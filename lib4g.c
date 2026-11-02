/*
 * low4g.c -- reserve all free address space below 4 GB at process start.
 *
 * WHY
 *   In a 64-bit process, a pointer that passed through a 32-bit int /
 *   unsigned / DWORD comes back as an address below 4 GB. In a non-PIE
 *   binary (GCC 4.9's default) the main malloc heap lives below 4 GB, so a
 *   truncated pointer to a small heap object often still "works" -- or
 *   silently scribbles on some other object. That is the intermittent,
 *   whack-a-mole behaviour.
 *
 *   With everything below 4 GB reserved PROT_NONE, the FIRST use of a
 *   truncated pointer segfaults, at the exact instruction that used it.
 *
 *   Intended side effect: glibc's main heap can no longer grow with brk, so
 *   malloc falls back to mmap and new heap memory lands above 4 GB.
 *   (A few KB of heap allocated before this runs may stay below 4 GB.)
 *
 * BUILD  (any gcc from 4.4 on; x86_64 or aarch64 Linux, glibc)
 *   gcc -std=gnu99 -O2 -fPIC -shared -o liblow4g.so low4g.c
 *
 * RUN    (no rebuild of the application)
 *   LD_PRELOAD=/abs/path/liblow4g.so ./your_app args...
 *   For a fully static binary, compile low4g.c into the binary instead;
 *   the constructor runs before the binary's own static initializers.
 *   LD_PRELOAD is inherited by child processes, so 64-bit helpers the app
 *   spawns get the same treatment.
 *
 * ENVIRONMENT
 *   LOW4G_DISABLE=1     do nothing
 *   LOW4G_QUIET=1       no startup summary on stderr
 *   LOW4G_NO_HANDLER=1  don't install the SIGSEGV/SIGBUS reporter
 *
 * DON'T COMBINE WITH
 *   - ASan or Valgrind runs: they manage the address space themselves, and
 *     ASan already turns most truncated pointers into a SEGV report.
 *   - Code that needs low memory on purpose: mmap(MAP_32BIT), some JITs
 *     (older LuaJIT), anything that asks for fixed low addresses.
 *   - A low `ulimit -v`: the reservation costs ~4 GB of address space
 *     (no RAM, no swap -- it is PROT_NONE and MAP_NORESERVE).
 *
 * If the application installs its own SIGSEGV handler after start-up, that
 * handler replaces this one; the reservation itself still works.
 */

#define _GNU_SOURCE
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#ifdef __GLIBC__
#include <malloc.h>
#endif

#if defined(__x86_64__) || defined(__aarch64__)

#define LOW4G_LIMIT ((uintptr_t)1 << 32)
#define MAX_GAPS 1024
#define DRAIN_CAP ((uintptr_t)16 << 20)   /* max leftover low heap to use up */

static uintptr_t g_reserved_bytes;
static unsigned  g_reserved_ranges;
static unsigned  g_failed_ranges;

/* ---------- async-signal-safe output helpers (no stdio, no malloc) ------ */

static void put_str(const char *s)
{
    ssize_t r = write(2, s, strlen(s));
    (void)r;
}

static void put_hex(uintptr_t v)
{
    static const char digits[] = "0123456789abcdef";
    char buf[19];
    int i;
    buf[0] = '0';
    buf[1] = 'x';
    for (i = 0; i < 16; i++)
        buf[2 + i] = digits[(v >> ((15 - i) * 4)) & 0xf];
    buf[18] = '\0';
    put_str(buf);
}

static void put_dec(uintptr_t v)
{
    char buf[24];
    int i = (int)sizeof(buf) - 1;
    buf[i] = '\0';
    do {
        buf[--i] = (char)('0' + (v % 10));
        v /= 10;
    } while (v != 0 && i > 0);
    put_str(buf + i);
}

static int env_set(const char *name)
{
    const char *v = getenv(name);
    return v != NULL && v[0] != '\0' && strcmp(v, "0") != 0;
}

/* ---------- reservation ------------------------------------------------- */

static uintptr_t page_size(void)
{
    long p = sysconf(_SC_PAGESIZE);
    return p > 0 ? (uintptr_t)p : 4096;
}

/* Lowest address the kernel lets user space map (vm.mmap_min_addr). */
static uintptr_t min_map_addr(void)
{
    char buf[32];
    uintptr_t v = 0, pg = page_size();
    ssize_t n;
    int i, fd = open("/proc/sys/vm/mmap_min_addr", O_RDONLY);

    if (fd >= 0) {
        n = read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (n > 0) {
            for (i = 0; i < n && buf[i] >= '0' && buf[i] <= '9'; i++)
                v = v * 10 + (uintptr_t)(buf[i] - '0');
        }
    }
    if (v < 65536)
        v = 65536;
    return (v + pg - 1) & ~(pg - 1);
}

static uintptr_t parse_hex(const char **pp)
{
    const char *p = *pp;
    uintptr_t v = 0;
    for (;;) {
        char c = *p;
        if (c >= '0' && c <= '9')      v = (v << 4) | (uintptr_t)(c - '0');
        else if (c >= 'a' && c <= 'f') v = (v << 4) | (uintptr_t)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v = (v << 4) | (uintptr_t)(c - 'A' + 10);
        else break;
        p++;
    }
    *pp = p;
    return v;
}

static void reserve_range(uintptr_t lo, uintptr_t hi)
{
    void *want, *got;
    size_t len;

    if (hi > LOW4G_LIMIT)
        hi = LOW4G_LIMIT;
    if (lo >= hi)
        return;
    want = (void *)lo;
    len = (size_t)(hi - lo);

    /* A hint without MAP_FIXED: the kernel uses the hint only if the whole
     * range is still free, so this can never clobber an existing mapping
     * (and works on old kernels that lack MAP_FIXED_NOREPLACE). */
    got = mmap(want, len, PROT_NONE,
               MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (got == want) {
        g_reserved_bytes += len;
        g_reserved_ranges++;
        return;
    }
    if (got != MAP_FAILED)
        munmap(got, len);
    g_failed_ranges++;
}

/* Collect the gaps below 4 GB from /proc/self/maps first, then map them.
 * (Mapping while still reading the file would shift what the kernel
 * reports mid-read.) */
static void reserve_low_gaps(void)
{
    static char buf[8192];
    static uintptr_t gap_lo[MAX_GAPS], gap_hi[MAX_GAPS];
    unsigned ngaps = 0, i;
    size_t have = 0;
    ssize_t n;
    int fd, done = 0;
    uintptr_t cursor = min_map_addr();

    fd = open("/proc/self/maps", O_RDONLY);
    if (fd < 0)
        return;

    while (!done) {
        char *line, *nl;
        n = read(fd, buf + have, sizeof(buf) - 1 - have);
        if (n <= 0)
            break;
        have += (size_t)n;

        line = buf;
        while ((nl = memchr(line, '\n', (size_t)(buf + have - line))) != NULL) {
            const char *p = line;
            uintptr_t start, end;

            start = parse_hex(&p);
            if (*p == '-')
                p++;
            end = parse_hex(&p);
            line = nl + 1;

            if (start >= LOW4G_LIMIT) {
                done = 1;
                break;
            }
            if (start > cursor && ngaps < MAX_GAPS) {
                gap_lo[ngaps] = cursor;
                gap_hi[ngaps] = start;
                ngaps++;
            }
            if (end > cursor)
                cursor = end;
        }
        have = (size_t)(buf + have - line);
        memmove(buf, line, have);
    }
    close(fd);

    if (cursor < LOW4G_LIMIT && ngaps < MAX_GAPS) {
        gap_lo[ngaps] = cursor;
        gap_hi[ngaps] = LOW4G_LIMIT;
        ngaps++;
    }
    for (i = 0; i < ngaps; i++)
        reserve_range(gap_lo[i], gap_hi[i]);
}

/* ---------- use up the leftover low heap -------------------------------- */

#ifdef __GLIBC__

/* Whatever free space is left in the brk heap (its top end, and chunks that
 * were freed before we ran) would keep handing out addresses below 4 GB
 * forever, because freed chunks get recycled. Allocate it all and leak it:
 * usually a few KB. Requests of 8, 24, 40 ... 1032 bytes walk every tcache
 * and fastbin size class; the 8-byte pass also splits any larger free chunk.
 * A second round picks up the old top that glibc frees when it switches the
 * main arena from brk to mmap. */
static uintptr_t drain_low_heap(void)
{
    uintptr_t taken = 0, before;
    size_t req;
    int round;
    long guard;
    void *p;

    for (round = 0; round < 4; round++) {
        before = taken;
        for (req = 8; req <= 1032; req += 16) {
            for (guard = 0; guard < 1000000; guard++) {
                p = malloc(req);
                if (p == NULL)
                    break;
                if ((uintptr_t)p >= LOW4G_LIMIT) {
                    free(p);
                    break;
                }
                taken += malloc_usable_size(p);     /* leaked on purpose */
                if (taken > DRAIN_CAP)
                    return taken;   /* brk still growing? stop leaking */
            }
        }
        if (taken == before)
            break;
    }
    return taken;
}
#endif

/* ---------- fault reporter --------------------------------------------- */

static char g_altstack[64 * 1024];

static void on_fault(int sig, siginfo_t *si, void *ctx)
{
    void *frames[64];
    int n;
    uintptr_t a = (uintptr_t)si->si_addr;
    (void)ctx;

    put_str("\n==low4g== ");
    put_str(sig == SIGSEGV ? "SIGSEGV" : "SIGBUS");
    if (si->si_code <= 0) {
        /* sent with kill()/raise()/tgkill(), not a memory fault */
        put_str(" sent by pid ");
        put_dec((uintptr_t)si->si_pid);
        put_str(" (not a memory fault)\n");
        raise(sig);
        return;
    }
    put_str(" at address ");
    put_hex(a);
    put_str("\n==low4g== ");

    if (sig == SIGSEGV && si->si_code == SI_KERNEL)
        put_str("general protection fault: non-canonical address -- a garbage, "
                "uninitialized or overwritten pointer\n");
    else if (a < 4096)
        put_str("near NULL: null-pointer dereference (plus a small offset)\n");
    else if (a < LOW4G_LIMIT && sig == SIGSEGV && si->si_code == SEGV_ACCERR)
        put_str("hit the low-4GB reservation: almost certainly a pointer that "
                "was squeezed through a 32-bit integer\n");
    else if (a < LOW4G_LIMIT)
        put_str("below 4GB: likely a truncated pointer\n");
    else
        put_str("above 4GB: not a truncation -- look for use-after-free, "
                "overflow or a corrupted pointer (try the ASan build)\n");

    n = backtrace(frames, 64);
    put_str("==low4g== backtrace (resolve with: addr2line -Cfipe <binary> <addr>):\n");
    backtrace_symbols_fd(frames, n, 2);
    put_str("==low4g== end of report\n\n");

    /* SA_RESETHAND already restored the default action. For a real fault,
     * returning re-executes the instruction and the process dies with a core
     * dump as usual; raise() covers signals sent with kill(). */
    raise(sig);
}

static void install_fault_reporter(void)
{
    stack_t ss;
    struct sigaction sa;
    void *warm[2];

    /* backtrace() loads libgcc_s on first use; do that now, not in the
     * signal handler. */
    (void)backtrace(warm, 2);

    memset(&ss, 0, sizeof(ss));
    ss.ss_sp = g_altstack;
    ss.ss_size = sizeof(g_altstack);
    sigaltstack(&ss, NULL);

    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = on_fault;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
}

/* ---------- entry point ------------------------------------------------- */

__attribute__((constructor(101)))
static void low4g_init(void)
{
    void *probe;
    uintptr_t drained = 0;

    if (env_set("LOW4G_DISABLE"))
        return;

#ifdef __GLIBC__
    /* Hand unused memory at the top of the brk heap back to the kernel, so
     * the reservation starts right above what is actually in use. */
    malloc_trim(0);
#endif

    reserve_low_gaps();

#ifdef __GLIBC__
    drained = drain_low_heap();
#endif

    if (!env_set("LOW4G_NO_HANDLER"))
        install_fault_reporter();

    if (env_set("LOW4G_QUIET") && drained <= DRAIN_CAP)
        return;

    probe = malloc(64);
    put_str("==low4g== reserved ");
    put_dec(g_reserved_bytes >> 20);
    put_str(" MB below 4GB in ");
    put_dec(g_reserved_ranges);
    put_str(" range(s)");
    if (g_failed_ranges) {
        put_str(", ");
        put_dec(g_failed_ranges);
        put_str(" range(s) could not be reserved");
    }
    put_str("; used up ");
    put_dec(drained >> 10);
    put_str(" KB of leftover low heap");
    if (drained > DRAIN_CAP)
        put_str(" (WARNING: hit the cap, brk heap may still be growing)");
    put_str("; malloc test -> ");
    put_hex((uintptr_t)probe);
    put_str((uintptr_t)probe >= LOW4G_LIMIT ? " (above 4GB, good)\n"
                                            : " (WARNING: still below 4GB)\n");
    free(probe);
}

#endif /* 64-bit */
