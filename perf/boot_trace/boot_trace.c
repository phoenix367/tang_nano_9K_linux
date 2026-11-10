// boot_trace: run a no-MMU RV32IMA Linux image in cnlohr's mini-rv32ima emulator core
// (external/mini-rv32ima, used unmodified as a header) and record what a CPU on the Tang
// Nano 9K would have to execute to reach the shell:
//   - instruction count by class (the classes perf/serv_cpi measures cycle costs for),
//     with shift-amount histograms because SERV's shift cost depends on the amount;
//   - trap entries, MMIO accesses, WFI idle time;
//   - hit/miss/write-back counts for a set of I-cache and D-cache configurations
//     (set-associative, LRU, D-cache write-back + write-allocate);
//   - the instruction count at which boot milestones appear on the UART.
// Output is JSON (-o). perf/estimate_boot.py turns it into boot-time estimates.
//
// Time model: the emulated timer advances by (instructions x -u microseconds), so timer
// interrupts and time-based waits happen at roughly the rate they would on the target CPU.
// WFI fast-forwards to the next timer match and the skipped time is reported as idle_us.
//
// Usage: boot_trace -f Image [-b dtb] [-m ram_bytes] [-u us_per_instr] [-s stop_string]
//                   [-n max_instr] [-o out.json] [-L uart.log] [-T pc.trace] [-P pc.hist]
//                   [-i "cmd\n..."] [-1] [-q]
// -1 (lockstep): one instruction per step, timer +1 per step, wfi a no-op - the time model of
//    sim/soc with a per-fetch CLINT tick, so PC traces (-T) can be compared with the RTL.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "default64mbdtc.h"

static uint32_t ram_amt = 8 * 1024 * 1024;

// Hooks called from inside the emulator core (defined below).
static inline uint32_t bus_load4(uint32_t ofs);
static inline void data_access(uint32_t ofs, int write);
static void post_exec(uint32_t pc_after, uint32_t ir, uint32_t trap);
static uint32_t control_store(uint32_t addy, uint32_t val);
static uint32_t control_load(uint32_t addy);

// ---------------------------------------------------------------- emulator core
#define MINIRV32WARN(x...) fprintf(stderr, x);
#define MINIRV32_DECORATE static
#define MINI_RV32_RAM_SIZE ram_amt
#define MINIRV32_IMPLEMENTATION
#define MINIRV32_CUSTOM_MEMORY_BUS
#define MINIRV32_LOAD4(ofs) bus_load4(ofs)
#define MINIRV32_LOAD2(ofs) (data_access((ofs), 0), *(uint16_t *)(image + (ofs)))
#define MINIRV32_LOAD1(ofs) (data_access((ofs), 0), *(uint8_t *)(image + (ofs)))
#define MINIRV32_LOAD2_SIGNED(ofs) (data_access((ofs), 0), *(int16_t *)(image + (ofs)))
#define MINIRV32_LOAD1_SIGNED(ofs) (data_access((ofs), 0), *(int8_t *)(image + (ofs)))
#define MINIRV32_STORE4(ofs, val) (data_access((ofs), 1), *(uint32_t *)(image + (ofs)) = (val))
#define MINIRV32_STORE2(ofs, val) (data_access((ofs), 1), *(uint16_t *)(image + (ofs)) = (val))
#define MINIRV32_STORE1(ofs, val) (data_access((ofs), 1), *(uint8_t *)(image + (ofs)) = (val))
#define MINIRV32_POSTEXEC(pc, ir, retval) post_exec((pc), (ir), (retval));
#define MINIRV32_HANDLE_MEM_STORE_CONTROL(addy, val) if (control_store(addy, val)) return val;
#define MINIRV32_HANDLE_MEM_LOAD_CONTROL(addy, rval) rval = control_load(addy);
#define MINIRV32_OTHERCSR_WRITE(csrno, value) ;
#define MINIRV32_OTHERCSR_READ(csrno, value) value = 0;
#include "mini-rv32ima.h"

static uint8_t *ram_image;
static struct MiniRV32IMAState *core;

// ---------------------------------------------------------------- cache model
typedef struct {
  const char *side;  // "I" or "D"
  uint32_t size, line, ways;
  uint32_t sets, line_shift;
  uint32_t *tag;      // sets*ways, tag | valid bit 0
  uint8_t *dirty;     // sets*ways
  uint32_t *age;      // sets*ways, LRU timestamps
  uint32_t clock;
  uint64_t reads, writes, misses, writebacks;
} cache_t;

static void cache_init(cache_t *c, const char *side, uint32_t size, uint32_t line, uint32_t ways) {
  memset(c, 0, sizeof(*c));
  c->side = side;
  c->size = size;
  c->line = line;
  c->ways = ways;
  c->sets = size / line / ways;
  while ((1u << c->line_shift) < line) c->line_shift++;
  c->tag = calloc((size_t)c->sets * ways, sizeof(uint32_t));
  c->dirty = calloc((size_t)c->sets * ways, 1);
  c->age = calloc((size_t)c->sets * ways, sizeof(uint32_t));
}

static void cache_access(cache_t *c, uint32_t addr, int write) {
  uint32_t lineaddr = addr >> c->line_shift;
  uint32_t set = lineaddr % c->sets;
  uint32_t tag = ((lineaddr / c->sets) << 1) | 1;
  uint32_t base = set * c->ways;
  if (write) c->writes++; else c->reads++;
  c->clock++;
  for (uint32_t w = 0; w < c->ways; w++) {
    if (c->tag[base + w] == tag) {
      c->age[base + w] = c->clock;
      if (write) c->dirty[base + w] = 1;
      return;
    }
  }
  c->misses++;
  uint32_t victim = 0;
  for (uint32_t w = 1; w < c->ways; w++)
    if (c->age[base + w] < c->age[base + victim]) victim = w;
  if ((c->tag[base + victim] & 1) && c->dirty[base + victim]) c->writebacks++;
  c->tag[base + victim] = tag;
  c->dirty[base + victim] = (uint8_t)write;
  c->age[base + victim] = c->clock;
}

#define MAX_CACHES 64
static cache_t icaches[MAX_CACHES], dcaches[MAX_CACHES], ucaches[MAX_CACHES];
static int n_icaches, n_dcaches, n_ucaches;

static void caches_init(void) {
  static const uint32_t sizes[] = {2048, 4096, 8192, 16384};
  static const uint32_t lines[] = {16, 32, 64};
  static const uint32_t ways[] = {1, 2};
  for (unsigned s = 0; s < sizeof sizes / sizeof *sizes; s++)
    for (unsigned l = 0; l < sizeof lines / sizeof *lines; l++)
      for (unsigned w = 0; w < sizeof ways / sizeof *ways; w++) {
        cache_init(&icaches[n_icaches++], "I", sizes[s], lines[l], ways[w]);
        cache_init(&dcaches[n_dcaches++], "D", sizes[s], lines[l], ways[w]);
        // Unified (instruction + data) cache, as planned for SERV (one bus master).
        cache_init(&ucaches[n_ucaches++], "U", 2 * sizes[s], lines[l], ways[w]);
      }
}

// ---------------------------------------------------------------- instruction stats
enum {
  C_LUI, C_AUIPC, C_JAL, C_JALR, C_BR_TAKEN, C_BR_NOT_TAKEN,
  C_LB, C_LH, C_LW, C_LBU, C_LHU, C_SB, C_SH, C_SW,
  C_ADDI, C_SLTI, C_SLTIU, C_XORI, C_ORI, C_ANDI, C_SLLI, C_SRLI, C_SRAI,
  C_ADD, C_SUB, C_SLL, C_SLT, C_SLTU, C_XOR, C_SRL, C_SRA, C_OR, C_AND,
  C_MUL, C_MULH, C_MULHSU, C_MULHU, C_DIV, C_DIVU, C_REM, C_REMU,
  C_FENCE, C_FENCE_I, C_ECALL, C_EBREAK, C_MRET, C_WFI, C_SYSTEM_OTHER, C_CSR,
  C_LR, C_SC, C_AMO, C_ILLEGAL, C_COUNT
};
static const char *class_names[C_COUNT] = {
  "lui", "auipc", "jal", "jalr", "branch_taken", "branch_not_taken",
  "lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw",
  "addi", "slti", "sltiu", "xori", "ori", "andi", "slli", "srli", "srai",
  "add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
  "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu",
  "fence", "fence_i", "ecall", "ebreak", "mret", "wfi", "system_other", "csr",
  "lr", "sc", "amo", "illegal"
};
static uint64_t class_count[C_COUNT];
// shift-amount histograms: slli, srli, srai, sll, srl, sra
static const int shift_classes[6] = {C_SLLI, C_SRLI, C_SRAI, C_SLL, C_SRL, C_SRA};
static uint64_t shamt_hist[6][32];
static uint64_t instret, exceptions, trap_entries, mmio_loads, mmio_stores, user_instret;
static uint64_t exc_by_cause[16];

static FILE *pc_trace;  // -T: one little-endian u32 PC per retired instruction
static uint32_t *pc_hist;  // -P: retired-instruction count per word address in RAM
static int expect_fetch = 1;
static uint32_t cur_ofs, cur_ir, pre_rs2;
static uint32_t dacc_addr[4];
static uint8_t dacc_wr[4];
static int n_dacc;

static inline void data_access(uint32_t ofs, int write) {
  if (n_dacc < 4) {
    dacc_addr[n_dacc] = ofs;
    dacc_wr[n_dacc] = (uint8_t)write;
    n_dacc++;
  }
}

static inline uint32_t bus_load4(uint32_t ofs) {
  uint32_t v;
  memcpy(&v, ram_image + ofs, 4);
  if (expect_fetch) {
    expect_fetch = 0;
    cur_ofs = ofs;
    cur_ir = v;
    pre_rs2 = core->regs[(v >> 20) & 31];
    n_dacc = 0;
    if (ofs + 0x80000000u == core->mtvec) trap_entries++;
  } else {
    data_access(ofs, 0);
  }
  return v;
}

static void shift_record(int idx, uint32_t amount) { shamt_hist[idx][amount & 31]++; }

static int classify(uint32_t ir, uint32_t pc_after) {
  uint32_t op = ir & 0x7f, f3 = (ir >> 12) & 7, f7 = ir >> 25;
  switch (op) {
  case 0x37: return C_LUI;
  case 0x17: return C_AUIPC;
  case 0x6f: return C_JAL;
  case 0x67: return C_JALR;
  case 0x63: return (pc_after != cur_ofs + 0x80000000u) ? C_BR_TAKEN : C_BR_NOT_TAKEN;
  case 0x03: {
    static const int m[8] = {C_LB, C_LH, C_LW, C_ILLEGAL, C_LBU, C_LHU, C_ILLEGAL, C_ILLEGAL};
    return m[f3];
  }
  case 0x23: return f3 == 0 ? C_SB : f3 == 1 ? C_SH : f3 == 2 ? C_SW : C_ILLEGAL;
  case 0x13: {
    uint32_t shamt = (ir >> 20) & 31;
    switch (f3) {
    case 0: return C_ADDI;
    case 1: shift_record(0, shamt); return C_SLLI;
    case 2: return C_SLTI;
    case 3: return C_SLTIU;
    case 4: return C_XORI;
    case 5:
      if (f7 & 0x20) { shift_record(2, shamt); return C_SRAI; }
      shift_record(1, shamt); return C_SRLI;
    case 6: return C_ORI;
    default: return C_ANDI;
    }
  }
  case 0x33:
    if (f7 == 1) {
      static const int m[8] = {C_MUL, C_MULH, C_MULHSU, C_MULHU, C_DIV, C_DIVU, C_REM, C_REMU};
      return m[f3];
    }
    switch (f3) {
    case 0: return (f7 & 0x20) ? C_SUB : C_ADD;
    case 1: shift_record(3, pre_rs2); return C_SLL;
    case 2: return C_SLT;
    case 3: return C_SLTU;
    case 4: return C_XOR;
    case 5:
      if (f7 & 0x20) { shift_record(5, pre_rs2); return C_SRA; }
      shift_record(4, pre_rs2); return C_SRL;
    case 6: return C_OR;
    default: return C_AND;
    }
  case 0x0f: return f3 == 1 ? C_FENCE_I : C_FENCE;
  case 0x73:
    if (f3 != 0) return C_CSR;
    switch (ir >> 20) {
    case 0x000: return C_ECALL;
    case 0x001: return C_EBREAK;
    case 0x302: return C_MRET;
    case 0x105: return C_WFI;
    default: return C_SYSTEM_OTHER;
    }
  case 0x2f: {
    uint32_t f5 = ir >> 27;
    return f5 == 2 ? C_LR : f5 == 3 ? C_SC : C_AMO;
  }
  default: return C_ILLEGAL;
  }
}

static void post_exec(uint32_t pc_after, uint32_t ir, uint32_t trap) {
  instret++;
  if ((core->extraflags & 3) == 0) user_instret++;
  class_count[classify(ir, pc_after)]++;
  if (trap) {
    exceptions++;
    exc_by_cause[(trap - 1) & 15]++;
  }
  for (int i = 0; i < n_icaches; i++) cache_access(&icaches[i], cur_ofs, 0);
  for (int i = 0; i < n_ucaches; i++) cache_access(&ucaches[i], cur_ofs, 0);
  for (int a = 0; a < n_dacc; a++) {
    for (int i = 0; i < n_dcaches; i++) cache_access(&dcaches[i], dacc_addr[a], dacc_wr[a]);
    for (int i = 0; i < n_ucaches; i++) cache_access(&ucaches[i], dacc_addr[a], dacc_wr[a]);
  }
  if (pc_hist) pc_hist[cur_ofs >> 2]++;
  if (pc_trace) {
    uint32_t pc = cur_ofs + 0x80000000u;
    fwrite(&pc, 4, 1, pc_trace);
  }
  expect_fetch = 1;
}

// ---------------------------------------------------------------- UART / milestones
static const char *milestone_str[] = {"Linux version", "Freeing unused kernel", "Run /init",
                                      "Kernel panic", NULL};
static uint64_t milestone_at[5];
// Boot is done at the first of these after "Run /init": a getty login prompt (6.1 image) or
// the root shell prompt (6.8 image auto-logs in). -s replaces the list with one string.
static const char *stop_strings[3] = {" login: ", "# ", NULL};
static const char *stop_string = " login: | # ";
static uint64_t stop_at;
// -i: text typed into the UART once the boot prompt appears. The tty driver may read it all at
// once, so the run ends when one prompt per typed line has appeared ("done" milestone).
static char *input;
static size_t input_pos, input_len;
static int feeding, input_lines, prompts_seen;
static uint64_t done_at;
static char uart_tail[256];
static size_t uart_len;
static int quiet;
static FILE *uart_log;

static void uart_putc(char ch) {
  if (!quiet) { putchar(ch); fflush(stdout); }
  if (uart_log) fputc(ch, uart_log);
  if (ch == 0) return;  // earlycon emits a NUL first; it would end the C string below
  if (uart_len + 1 >= sizeof uart_tail) {
    memmove(uart_tail, uart_tail + 128, uart_len - 128);
    uart_len -= 128;
  }
  uart_tail[uart_len++] = ch;
  uart_tail[uart_len] = 0;
  for (int i = 0; milestone_str[i]; i++)
    if (!milestone_at[i] && strstr(uart_tail, milestone_str[i])) milestone_at[i] = instret;
  if (!stop_at && milestone_at[2])
    for (int i = 0; stop_strings[i]; i++) {
      const char *hit = strstr(uart_tail, stop_strings[i]);
      if (!hit) continue;
      // Ignore kernel log lines ("[    7.6] login: page allocation failure ...").
      const char *line = hit;
      while (line > uart_tail && line[-1] != '\n' && line[-1] != '\r') line--;
      if (*line != '[') stop_at = instret;
    }
  if (stop_at && input && !feeding) {
    feeding = 1;
    uart_len = 0;  // forget the boot prompt
  } else if (feeding && !done_at) {
    for (int i = 0; stop_strings[i]; i++) {
      const char *hit = strstr(uart_tail, stop_strings[i]);
      if (!hit) continue;
      const char *line = hit;
      while (line > uart_tail && line[-1] != '\n' && line[-1] != '\r') line--;
      if (*line == '[') continue;
      uart_len = 0;  // count each prompt once
      if (++prompts_seen >= input_lines) done_at = instret;
      break;
    }
  }
}

static uint32_t control_store(uint32_t addy, uint32_t val) {
  mmio_stores++;
  if (addy == 0x10000000) uart_putc((char)val);
  else if (addy == 0x11004004) core->timermatchh = val;
  else if (addy == 0x11004000) core->timermatchl = val;
  else if (addy == 0x11100000) { core->pc = core->pc + 4; return val; }  // SYSCON
  return 0;
}

static uint32_t control_load(uint32_t addy) {
  mmio_loads++;
  int rx = feeding && input_pos < input_len;
  if (addy == 0x10000005) return 0x60 | rx;  // 8250 LSR: TX empty, DR when input is pending
  if (addy == 0x10000000 && rx) {
    return (uint8_t)input[input_pos++];
  }
  if (addy == 0x1100bffc) return core->timerh;
  if (addy == 0x1100bff8) return core->timerl;
  return 0;
}


// ---------------------------------------------------------------- main
static void write_json(FILE *f, const char *image, double us_per_instr, uint64_t idle_us,
                       int stopped_reason) {
  fprintf(f, "{\n  \"image\": \"%s\",\n  \"ram_bytes\": %u,\n  \"us_per_instr\": %g,\n", image,
          ram_amt, us_per_instr);
  static const char *reasons[] = {"stop_string", "max_instr", "poweroff", "stuck_wfi", "kernel_panic"};
  fprintf(f, "  \"end_reason\": \"%s\",\n  \"stop_string\": \"%s\",\n", reasons[stopped_reason],
          stop_string);
  fprintf(f, "  \"instret\": %llu,\n  \"user_instret\": %llu,\n", (unsigned long long)instret,
          (unsigned long long)user_instret);
  fprintf(f, "  \"idle_us\": %llu,\n  \"exceptions\": %llu,\n  \"trap_entries\": %llu,\n",
          (unsigned long long)idle_us, (unsigned long long)exceptions,
          (unsigned long long)trap_entries);
  fprintf(f, "  \"mmio_loads\": %llu,\n  \"mmio_stores\": %llu,\n", (unsigned long long)mmio_loads,
          (unsigned long long)mmio_stores);
  fprintf(f, "  \"exceptions_by_cause\": [");
  for (int i = 0; i < 16; i++) fprintf(f, "%s%llu", i ? ", " : "", (unsigned long long)exc_by_cause[i]);
  fprintf(f, "],\n  \"milestones\": {");
  for (int i = 0; milestone_str[i]; i++)
    fprintf(f, "%s\"%s\": %llu", i ? ", " : "", milestone_str[i], (unsigned long long)milestone_at[i]);
  fprintf(f, ", \"stop\": %llu, \"done\": %llu},\n  \"classes\": {", (unsigned long long)stop_at,
          (unsigned long long)done_at);
  for (int i = 0; i < C_COUNT; i++)
    fprintf(f, "%s\n    \"%s\": %llu", i ? "," : "", class_names[i], (unsigned long long)class_count[i]);
  fprintf(f, "\n  },\n  \"shift_amounts\": {");
  for (int s = 0; s < 6; s++) {
    fprintf(f, "%s\n    \"%s\": [", s ? "," : "", class_names[shift_classes[s]]);
    for (int a = 0; a < 32; a++) fprintf(f, "%s%llu", a ? ", " : "", (unsigned long long)shamt_hist[s][a]);
    fprintf(f, "]");
  }
  fprintf(f, "\n  },\n  \"caches\": [");
  cache_t *sets[3] = {icaches, dcaches, ucaches};
  int counts[3] = {n_icaches, n_dcaches, n_ucaches};
  int first = 1;
  for (int k = 0; k < 3; k++)
    for (int i = 0; i < counts[k]; i++) {
      cache_t *c = &sets[k][i];
      fprintf(f, "%s\n    {\"side\": \"%s\", \"size\": %u, \"line\": %u, \"ways\": %u, "
              "\"reads\": %llu, \"writes\": %llu, \"misses\": %llu, \"writebacks\": %llu}",
              first ? "" : ",", c->side, c->size, c->line, c->ways, (unsigned long long)c->reads,
              (unsigned long long)c->writes, (unsigned long long)c->misses,
              (unsigned long long)c->writebacks);
      first = 0;
    }
  fprintf(f, "\n  ]\n}\n");
}

int main(int argc, char **argv) {
  const char *image_file = NULL, *out_file = NULL, *log_file = NULL, *dtb_file = NULL,
             *trace_file = NULL, *prof_file = NULL;
  double us_per_instr = 1.0;
  int lockstep = 0;
  uint64_t max_instr = 4ull * 1000 * 1000 * 1000;
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
    if (!strcmp(a, "-f") && v) image_file = argv[++i];
    else if (!strcmp(a, "-m") && v) ram_amt = (uint32_t)strtoul(argv[++i], NULL, 0);
    else if (!strcmp(a, "-u") && v) us_per_instr = atof(argv[++i]);
    else if (!strcmp(a, "-s") && v) { stop_string = stop_strings[0] = argv[++i]; stop_strings[1] = NULL; }
    else if (!strcmp(a, "-n") && v) max_instr = strtoull(argv[++i], NULL, 0);
    else if (!strcmp(a, "-o") && v) out_file = argv[++i];
    else if (!strcmp(a, "-L") && v) log_file = argv[++i];
    else if (!strcmp(a, "-b") && v) dtb_file = argv[++i];
    else if (!strcmp(a, "-T") && v) trace_file = argv[++i];
    else if (!strcmp(a, "-P") && v) prof_file = argv[++i];
    else if (!strcmp(a, "-i") && v) {  // "\n" in the argument becomes a newline
      const char *src = argv[++i];
      input = malloc(strlen(src) + 1);
      for (const char *q = src; *q; q++) {
        if (q[0] == '\\' && q[1] == 'n') { input[input_len++] = '\n'; q++; input_lines++; }
        else input[input_len++] = *q;
      }
    }
    else if (!strcmp(a, "-q")) quiet = 1;
    else if (!strcmp(a, "-1")) lockstep = 1;
    else {
      fprintf(stderr, "usage: %s -f Image [-m ram_bytes] [-u us_per_instr] [-s stop_string] "
                      "[-n max_instr] [-o out.json] [-L uart.log] [-b dtb] [-T pc.trace] [-P pc.hist] "
                      "[-i input] [-1] [-q]\n",
              argv[0]);
      return 1;
    }
  }
  if (!image_file || us_per_instr <= 0) {
    fprintf(stderr, "need -f Image and a positive -u\n");
    return 1;
  }
  if (log_file && (uart_log = fopen(log_file, "w"))) setvbuf(uart_log, NULL, _IONBF, 0);
  if (trace_file && !(pc_trace = fopen(trace_file, "wb"))) {
    fprintf(stderr, "cannot write %s\n", trace_file);
    return 1;
  }

  ram_image = calloc(ram_amt, 1);
  FILE *f = fopen(image_file, "rb");
  if (!f) { fprintf(stderr, "cannot open %s\n", image_file); return 1; }
  fseek(f, 0, SEEK_END);
  long flen = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (flen > (long)ram_amt || fread(ram_image, flen, 1, f) != 1) {
    fprintf(stderr, "cannot load %s into %u bytes\n", image_file, ram_amt);
    return 1;
  }
  fclose(f);

  // DTB at the start of the top 4 KB of RAM when it fits (the QERV boot ROM passes the same
  // address, 0x807FF000 for 8 MB, so emulator and RTL see the same memory layout); larger
  // DTBs go right below the top, 8-byte aligned. The kernel reserves it. Unlike
  // mini-rv32ima.c the CPU state lives outside guest RAM, so all of -m is RAM, as on the board.
  uint32_t dtb_ptr;
  if (dtb_file) {
    FILE *d = fopen(dtb_file, "rb");
    if (!d) { fprintf(stderr, "cannot open %s\n", dtb_file); return 1; }
    fseek(d, 0, SEEK_END);
    long dlen = ftell(d);
    fseek(d, 0, SEEK_SET);
    dtb_ptr = (dlen <= 4096) ? ram_amt - 4096 : (ram_amt - (uint32_t)dlen) & ~7u;
    if (dtb_ptr < (uint32_t)flen || fread(ram_image + dtb_ptr, dlen, 1, d) != 1) {
      fprintf(stderr, "cannot place %s in RAM\n", dtb_file);
      return 1;
    }
    fclose(d);
  } else {
    // mini-rv32ima's default DTB with its memory size patched to end below the DTB.
    dtb_ptr = (ram_amt - sizeof(default64mbdtb)) & ~7u;
    memcpy(ram_image + dtb_ptr, default64mbdtb, sizeof(default64mbdtb));
    uint32_t *dtb = (uint32_t *)(ram_image + dtb_ptr);
    if (dtb[0x13c / 4] == 0x00c0ff03) {
      uint32_t r = dtb_ptr;
      dtb[0x13c / 4] = (r >> 24) | (((r >> 16) & 0xff) << 8) | (((r >> 8) & 0xff) << 16) | ((r & 0xff) << 24);
    }
  }

  core = calloc(1, sizeof(struct MiniRV32IMAState));
  if (prof_file) pc_hist = calloc(ram_amt / 4, sizeof(uint32_t));
  core->pc = MINIRV32_RAM_IMAGE_OFFSET;
  core->regs[10] = 0;
  core->regs[11] = dtb_ptr + MINIRV32_RAM_IMAGE_OFFSET;
  core->extraflags |= 3;

  caches_init();

  double time_us = 0;       // emulated time
  uint64_t timer_fed = 0;   // microseconds already handed to the core's timer
  uint64_t idle_us = 0, last_instret = 0;
  int reason = 1;
  while (instret < max_instr) {
    int ret;
    if (lockstep) {
      // -1: the QERV RTL's deterministic time (sim/soc lockstep): one instruction (or one
      // interrupt entry) per step, the timer advances by 1 per step, wfi is a no-op.
      ret = MiniRV32IMAStep(core, ram_image, 0, 1, 1);
      if (ret == 1) {
        core->extraflags &= ~4u;
        ret = 0;
      }
    } else {
      time_us += (double)(instret - last_instret) * us_per_instr;
      last_instret = instret;
      uint64_t now = (uint64_t)time_us;
      uint32_t elapsed = (uint32_t)(now - timer_fed);
      timer_fed = now;
      ret = MiniRV32IMAStep(core, ram_image, 0, elapsed, 64);
    }
    if (stop_at && (!input || done_at)) { reason = 0; break; }
    if (milestone_at[3]) { reason = 4; break; }
    if (quiet && instret >= 64 && instret / 100000000 != (instret - 64) / 100000000)
      fprintf(stderr, "  ... %llu M instructions\n", (unsigned long long)(instret / 1000000));
    if (ret == 1) {  // WFI: skip ahead to the timer match
      uint64_t t = ((uint64_t)core->timerh << 32) | core->timerl;
      uint64_t m = ((uint64_t)core->timermatchh << 32) | core->timermatchl;
      if (!m) { reason = 3; break; }
      uint64_t skip = (m > t) ? (m - t + 1) : 1;
      idle_us += skip;
      time_us += (double)skip;
    } else if (ret == 0x5555 || ret == 0x7777) {
      reason = 2;
      break;
    } else if (ret != 0) {
      fprintf(stderr, "\nstep returned %d\n", ret);
      break;
    }
  }
  if (!quiet) printf("\n");
  fprintf(stderr, "instret=%llu idle_us=%llu end=%d stop_at=%llu\n", (unsigned long long)instret,
          (unsigned long long)idle_us, reason, (unsigned long long)stop_at);
  if (out_file) {
    FILE *o = fopen(out_file, "w");
    write_json(o, image_file, us_per_instr, idle_us, reason);
    fclose(o);
  }
  if (uart_log) fclose(uart_log);
  if (pc_trace) fclose(pc_trace);
  if (pc_hist) {  // text: "<pc hex> <count>" for every executed address
    FILE *pf = fopen(prof_file, "w");
    for (uint32_t i = 0; pf && i < ram_amt / 4; i++)
      if (pc_hist[i]) fprintf(pf, "%08x %u\n", 0x80000000u + 4 * i, pc_hist[i]);
    if (pf) fclose(pf);
  }
  return reason == 0 ? 0 : 2;
}
