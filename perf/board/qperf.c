/* qperf: performance tests for Linux on the Tang Nano 9K (QERV RV32IMA at 42 MHz, SV32 MMU,
 * 16 KB direct-mapped unified L1 with 32-byte lines, 8 MB PSRAM). perf/board/run.py builds it
 * with Buildroot's toolchain, uploads it to the board over the UART and runs it.
 *
 *   qperf [prefix...]      run the tests whose names start with a prefix (default: all)
 *
 * Output: one line per result, "name value unit details". Groups:
 *   cpu.*  cycles per instruction of one class, from inline-asm loops of 32 and 64 copies:
 *          (t64 - t32) / 32 cancels the loop overhead. Then two C workloads.
 *   os.*   what the kernel costs: the timer tick's share of a busy loop, syscalls, pipes,
 *          context switches, fork, exec, page faults, tmpfs I/O.
 *   mem.*  load latency by working-set size (a pointer chase over its lines in random order),
 *          read/write/memcpy/memset bandwidth in the cache and from PSRAM, and the
 *          framebuffer through its uncached alias.
 *
 * Two kinds of number. "best" is the fastest of many short runs (~1 ms, well under the 10 ms
 * tick period): the hardware or the kernel path alone, without timer interrupts. "avg" is a
 * long run's mean, what a program actually gets; the tick takes a large share (os.tick_share).
 * cpu.* and mem.* report best, os.* report avg with best in the details.
 *
 * Page colours: the cache is direct-mapped and as large as 4 pages, so two lines collide when
 * their physical addresses agree in bits 13:5; for a page that's the frame's bits 1:0 (its
 * colour) and the offset. Where the physical frames show in /proc/self/pagemap (root), the
 * mem.* buffers are put together from pages of chosen colours (moved into place with
 * mremap): consecutive colours like contiguous memory, chase lines that would collide with
 * the chase code left out. memcpy runs both ways: source and destination pages of different
 * colours, and of the same colours (mem.memcpy_*_conflict), which thrashes.
 *
 * Times come from the time CSR (the CLINT's mtime, 1 MHz); cycles assume CPU_HZ. The SoC's
 * counters (SYSCON words 5 and 6: cache misses and write-backs, through /dev/mem) give the
 * misses of a run; they count everything the system does in the meantime.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef CPU_HZ
#define CPU_HZ 42000000.0
#endif
#define KERNEL_HZ 100                       /* CONFIG_HZ_100 */
#define SYSCON 0x11100000u
#define PAGE 4096
#define LINE 32
#define COLORS 4                            /* 16 KB direct-mapped cache / 4 KB pages */

static char **filters;
static int nfilters;

static int want(const char *name)
{
    if (!nfilters)
        return 1;
    for (int i = 0; i < nfilters; i++) {            /* either one a prefix of the other */
        size_t a = strlen(name), b = strlen(filters[i]);
        if (!strncmp(name, filters[i], a < b ? a : b))
            return 1;
    }
    return 0;
}

static void out(const char *name, double v, const char *unit, const char *fmt, ...)
{
    printf("%-26s %11.3f %-7s", name, v, unit);
    if (fmt) {
        va_list ap;
        va_start(ap, fmt);
        putchar(' ');
        vprintf(fmt, ap);
        va_end(ap);
    }
    putchar('\n');
    fflush(stdout);
}

static double cycles(double us) { return us * CPU_HZ / 1e6; }

/* ---------------------------------------------------------------- time and counters */
static int use_rdtime;

static inline uint32_t rdtime(void)
{
    uint32_t t;
    __asm__ volatile("rdtime %0" : "=r"(t));
    return t;
}

static uint32_t gettime_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)ts.tv_sec * 1000000u + (uint32_t)(ts.tv_nsec / 1000);
}

static inline uint32_t now(void) { return use_rdtime ? rdtime() : gettime_us(); }

static void time_init(void)
{
    uint32_t a = rdtime(), g = gettime_us();
    usleep(100000);
    uint32_t da = rdtime() - a, dg = gettime_us() - g;
    use_rdtime = da > dg * 0.97 && da < dg * 1.03;
}

static volatile uint32_t *sysc;

struct hw { uint32_t miss, wb; };

static void hw_init(void)
{
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0)
        return;
    void *p = mmap(0, PAGE, PROT_READ, MAP_SHARED, fd, SYSCON);
    if (p != MAP_FAILED)
        sysc = p;
    close(fd);
}

static struct hw hw_now(void)
{
    struct hw h = {0, 0};
    if (sysc) {
        h.miss = sysc[5];
        h.wb = sysc[6];
    }
    return h;
}

static struct hw hw_delta(struct hw a)
{
    struct hw b = hw_now();
    b.miss -= a.miss;
    b.wb -= a.wb;
    return b;
}

/* ---------------------------------------------------------------- measuring */
typedef void (*bfn)(unsigned n, void *ctx);

struct res { double us; unsigned n; struct hw hw; };     /* us per unit of n; counters */

/* avg: f(n) with n doubling until it takes a quarter of target_us, then once more scaled to
 * about target_us. */
static struct res bench(bfn f, void *ctx, uint32_t target_us)
{
    unsigned n = 1;
    uint32_t d;
    for (;;) {
        uint32_t t0 = now();
        f(n, ctx);
        d = now() - t0;
        if (d >= target_us / 4 || n >= (1u << 28))
            break;
        n *= 2;
    }
    double k = (double)target_us / (d ? d : 1);
    if (k > 1.2)
        n = (unsigned)(n * k);
    struct hw h0 = hw_now();
    uint32_t t0 = now();
    f(n, ctx);
    d = now() - t0;
    struct res r = {(double)d / n, n, hw_delta(h0)};
    return r;
}

/* best: the fastest of `runs` runs of f(n). The counters come from the fastest run that
 * nothing interrupted around the counter reads (a tick there counts its misses but not its
 * time). */
static struct res best(bfn f, void *ctx, unsigned n, int runs)
{
    struct res r = {1e30, n, {0, 0}};
    double hw_us = 1e30;
    for (int i = 0; i < runs; i++) {
        uint32_t ta = now();
        struct hw h0 = hw_now();
        uint32_t t0 = now();
        f(n, ctx);
        uint32_t t1 = now();
        struct hw h = hw_delta(h0);
        uint32_t tb = now();
        double us = (t1 - t0) / (double)n;
        if (us < r.us)
            r.us = us;
        if (t0 - ta < 20 && tb - t1 < 20 && us < hw_us) {
            hw_us = us;
            r.hw = h;
        }
    }
    return r;
}

/* the n for which f(n) takes at least us microseconds */
static unsigned chunk_n(bfn f, void *ctx, uint32_t us)
{
    unsigned n = 1;
    for (; n < (1u << 28); n *= 2) {
        uint32_t t0 = now();
        f(n, ctx);
        if (now() - t0 >= us)
            break;
    }
    return n;
}

/* ---------------------------------------------------------------- page colours */
static int pagemap = -1, colors_ok;

static int color_of(const void *va)
{
    uint64_t e;
    if (!colors_ok ||
        pread(pagemap, &e, 8, (off_t)((uintptr_t)va / PAGE) * 8) != 8 || !(e >> 63))
        return -1;
    return (int)(e & (COLORS - 1));
}

static void colors_init(void)
{
    static volatile char probe[PAGE] __attribute__((aligned(PAGE)));
    uint64_t e;
    probe[0] = 1;
    pagemap = open("/proc/self/pagemap", O_RDONLY);
    colors_ok = pagemap >= 0 && pread(pagemap, &e, 8, (off_t)((uintptr_t)probe / PAGE) * 8) == 8 &&
                (e >> 63) && (e & ((1ull << 55) - 1));      /* frame numbers shown (root) */
}

/* A virtually contiguous buffer of n pages, page i of colour col(i) (-1: any), put together
 * from pages faulted in elsewhere and moved into place with mremap. Without the colours, a
 * plain buffer. */
typedef int (*colfn)(unsigned i);

static uint8_t *colored_buffer(unsigned n, colfn col)
{
    size_t len = (size_t)n * PAGE;
    if (!colors_ok) {
        uint8_t *p = mmap(0, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED)
            return 0;
        memset(p, 0, len);
        return p;
    }
    uint8_t *dst = mmap(0, len, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (dst == MAP_FAILED)
        return 0;
    unsigned cap = n + 64, have = 0, cnt[COLORS] = {0};
    uint8_t **pool[COLORS];
    for (int c = 0; c < COLORS; c++)
        pool[c] = malloc((cap + 32) * sizeof(uint8_t *));
    for (unsigned i = 0; i < n; i++) {
        int c = col(i);
        while (c < 0 || !cnt[c]) {
            if (c < 0 || have >= cap) {               /* any colour will do */
                for (int k = 0; k < COLORS; k++)
                    if (cnt[k])
                        c = k;
                if (c >= 0 && cnt[c])
                    break;
            }
            uint8_t *b = mmap(0, 16 * PAGE, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (b == MAP_FAILED)
                exit(6);
            for (int k = 0; k < 16; k++) {
                b[k * PAGE] = 0;                      /* fault it in: a frame of its own */
                int cc = color_of(b + k * PAGE);
                if (cc < 0)
                    cc = 0;
                pool[cc][cnt[cc]++] = b + k * PAGE;
            }
            have += 16;
        }
        uint8_t *pg = pool[c][--cnt[c]];
        if (mremap(pg, PAGE, PAGE, MREMAP_MAYMOVE | MREMAP_FIXED, dst + (size_t)i * PAGE) == MAP_FAILED)
            exit(7);
    }
    for (int c = 0; c < COLORS; c++) {
        while (cnt[c])
            munmap(pool[c][--cnt[c]], PAGE);
        free(pool[c]);
    }
    return dst;
}

static int col_rr(unsigned i) { return (int)(i % COLORS); }      /* like contiguous memory */
static unsigned split_at;
static int col_split(unsigned i)                                  /* 2nd part shifted by 2 */
{
    return (int)((i + (i >= split_at ? 2 : 0)) % COLORS);
}
static int want_cols[COLORS];
static int col_list(unsigned i) { return want_cols[i % COLORS]; }

/* colours for a buffer of up to 3 pages that the given code can't collide with */
static void avoid_code(const void *code)
{
    int cc = color_of(code), k = 0;
    for (int c = 0; c < COLORS; c++)
        if (c != cc)
            want_cols[k++] = c;
    want_cols[3] = want_cols[0];
}

/* ---------------------------------------------------------------- cpu: instruction classes */
#define S4(x) x x x x
#define S16(x) S4(S4(x))
#define S32(x) S16(x) S16(x)
#define S64(x) S32(x) S32(x)

/* t1 = 3 (a divisor), t2 = a pointer to a private word */
#define ILOOP(fname, body, rep)                                                   \
    static void __attribute__((noinline)) fname(unsigned n, void *p)              \
    {                                                                             \
        __asm__ volatile("li t1, 3\n\t"                                           \
                         "mv t2, %1\n\t"                                          \
                         "1:\n\t" rep(body) "addi %0, %0, -1\n\t"                 \
                         "bnez %0, 1b\n\t"                                        \
                         : "+r"(n)                                                \
                         : "r"(p)                                                 \
                         : "t0", "t1", "t2", "memory");                           \
    }
#define CPUTEST(id, body) ILOOP(id##_32, body, S32) ILOOP(id##_64, body, S64)

CPUTEST(c_add, "add t0, t0, t1\n\t")
CPUTEST(c_lui, "lui t0, 0x12345\n\t")
CPUTEST(c_slt, "slt t0, t0, t1\n\t")
CPUTEST(c_slli, "slli t0, t0, 1\n\t")
CPUTEST(c_srli1, "srli t0, t0, 1\n\t")
CPUTEST(c_srli16, "srli t0, t0, 16\n\t")
CPUTEST(c_srli31, "srli t0, t0, 31\n\t")
CPUTEST(c_bnt, "bnez zero, .+4\n\t")
CPUTEST(c_bt, "beqz zero, .+4\n\t")
CPUTEST(c_jal, "jal zero, .+4\n\t")
CPUTEST(c_lw, "lw t0, 0(t2)\n\t")
CPUTEST(c_lb, "lb t0, 1(t2)\n\t")
CPUTEST(c_sw, "sw t0, 0(t2)\n\t")
CPUTEST(c_sb, "sb t0, 1(t2)\n\t")
CPUTEST(c_mul, "mul t0, t0, t1\n\t")
CPUTEST(c_mulh, "mulh t0, t0, t1\n\t")
CPUTEST(c_div, "div t0, t0, t1\n\t")
CPUTEST(c_amo, "amoadd.w t0, t1, (t2)\n\t")
CPUTEST(c_lrsc, "lr.w t0, (t2)\n\tsc.w t0, t1, (t2)\n\t")
CPUTEST(c_rdtime, "rdtime t0\n\t")
CPUTEST(c_fence, "fence\n\t")

static uint8_t scratch[PAGE] __attribute__((aligned(PAGE)));

/* line offsets in a page: is `off` clear of the lines code at `code` (len bytes) occupies? The
 * cache index's low bits are the offset's bits 11:5, whatever the frame. */
static int clear_of(uintptr_t off, const void *code, uintptr_t len)
{
    return ((off - (uintptr_t)code + 2 * LINE) & (PAGE - 1)) >= len + 4 * LINE;
}

/* a word whose line can't collide with either loop's code */
static void *data_word(bfn a, bfn b)
{
    for (uintptr_t off = 0; off < PAGE; off += LINE)
        if (clear_of(off, (void *)a, 160) && clear_of(off, (void *)b, 288))
            return scratch + off;
    return scratch;
}

static void cpu_class(const char *name, bfn f32, bfn f64, const char *sim)
{
    if (!want(name))
        return;
    void *w = data_word(f32, f64);
    unsigned n = chunk_n(f32, w, 1000);
    double a = best(f32, w, n, 30).us, b = best(f64, w, n, 30).us;
    double cyc = cycles((b - a) / 32);
    out(name, cyc, "cycles", "%.3f us; simulation with a 1-cycle bus: %s", cyc / CPU_HZ * 1e6, sim);
}

/* ---------------------------------------------------------------- cpu: C workloads */
static uint32_t crc_table[256];
static volatile uint32_t sink;

static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++)
            c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crc_table[i] = c;
    }
}

static uint8_t crc_data[1024];

static void crc_run(unsigned n, void *ctx)
{
    (void)ctx;
    uint32_t c = ~0u;
    while (n--)
        for (size_t i = 0; i < sizeof crc_data; i++)
            c = crc_table[(c ^ crc_data[i]) & 0xFF] ^ (c >> 8);
    sink = c;
}

static int cmp_int(const void *a, const void *b)
{
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}

#define QS_N 2048
static int qs_src[QS_N], qs_dst[QS_N];

static void qsort_run(unsigned n, void *ctx)
{
    (void)ctx;
    while (n--) {
        memcpy(qs_dst, qs_src, sizeof qs_dst);
        qsort(qs_dst, QS_N, sizeof(int), cmp_int);
    }
}

static uint32_t rnd_state = 12345;
static uint32_t rnd(void)
{
    rnd_state ^= rnd_state << 13;
    rnd_state ^= rnd_state >> 17;
    rnd_state ^= rnd_state << 5;
    return rnd_state;
}

static void cpu_tests(void)
{
    cpu_class("cpu.add", c_add_32, c_add_64, "12");
    cpu_class("cpu.lui", c_lui_32, c_lui_64, "12");
    cpu_class("cpu.slt", c_slt_32, c_slt_64, "20");
    cpu_class("cpu.slli", c_slli_32, c_slli_64, "20");
    cpu_class("cpu.srli_1", c_srli1_32, c_srli1_64, "20");
    cpu_class("cpu.srli_16", c_srli16_32, c_srli16_64, "24");
    cpu_class("cpu.srli_31", c_srli31_32, c_srli31_64, "27");
    cpu_class("cpu.branch_not_taken", c_bnt_32, c_bnt_64, "20");
    cpu_class("cpu.branch_taken", c_bt_32, c_bt_64, "20");
    cpu_class("cpu.jal", c_jal_32, c_jal_64, "20");
    cpu_class("cpu.lw", c_lw_32, c_lw_64, "22");
    cpu_class("cpu.lb", c_lb_32, c_lb_64, "22");
    cpu_class("cpu.sw", c_sw_32, c_sw_64, "22");
    cpu_class("cpu.sb", c_sb_32, c_sb_64, "22");
    cpu_class("cpu.mul", c_mul_32, c_mul_64, "23");
    cpu_class("cpu.mulh", c_mulh_32, c_mulh_64, "23");
    cpu_class("cpu.div", c_div_32, c_div_64, "55");
    cpu_class("cpu.amoadd", c_amo_32, c_amo_64, "26");
    cpu_class("cpu.lr_sc_pair", c_lrsc_32, c_lrsc_64, "23 + 23-24");
    cpu_class("cpu.rdtime", c_rdtime_32, c_rdtime_64, "12 (a CSR read)");
    cpu_class("cpu.fence", c_fence_32, c_fence_64, "- (a no-op)");
    if (want("cpu.crc32")) {
        for (size_t i = 0; i < sizeof crc_data; i++)
            crc_data[i] = (uint8_t)rnd();
        crc_init();
        struct res b = best(crc_run, 0, 1, 30), a = bench(crc_run, 0, 500000);
        out("cpu.crc32", 1.0 / b.us * 1e6, "KB/s", "best; avg %.1f KB/s (table-driven, 1 KB)",
            1.0 / a.us * 1e6);
    }
    if (want("cpu.qsort")) {
        for (int i = 0; i < QS_N; i++)
            qs_src[i] = (int)rnd();
        struct res a = bench(qsort_run, 0, 1000000);
        out("cpu.qsort", a.us / 1000, "ms", "avg; %d ints, libc qsort", QS_N);
    }
}

/* ---------------------------------------------------------------- os */
static void spin(unsigned n, void *p) { c_add_32(n, p); }

static void os_tick(void)
{
    if (!want("os.tick"))
        return;
    unsigned n = chunk_n(spin, 0, 500);
    uint32_t mn = ~0u, sum = 0, chunks = 0, prev = now(), start = prev;
    struct hw h0 = hw_now();
    while (now() - start < 2000000) {
        spin(n, 0);
        uint32_t t = now(), d = t - prev;
        prev = t;
        sum += d;
        chunks++;
        if (d < mn)
            mn = d;
    }
    struct hw h = hw_delta(h0);
    double lost = sum - (double)chunks * mn, ticks = sum / 1e6 * KERNEL_HZ;
    out("os.tick_share", 100.0 * lost / sum, "%",
        "of a busy loop's time goes to the kernel (the %d Hz tick) and other tasks", KERNEL_HZ);
    out("os.tick_cost", lost / ticks, "us", "per tick (%.0f cycles); %.0f cache misses, "
        "%.0f write-backs per tick", cycles(lost / ticks), h.miss / ticks, h.wb / ticks);
}

static void sys_getppid(unsigned n, void *c) { (void)c; while (n--) syscall(SYS_getppid); }
static void sys_clock(unsigned n, void *c)
{
    (void)c;
    struct timespec ts;
    while (n--)
        clock_gettime(CLOCK_MONOTONIC, &ts);
}

struct pp { int to[2], from[2]; };

static void pipe_rtt(unsigned n, void *ctx)
{
    struct pp *p = ctx;
    char c = 'x';
    while (n--)
        if (write(p->to[1], &c, 1) != 1 || read(p->from[0], &c, 1) != 1)
            exit(2);
}

static void yield_rtt(unsigned n, void *c) { (void)c; while (n--) sched_yield(); }

static void do_fork(unsigned n, void *c)
{
    (void)c;
    while (n--) {
        pid_t pid = fork();
        if (pid == 0)
            _exit(0);
        waitpid(pid, 0, 0);
    }
}

static void do_exec(unsigned n, void *c)
{
    (void)c;
    while (n--) {
        pid_t pid = vfork();
        if (pid == 0) {
            execl("/bin/true", "true", (char *)0);
            _exit(127);
        }
        waitpid(pid, 0, 0);
    }
}

#define FAULT_PAGES 64
static void do_faults(unsigned n, void *c)
{
    (void)c;
    while (n--) {
        uint8_t *p = mmap(0, FAULT_PAGES * PAGE, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED)
            exit(3);
        for (size_t i = 0; i < FAULT_PAGES * PAGE; i += PAGE)
            p[i] = 1;
        munmap(p, FAULT_PAGES * PAGE);
    }
}

#define FILE_BYTES (128 * 1024)
static char iobuf[4096];

static void file_write(unsigned n, void *c)
{
    (void)c;
    while (n--) {
        int fd = open("/tmp/qperf.dat", O_WRONLY | O_CREAT | O_TRUNC, 0600);
        for (int i = 0; i < FILE_BYTES / 4096; i++)
            if (write(fd, iobuf, 4096) != 4096)
                exit(4);
        close(fd);
    }
}

static void file_read(unsigned n, void *c)
{
    (void)c;
    while (n--) {
        int fd = open("/tmp/qperf.dat", O_RDONLY);
        while (read(fd, iobuf, 4096) > 0)
            ;
        close(fd);
    }
}

/* avg over target_us and best of `runs` runs of n_best; per op (divided by per) */
static void os_op(const char *name, bfn f, void *ctx, uint32_t target_us, unsigned n_best,
                  int runs, double per, double scale, const char *unit, const char *what)
{
    struct res a = bench(f, ctx, target_us), b = best(f, ctx, n_best, runs);
    double ops = (double)n_best * per;
    out(name, a.us / per * scale, unit, "avg; best %.3f (%.3g cycles, %.0f misses); %s",
        b.us / per * scale, cycles(b.us / per), b.hw.miss / ops, what);
}

static void os_tests(void)
{
    os_tick();
    if (want("os.syscall"))
        os_op("os.syscall", sys_getppid, 0, 300000, 10, 50, 1, 1, "us", "getppid()");
    if (want("os.clock_gettime"))
        os_op("os.clock_gettime", sys_clock, 0, 300000, 10, 50, 1, 1, "us", "CLOCK_MONOTONIC");
    if (want("os.pipe")) {
        struct pp p;
        if (pipe(p.to) || pipe(p.from))
            exit(5);
        pid_t pid = fork();
        if (pid == 0) {
            char c;
            close(p.to[1]);
            while (read(p.to[0], &c, 1) == 1)
                if (write(p.from[1], &c, 1) != 1)
                    break;
            _exit(0);
        }
        close(p.to[0]);
        close(p.from[1]);
        os_op("os.pipe_round_trip", pipe_rtt, &p, 1000000, 1, 40, 1, 1, "us",
              "1 byte there and back between 2 processes (4 syscalls, 2 switches)");
        close(p.to[1]);
        waitpid(pid, 0, 0);
        close(p.from[0]);
    }
    if (want("os.yield")) {
        pid_t pid = fork();
        if (pid == 0)
            for (;;)
                sched_yield();
        os_op("os.yield_round_trip", yield_rtt, 0, 1000000, 1, 40, 1, 1, "us",
              "sched_yield() with a second process yielding back (2 syscalls, 2 switches)");
        kill(pid, SIGKILL);
        waitpid(pid, 0, 0);
    }
    if (want("os.fork"))
        os_op("os.fork", do_fork, 0, 1000000, 1, 8, 1, 1e-3, "ms", "fork + _exit + waitpid");
    if (want("os.exec"))
        os_op("os.exec", do_exec, 0, 1500000, 1, 8, 1, 1e-3, "ms",
              "vfork + exec /bin/true (busybox) + waitpid");
    if (want("os.page_fault"))
        os_op("os.page_fault", do_faults, 0, 500000, 1, 8, FAULT_PAGES, 1, "us",
              "first write to an anonymous page (a zeroed frame), mmap/munmap included");
    if (want("os.tmpfs")) {
        memset(iobuf, 0x5A, sizeof iobuf);
        struct res w = bench(file_write, 0, 500000);
        struct res r = bench(file_read, 0, 500000);
        unlink("/tmp/qperf.dat");
        out("os.tmpfs_write", FILE_BYTES / w.us * 1e6 / 1024, "KB/s", "avg; 128 KB in 4 KB writes");
        out("os.tmpfs_read", FILE_BYTES / r.us * 1e6 / 1024, "KB/s", "avg; 128 KB in 4 KB reads");
    }
}

/* ---------------------------------------------------------------- mem: latency */
static uint32_t **__attribute__((noinline)) chase(uint32_t **p, unsigned n)
{
    while (n--) {
        p = (uint32_t **)*p; p = (uint32_t **)*p; p = (uint32_t **)*p; p = (uint32_t **)*p;
        p = (uint32_t **)*p; p = (uint32_t **)*p; p = (uint32_t **)*p; p = (uint32_t **)*p;
        p = (uint32_t **)*p; p = (uint32_t **)*p; p = (uint32_t **)*p; p = (uint32_t **)*p;
        p = (uint32_t **)*p; p = (uint32_t **)*p; p = (uint32_t **)*p; p = (uint32_t **)*p;
    }
    return p;
}

struct ch { uint32_t **at; };
static void chase_run(unsigned n, void *ctx)
{
    struct ch *c = ctx;
    c->at = chase(c->at, n);
}

static void mem_latency(void)
{
    if (!want("mem.latency_"))
        return;
    static const unsigned kb[] = {2, 4, 8, 12, 16, 20, 24, 32, 64, 128, 256, 512, 1024};
    const unsigned pages = 1024 * 1024 / PAGE, lpp = PAGE / LINE;
    uint8_t *buf = colored_buffer(pages, col_rr);
    uint32_t *order = malloc(pages * lpp * sizeof *order);
    int8_t *pc = malloc(pages);
    if (!buf || !order || !pc) {
        out("mem.latency", 0, "-", "no memory");
        return;
    }
    for (unsigned p = 0; p < pages; p++)
        pc[p] = (int8_t)color_of(buf + (size_t)p * PAGE);
    int cc = color_of((void *)chase);
    for (size_t i = 0; i < sizeof kb / sizeof kb[0]; i++) {
        char name[32];
        snprintf(name, sizeof name, "mem.latency_%uk", kb[i]);
        if (!want(name))
            continue;
        unsigned lines = kb[i] * 1024 / LINE, m = 0, skipped = 0;
        for (unsigned k = 0; k < lines; k++) {
            /* leave out the lines that share a cache line with the chase code */
            if (cc >= 0 && pc[k / lpp] == cc && !clear_of((k % lpp) * LINE, (void *)chase, 96)) {
                skipped++;
                continue;
            }
            order[m++] = k;
        }
        for (unsigned k = m - 1; k > 0; k--) {           /* random order (Fisher-Yates) */
            unsigned j = rnd() % (k + 1), t = order[k];
            order[k] = order[j];
            order[j] = t;
        }
        for (unsigned k = 0; k < m; k++)
            *(uint8_t **)(buf + order[k] * LINE) = buf + order[(k + 1) % m] * LINE;
        struct ch c = {(uint32_t **)(buf + order[0] * LINE)};
        chase_run(m / 16 + 1, &c);                       /* one lap to warm up */
        unsigned n = chunk_n(chase_run, &c, 1000);
        struct res r = best(chase_run, &c, n, 40);
        double loads = 16.0 * n, us = r.us / 16;
        out(name, cycles(us), "cycles", "%.3f us per load; %.2f misses, %.2f write-backs "
            "per load (%u of %u lines)", us, r.hw.miss / loads, r.hw.wb / loads, m, lines);
    }
    free(pc);
    free(order);
    munmap(buf, (size_t)pages * PAGE);
}

/* ---------------------------------------------------------------- mem: bandwidth */
static void __attribute__((noinline)) read_words(const uint8_t *b, size_t len)
{
    const uint32_t *p = (const uint32_t *)b, *e = p + len / 4;
    uint32_t s = 0;
    for (; p < e; p += 8)
        s += p[0] + p[1] + p[2] + p[3] + p[4] + p[5] + p[6] + p[7];
    sink = s;
}

static void __attribute__((noinline)) write_words(uint8_t *b, size_t len)
{
    volatile uint32_t *p = (volatile uint32_t *)b, *e = p + len / 4;
    for (; p < e; p += 8) {
        p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 0;
        p[4] = 0; p[5] = 0; p[6] = 0; p[7] = 0;
    }
}

enum { OP_READ, OP_WRITE, OP_COPY, OP_SET };
struct stream { uint8_t *dst, *src; size_t len, piece, off; int op; };

/* n pieces, each at the next offset (wrapping at len) */
static void stream_run(unsigned n, void *ctx)
{
    struct stream *s = ctx;
    while (n--) {
        uint8_t *d = s->dst + s->off;
        switch (s->op) {
        case OP_READ: read_words(d, s->piece); break;
        case OP_WRITE: write_words(d, s->piece); break;
        case OP_COPY: memcpy(d, s->src + s->off, s->piece); break;
        default: memset(d, (int)n, s->piece); break;
        }
        s->off += s->piece;
        if (s->off >= s->len)
            s->off = 0;
    }
}

static void bw(const char *name, int op, uint8_t *dst, uint8_t *src, size_t len, size_t piece,
               const char *what)
{
    if (!want(name))
        return;
    struct stream s = {dst, src, len, piece, 0, op};
    stream_run(len / piece, &s);                         /* one lap to warm up */
    struct res r = best(stream_run, &s, 1, 40);
    out(name, piece / r.us * 1e6 / 1024, "KB/s", "%s; %.2f misses, %.2f write-backs per 32 B",
        what, r.hw.miss * (double)LINE / piece, r.hw.wb * (double)LINE / piece);
}

static void mem_bandwidth(void)
{
    if (!want("mem.") || !(want("mem.read") || want("mem.write") || want("mem.memcpy") ||
                           want("mem.memset") || want("mem.fb_")))
        return;
    const unsigned big = 256;                            /* pages: 1 MB */
    uint8_t *b;

    avoid_code((void *)read_words);                      /* 8 KB, in the cache */
    if ((b = colored_buffer(2, col_list))) {
        bw("mem.read_8k", OP_READ, b, 0, 2 * PAGE, 2 * PAGE, "word loads, in the cache");
        bw("mem.write_8k", OP_WRITE, b, 0, 2 * PAGE, 2 * PAGE, "word stores, in the cache");
        munmap(b, 2 * PAGE);
    }
    avoid_code((void *)memcpy);
    if ((b = colored_buffer(2, col_list))) {
        bw("mem.memcpy_4k", OP_COPY, b, b + PAGE, PAGE, PAGE, "libc memcpy, 4 KB, in the cache");
        munmap(b, 2 * PAGE);
    }
    avoid_code((void *)memset);
    if ((b = colored_buffer(2, col_list))) {
        bw("mem.memset_8k", OP_SET, b, 0, 2 * PAGE, 2 * PAGE, "libc memset, in the cache");
        munmap(b, 2 * PAGE);
    }
    if ((b = colored_buffer(big, col_rr))) {             /* 1 MB, streamed in 8 KB pieces */
        size_t len = (size_t)big * PAGE;
        bw("mem.read_1m", OP_READ, b, 0, len, 2 * PAGE, "word loads from PSRAM");
        bw("mem.write_1m", OP_WRITE, b, 0, len, 2 * PAGE, "word stores to PSRAM (write-allocate)");
        bw("mem.memset_1m", OP_SET, b, 0, len, 2 * PAGE, "libc memset to PSRAM");
        bw("mem.memcpy_512k_conflict", OP_COPY, b, b + len / 2, len / 2, PAGE,
           "libc memcpy, source and destination pages of the same colours (thrashing)");
        munmap(b, len);
    }
    split_at = big / 2;
    if ((b = colored_buffer(big, col_split))) {
        size_t len = (size_t)big * PAGE;
        bw("mem.memcpy_512k", OP_COPY, b, b + len / 2, len / 2, PAGE,
           "libc memcpy, PSRAM to PSRAM, pages of different colours");
        munmap(b, len);
    }

    if (!want("mem.fb_"))                                /* uncached: 0x9070_0000 */
        return;
    int fd = open("/dev/fb0", O_RDWR);
    size_t fbl = 640 * 480 * 2;
    uint8_t *fb = fd < 0 ? MAP_FAILED : mmap(0, fbl, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (fb == MAP_FAILED) {
        out("mem.fb", 0, "-", "no /dev/fb0");
    } else {
        bw("mem.fb_write", OP_WRITE, fb, 0, fbl, 2 * PAGE, "word stores to /dev/fb0 (uncached)");
        bw("mem.fb_read", OP_READ, fb, 0, fbl, 2 * PAGE, "word loads from /dev/fb0 (uncached)");
        munmap(fb, fbl);
    }
    if (fd >= 0)
        close(fd);
}

int main(int argc, char **argv)
{
    filters = argv + 1;
    nfilters = argc - 1;
    time_init();
    hw_init();
    colors_init();
    printf("# qperf: CPU %.0f MHz assumed; timer %s; SoC counters %s; page colours %s\n",
           CPU_HZ / 1e6, use_rdtime ? "rdtime (1 MHz)" : "clock_gettime",
           sysc ? "yes" : "no (/dev/mem)", colors_ok ? "yes" : "no (pagemap)");
    fflush(stdout);
    uint32_t t0 = now();
    cpu_tests();
    os_tests();
    mem_latency();
    mem_bandwidth();
    printf("# done in %.1f s\n", (now() - t0) / 1e6);
    return 0;
}
