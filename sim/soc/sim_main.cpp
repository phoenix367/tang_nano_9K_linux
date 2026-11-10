// Verilator driver for the QERV SoC (sim/soc/tb_soc.v): boots the stage-1 Linux image and
// reports console milestones in clock cycles and instruction fetches, like perf/boot_trace.
//
// Plusargs (the PSRAM model's +psram_load0/+psram_addr0/... are passed through):
//   +max_cycles=<n>       stop after n cycles (default 4e9)
//   +input=<text>         typed at the shell prompt ("\n" = newline), one line per prompt;
//                         the run ends at the prompt after the last line. Each character
//                         waits for its echo (the polled UART reads one FIFO per tick).
//   +uart_log=<file>      console copy
//   +fetch_trace=<file>   one little-endian u32 PC per instruction fetch
//   +quiet                no console on stdout
//   +break_pc=<hex>       stop at the first fetch of this PC and write the last 20000 fetches
//                         with CPU state (MIE MPIE mode new_irq mtip) to +break_dump=<file>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "Vtb_soc.h"
#include "verilated.h"

static const char *milestones[] = {"Linux version", "Freeing unused kernel", "Run /init",
                                   "Kernel panic", nullptr};

// Value of +name=value, or nullptr. (commandArgsPlusMatch returns "" when absent.)
static const char *plusarg(const char *prefix) {
  const char *a = Verilated::commandArgsPlusMatch(prefix);
  if (!a || !*a) return nullptr;
  const char *eq = strchr(a, '=');
  return eq ? eq + 1 : a + strlen(a);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *top = new Vtb_soc;

  uint64_t max_cycles = 4000000000ull;
  if (const char *a = plusarg("max_cycles=")) max_cycles = strtoull(a, nullptr, 0);
  std::string input;
  if (const char *a = plusarg("input=")) {
    for (const char *p = a; *p; p++) {
      if (p[0] == '\\' && p[1] == 'n') { input += '\n'; p++; } else input += *p;
    }
  }
  int input_lines = 0;
  for (char c : input) input_lines += c == '\n';
  FILE *ulog = nullptr, *ftrace = nullptr;
  if (const char *a = plusarg("uart_log=")) {
    ulog = fopen(a, "w");
    if (ulog) setvbuf(ulog, nullptr, _IONBF, 0);       // readable while running
  }
  if (const char *a = plusarg("fetch_trace=")) ftrace = fopen(a, "wb");
  bool quiet = plusarg("quiet") != nullptr;
  uint32_t break_pc = 0;
  bool have_break = false;
  if (const char *a = plusarg("break_pc=")) { break_pc = strtoul(a, nullptr, 16); have_break = true; }
  const char *break_dump = plusarg("break_dump=");
  const size_t RING = 20000;
  struct Rec { uint64_t cycle; uint32_t pc; uint8_t st; };
  static Rec ring[RING];
  size_t ring_n = 0;

  const uint64_t clk_hz = 27000000, baud = 1000000, cpb = clk_hz / baud;

  std::string tail;
  uint64_t milestone_cycle[5] = {0}, milestone_fetch[5] = {0};
  uint64_t stop_cycle = 0, stop_fetch = 0, done_cycle = 0;
  bool feeding = false;
  size_t in_pos = 0;
  int prompts = 0;
  // RX serializer state
  int rx_bit = -1;             // -1 idle, 0 start, 1..8 data, 9 stop
  uint64_t rx_next = 0;
  uint8_t rx_char = 0;
  bool wait_echo = false;
  bool line_ready = false;     // a prompt was seen: the next line may be typed
  uint64_t echo_deadline = 0;

  uint64_t cycle = 0, fetches = 0;
  top->rst = 1;
  top->uart_rx = 1;
  top->clk = 0;
  top->eval();

  auto prompt_in_tail = [&](void) {
    size_t p = tail.rfind("# ");
    if (p == std::string::npos || p + 2 != tail.size()) return false;
    size_t ls = tail.find_last_of("\r\n", p);
    size_t start = (ls == std::string::npos) ? 0 : ls + 1;
    return tail[start] != '[';
  };

  const char *end_reason = "max_cycles";
  for (; cycle < max_cycles; cycle++) {
    top->rst = cycle < 16;
    top->clk = 0;
    top->eval();

    // ---- sample the cycle
    if (top->fetch && !top->rst) {
      fetches++;
      if (ftrace) { uint32_t pc = top->pc; fwrite(&pc, 4, 1, ftrace); }
      if (have_break) {
        ring[ring_n % RING] = {cycle, (uint32_t)top->pc,
                               (uint8_t)(top->dbg_mie | top->dbg_mpie << 1 | top->dbg_mode_m << 2 |
                                         top->dbg_new_irq << 3 | top->dbg_mtip << 4)};
        ring_n++;
        if (top->pc == break_pc) {
          FILE *bf = fopen(break_dump ? break_dump : "break_dump.txt", "w");
          size_t first = ring_n > RING ? ring_n - RING : 0;
          fprintf(bf, "# fetch cycle pc MIE MPIE M new_irq mtip\n");
          for (size_t i = first; i < ring_n; i++) {
            const Rec &r = ring[i % RING];
            fprintf(bf, "%zu %llu %08x %d %d %d %d %d\n", i + 1, (unsigned long long)r.cycle, r.pc,
                    r.st & 1, r.st >> 1 & 1, r.st >> 2 & 1, r.st >> 3 & 1, r.st >> 4 & 1);
          }
          fclose(bf);
          end_reason = "break_pc";
          break;
        }
      }
    }
    if (top->tx_push && !top->rst) {
      char ch = (char)top->tx_byte;
      if (!quiet) { fputc(ch, stdout); fflush(stdout); }
      if (ulog) fputc(ch, ulog);
      if (ch) {
        tail += ch;
        if (tail.size() > 512) tail.erase(0, 256);
        for (int i = 0; milestones[i]; i++)
          if (!milestone_cycle[i] && tail.find(milestones[i]) != std::string::npos) {
            milestone_cycle[i] = cycle;
            milestone_fetch[i] = fetches;
          }
        if (wait_echo && in_pos > 0 && (ch == input[in_pos - 1] || (input[in_pos - 1] == '\n' && ch == '\n'))) wait_echo = false;
        if (milestone_cycle[2] && prompt_in_tail()) {
          if (!stop_cycle) {
            stop_cycle = cycle;
            stop_fetch = fetches;
            if (input.empty()) { end_reason = "prompt"; break; }
            feeding = true;
            line_ready = true;
          } else if (feeding) {
            line_ready = true;
            if (++prompts >= input_lines && in_pos == input.size()) {
              done_cycle = cycle;
              end_reason = "input_done";
              break;
            }
          }
          tail.clear();
        }
      }
    }
    if (milestone_cycle[3]) { end_reason = "kernel_panic"; break; }
    if (top->poweroff) { end_reason = "poweroff"; break; }

    // ---- UART RX: type the input, one character per echo
    if (feeding && line_ready && rx_bit < 0 && !wait_echo && in_pos < input.size()) {
      rx_char = (uint8_t)input[in_pos++];
      if (rx_char == '\n') line_ready = false;    // wait for the next prompt
      rx_bit = 0;
      rx_next = cycle;
      wait_echo = true;
      echo_deadline = cycle + clk_hz / 20;         // give up waiting after 50 ms
    }
    if (wait_echo && cycle > echo_deadline) wait_echo = false;
    if (rx_bit >= 0 && cycle >= rx_next) {
      top->uart_rx = rx_bit == 0 ? 0 : rx_bit <= 8 ? ((rx_char >> (rx_bit - 1)) & 1) : 1;
      rx_next = cycle + cpb;
      rx_bit = rx_bit == 9 ? -1 : rx_bit + 1;
    }

    top->clk = 1;
    top->eval();
  }

  fprintf(stderr, "\n== end: %s after %llu cycles (%.3f s at 27 MHz), %llu fetches\n", end_reason,
          (unsigned long long)cycle, cycle / (double)clk_hz, (unsigned long long)fetches);
  for (int i = 0; milestones[i]; i++)
    if (milestone_cycle[i])
      fprintf(stderr, "   %-22s cycle %12llu  fetch %10llu  (%.3f s)\n", milestones[i],
              (unsigned long long)milestone_cycle[i], (unsigned long long)milestone_fetch[i],
              milestone_cycle[i] / (double)clk_hz);
  if (stop_cycle)
    fprintf(stderr, "   %-22s cycle %12llu  fetch %10llu  (%.3f s)\n", "shell prompt",
            (unsigned long long)stop_cycle, (unsigned long long)stop_fetch, stop_cycle / (double)clk_hz);
  if (ulog) fclose(ulog);
  if (ftrace) fclose(ftrace);
  top->final();
  delete top;
  return strcmp(end_reason, "prompt") == 0 || strcmp(end_reason, "input_done") == 0 ||
                 strcmp(end_reason, "poweroff") == 0 ? 0 : 2;
}
