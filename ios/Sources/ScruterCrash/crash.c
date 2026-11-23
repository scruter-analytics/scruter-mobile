// Scruter Analytics: crash handlers of the iOS SDK (docs/MOBILE.md §3.10). See ScruterCrash.h.
//
// Everything that runs at the crash is async-signal-safe: no allocation, no lock, no Objective-C or Swift, only
// write(2), Mach traps and memory read through vm_read_overwrite. The binary images are described ahead of time (one
// pre-formatted line each, built when dyld loads them) and the context is a double buffer the SDK updates.
//
// Report format (text, one item per line):
//   SCRUTER-CRASH 1
//   time <ms since 1970>        kind crash            type EXC_BAD_ACCESS
//   code KERN_INVALID_ADDRESS   sig SIGSEGV           reason <one line>
//   ctx <one line of JSON>
//   thread <crashed 0|1> <main 0|1>, then one "f 0x<return address>" per frame
//   img 0x<load address> 0x<__TEXT size> <UUID> <arch> <in app 0|1> <name>
//   end

#include "ScruterCrash.h"

#if defined(__APPLE__)

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define SC_MAX_FRAMES 64
#define SC_MAX_IMAGES 1024
#define SC_CONTEXT_SIZE 4096
#define SC_LINE 240

// ---------------------------------------------------------------------------------------------------- state

static int g_fd = -1;
static atomic_int g_installed = 0;
static atomic_flag g_handled = ATOMIC_FLAG_INIT;
static thread_t g_main_thread = MACH_PORT_NULL;

static char g_context[2][SC_CONTEXT_SIZE];
static size_t g_context_len[2];
static atomic_int g_context_index = 0;
static pthread_mutex_t g_context_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    uintptr_t load;
    uintptr_t size;
    char line[SC_LINE];
    size_t len;
} sc_image;

static sc_image g_images[SC_MAX_IMAGES];
static atomic_int g_image_count = 0;
static char g_bundle_dir[1024];
static size_t g_bundle_dir_len = 0;

static const int g_signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP};
#define SC_SIGNAL_COUNT (sizeof(g_signals) / sizeof(g_signals[0]))
static struct sigaction g_previous[SC_SIGNAL_COUNT];
static char g_altstack[65536];

static mach_port_t g_exception_port = MACH_PORT_NULL;
static pthread_t g_mach_thread;

// ---------------------------------------------------------------------------------------------------- writing

typedef struct {
    char buf[2048];
    size_t len;
} sc_writer;

static void w_flush(sc_writer *w) {
    size_t off = 0;
    while (off < w->len) {
        ssize_t n = write(g_fd, w->buf + off, w->len - off);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            break;
        }
        off += (size_t)n;
    }
    w->len = 0;
}

static void w_bytes(sc_writer *w, const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (w->len == sizeof(w->buf)) w_flush(w);
        w->buf[w->len++] = s[i];
    }
}

static void w_str(sc_writer *w, const char *s) {
    if (s) w_bytes(w, s, strlen(s));
}

/// A string on one line: newlines and other control characters become spaces, ≤ max bytes.
static void w_line_str(sc_writer *w, const char *s, size_t max) {
    if (!s) return;
    for (size_t i = 0; s[i] && i < max; i++) {
        char c = s[i];
        if ((unsigned char)c < 0x20) c = ' ';
        w_bytes(w, &c, 1);
    }
}

static void w_hex(sc_writer *w, uint64_t v) {
    char tmp[19];
    int i = 18;
    tmp[i] = 0;
    do {
        tmp[--i] = "0123456789abcdef"[v & 0xF];
        v >>= 4;
    } while (v && i > 2);
    tmp[--i] = 'x';
    tmp[--i] = '0';
    w_str(w, tmp + i);
}

static void w_dec(sc_writer *w, uint64_t v) {
    char tmp[21];
    int i = 20;
    tmp[i] = 0;
    do {
        tmp[--i] = (char)('0' + v % 10);
        v /= 10;
    } while (v && i > 0);
    w_str(w, tmp + i);
}

// ---------------------------------------------------------------------------------------------------- stacks

#if defined(__arm64__)
// Pointer-authentication bits of return addresses in arm64e system libraries.
#define SC_PAC_MASK 0x0000000FFFFFFFFFULL
#else
#define SC_PAC_MASK 0xFFFFFFFFFFFFFFFFULL
#endif

static uintptr_t strip(uintptr_t a) { return (uintptr_t)(a & SC_PAC_MASK); }

static int safe_read(uintptr_t addr, void *out, size_t size) {
    vm_size_t got = 0;
    kern_return_t kr =
        vm_read_overwrite(mach_task_self(), (vm_address_t)addr, (vm_size_t)size, (vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == size;
}

/// The frames of a thread: its pc, its link register when the frame chain does not hold it yet (a leaf function),
/// then the return addresses of the frame-pointer chain.
static size_t walk(uintptr_t pc, uintptr_t lr, uintptr_t fp, uintptr_t *out, size_t max) {
    size_t n = 0;
    if (pc && n < max) out[n++] = strip(pc);
    uintptr_t first = 0;
    int have_first = 0;
    {
        uintptr_t frame[2];
        if (fp && safe_read(fp, frame, sizeof frame)) {
            first = strip(frame[1]);
            have_first = 1;
        }
    }
    if (lr && n < max && (!have_first || strip(lr) != first)) out[n++] = strip(lr);
    for (int i = 0; n < max && fp && i < 1024; i++) {
        uintptr_t frame[2];
        if (!safe_read(fp, frame, sizeof frame)) break;
        uintptr_t ret = strip(frame[1]);
        if (!ret) break;
        out[n++] = ret;
        if (frame[0] <= fp) break;  // The stack grows down: the caller's frame is above.
        fp = frame[0];
    }
    return n;
}

static int thread_registers(thread_t t, uintptr_t *pc, uintptr_t *lr, uintptr_t *fp) {
#if defined(__arm64__)
    arm_thread_state64_t st;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(t, ARM_THREAD_STATE64, (thread_state_t)&st, &count) != KERN_SUCCESS) return 0;
    *pc = (uintptr_t)arm_thread_state64_get_pc(st);
    *lr = (uintptr_t)arm_thread_state64_get_lr(st);
    *fp = (uintptr_t)arm_thread_state64_get_fp(st);
    return 1;
#elif defined(__x86_64__)
    x86_thread_state64_t st;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(t, x86_THREAD_STATE64, (thread_state_t)&st, &count) != KERN_SUCCESS) return 0;
    *pc = (uintptr_t)st.__rip;
    *lr = 0;
    *fp = (uintptr_t)st.__rbp;
    return 1;
#else
    (void)t;
    *pc = *lr = *fp = 0;
    return 0;
#endif
}

static int context_registers(void *ctx, uintptr_t *pc, uintptr_t *lr, uintptr_t *fp) {
    ucontext_t *uc = (ucontext_t *)ctx;
    if (!uc || !uc->uc_mcontext) return 0;
#if defined(__arm64__)
    *pc = (uintptr_t)arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
    *lr = (uintptr_t)arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
    *fp = (uintptr_t)arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
    return 1;
#elif defined(__x86_64__)
    *pc = (uintptr_t)uc->uc_mcontext->__ss.__rip;
    *lr = 0;
    *fp = (uintptr_t)uc->uc_mcontext->__ss.__rbp;
    return 1;
#else
    return 0;
#endif
}

/// Until when reports are not written (scruter_crash_mute), ms since the epoch.
static _Atomic uint64_t g_muted_until = 0;

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static void write_frames(sc_writer *w, const uintptr_t *frames, size_t n) {
    for (size_t i = 0; i < n && i < SC_MAX_FRAMES; i++) {
        w_str(w, "f ");
        w_hex(w, (uint64_t)frames[i]);
        w_str(w, "\n");
    }
}

/// Writes the whole report. `crashed` is the crashed thread (its frames given), `crashed_is_main` whether it is the
/// main thread; the main thread's stack is added when it is another one.
static void write_report(const char *kind, const char *type, const char *code, const char *sig, const char *reason,
                         thread_t crashed, int crashed_is_main, const uintptr_t *frames, size_t frame_count) {
    if (g_fd < 0 || now_ms() < atomic_load(&g_muted_until)) return;
    lseek(g_fd, 0, SEEK_SET);
    ftruncate(g_fd, 0);
    sc_writer w;
    w.len = 0;
    w_str(&w, "SCRUTER-CRASH 1\ntime ");
    w_dec(&w, now_ms());
    w_str(&w, "\nkind ");
    w_str(&w, kind);
    if (type && *type) {
        w_str(&w, "\ntype ");
        w_line_str(&w, type, 200);
    }
    if (code && *code) {
        w_str(&w, "\ncode ");
        w_line_str(&w, code, 200);
    }
    if (sig && *sig) {
        w_str(&w, "\nsig ");
        w_str(&w, sig);
    }
    if (reason && *reason) {
        w_str(&w, "\nreason ");
        w_line_str(&w, reason, 600);
    }
    int ci = atomic_load(&g_context_index);
    if (g_context_len[ci] > 0) {
        w_str(&w, "\nctx ");
        w_bytes(&w, g_context[ci], g_context_len[ci]);
    }
    w_str(&w, "\nthread 1 ");
    w_str(&w, crashed_is_main ? "1\n" : "0\n");
    write_frames(&w, frames, frame_count);
    if (!crashed_is_main && g_main_thread != MACH_PORT_NULL && g_main_thread != crashed) {
        uintptr_t main_frames[SC_MAX_FRAMES];
        size_t n = 0;
        if (thread_suspend(g_main_thread) == KERN_SUCCESS) {
            uintptr_t pc, lr, fp;
            if (thread_registers(g_main_thread, &pc, &lr, &fp)) n = walk(pc, lr, fp, main_frames, SC_MAX_FRAMES);
            thread_resume(g_main_thread);
        }
        if (n > 0) {
            w_str(&w, "thread 0 1\n");
            write_frames(&w, main_frames, n);
        }
    }
    int count = atomic_load(&g_image_count);
    for (int i = 0; i < count && i < SC_MAX_IMAGES; i++) w_bytes(&w, g_images[i].line, g_images[i].len);
    w_str(&w, "end\n");
    w_flush(&w);
    fsync(g_fd);
}

// ---------------------------------------------------------------------------------------------------- images

static const char *arch_name(cpu_type_t type, cpu_subtype_t subtype) {
    if (type == CPU_TYPE_ARM64) return (subtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E ? "arm64e" : "arm64";
    if (type == CPU_TYPE_X86_64) return "x86_64";
    if (type == CPU_TYPE_ARM) return "armv7";
    return "unknown";
}

static void on_add_image(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (header->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *h = (const struct mach_header_64 *)header;
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname) return;
    const char *path = info.dli_fname;
    if (h->filetype == MH_EXECUTE && g_bundle_dir_len == 0) {
        const char *slash = strrchr(path, '/');
        size_t len = slash ? (size_t)(slash - path) : 0;
        if (len > 0 && len < sizeof(g_bundle_dir) - 1) {
            memcpy(g_bundle_dir, path, len);
            g_bundle_dir[len] = '/';
            g_bundle_dir_len = len + 1;
            g_bundle_dir[g_bundle_dir_len] = 0;
        }
    }
    uint8_t uuid[16];
    int has_uuid = 0;
    uint64_t text_size = 0;
    const uint8_t *cmd = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd == LC_UUID) {
            memcpy(uuid, ((const struct uuid_command *)lc)->uuid, 16);
            has_uuid = 1;
        } else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_TEXT) == 0) text_size = seg->vmsize;
        }
        cmd += lc->cmdsize;
    }
    if (!has_uuid) return;
    int index = atomic_load(&g_image_count);
    if (index >= SC_MAX_IMAGES) return;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    int in_app = g_bundle_dir_len > 0 && strncmp(path, g_bundle_dir, g_bundle_dir_len) == 0;
    sc_image *img = &g_images[index];
    img->load = (uintptr_t)header;
    img->size = (uintptr_t)text_size;
    int n = snprintf(img->line, sizeof(img->line),
                     "img 0x%lx 0x%llx %02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X %s %d %s\n",
                     (unsigned long)img->load, (unsigned long long)text_size, uuid[0], uuid[1], uuid[2], uuid[3],
                     uuid[4], uuid[5], uuid[6], uuid[7], uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13],
                     uuid[14], uuid[15], arch_name(h->cputype, h->cpusubtype), in_app, name);
    if (n <= 0) return;
    if ((size_t)n >= sizeof(img->line)) {
        img->line[sizeof(img->line) - 2] = '\n';
        img->line[sizeof(img->line) - 1] = 0;
        n = (int)sizeof(img->line) - 1;
    }
    img->len = (size_t)n;
    atomic_store(&g_image_count, index + 1);
}

// ---------------------------------------------------------------------------------------------------- signals

static const char *signal_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS: return "SIGBUS";
        case SIGILL: return "SIGILL";
        case SIGABRT: return "SIGABRT";
        case SIGFPE: return "SIGFPE";
        case SIGTRAP: return "SIGTRAP";
        default: return "SIGNAL";
    }
}

static const char *signal_exception(int sig) {
    switch (sig) {
        case SIGSEGV:
        case SIGBUS: return "EXC_BAD_ACCESS";
        case SIGILL: return "EXC_BAD_INSTRUCTION";
        case SIGFPE: return "EXC_ARITHMETIC";
        case SIGTRAP: return "EXC_BREAKPOINT";
        case SIGABRT: return "EXC_CRASH";
        default: return "EXC_CRASH";
    }
}

static const char *signal_code(int sig, int code) {
    if (sig == SIGSEGV) return code == SEGV_ACCERR ? "SEGV_ACCERR" : "SEGV_MAPERR";
    if (sig == SIGBUS) return code == BUS_ADRERR ? "BUS_ADRERR" : code == BUS_OBJERR ? "BUS_OBJERR" : "BUS_ADRALN";
    if (sig == SIGFPE) return code == FPE_INTDIV ? "FPE_INTDIV" : "FPE_FLTINV";
    return "";
}

static void on_signal(int sig, siginfo_t *info, void *context) {
    if (!atomic_flag_test_and_set(&g_handled)) {
        uintptr_t frames[SC_MAX_FRAMES];
        size_t n = 0;
        uintptr_t pc, lr, fp;
        if (context_registers(context, &pc, &lr, &fp)) n = walk(pc, lr, fp, frames, SC_MAX_FRAMES);
        write_report("crash", signal_exception(sig), info ? signal_code(sig, info->si_code) : "", signal_name(sig), "",
                     mach_thread_self(), pthread_main_np(), frames, n);
    }
    // Chain: the previous handler (another crash reporter), else the default action. A fault happens again when the
    // handler returns and reaches it; a signal sent by abort() or raise() is sent again.
    for (size_t i = 0; i < SC_SIGNAL_COUNT; i++) {
        if (g_signals[i] != sig) continue;
        struct sigaction prev = g_previous[i];
        if (!(prev.sa_flags & SA_SIGINFO) && prev.sa_handler == SIG_IGN) prev.sa_handler = SIG_DFL;
        sigaction(sig, &prev, NULL);
    }
    if (!info || info->si_code == SI_USER) raise(sig);
}

// ---------------------------------------------------------------------------------------------------- Mach

#pragma pack(push, 4)
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t ndr;
    exception_type_t exception;
    mach_msg_type_number_t code_count;
    int64_t code[2];
    char padding[512];
} sc_exception_message;

typedef struct {
    mach_msg_header_t header;
    NDR_record_t ndr;
    kern_return_t result;
} sc_reply_message;
#pragma pack(pop)

static const char *mach_exception_name(exception_type_t e) {
    switch (e) {
        case EXC_BAD_ACCESS: return "EXC_BAD_ACCESS";
        case EXC_BAD_INSTRUCTION: return "EXC_BAD_INSTRUCTION";
        case EXC_ARITHMETIC: return "EXC_ARITHMETIC";
        case EXC_SOFTWARE: return "EXC_SOFTWARE";
        case EXC_BREAKPOINT: return "EXC_BREAKPOINT";
        default: return "EXC_CRASH";
    }
}

static const char *mach_exception_signal(exception_type_t e, int64_t code) {
    switch (e) {
        case EXC_BAD_ACCESS: return code == KERN_INVALID_ADDRESS ? "SIGSEGV" : "SIGBUS";
        case EXC_BAD_INSTRUCTION: return "SIGILL";
        case EXC_ARITHMETIC: return "SIGFPE";
        case EXC_BREAKPOINT: return "SIGTRAP";
        default: return "SIGABRT";
    }
}

static const char *mach_code_name(exception_type_t e, int64_t code) {
    if (e != EXC_BAD_ACCESS) return "";
    switch (code) {
        case KERN_INVALID_ADDRESS: return "KERN_INVALID_ADDRESS";
        case KERN_PROTECTION_FAILURE: return "KERN_PROTECTION_FAILURE";
        default: return "KERN_FAILURE";
    }
}

static void *mach_handler_thread(void *arg) {
    (void)arg;
    pthread_setname_np("net.scruter.crash");
    for (;;) {
        sc_exception_message msg;
        memset(&msg, 0, sizeof(msg));
        kern_return_t kr = mach_msg(&msg.header, MACH_RCV_MSG | MACH_RCV_LARGE, 0, sizeof(msg), g_exception_port,
                                    MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) {
            if (kr == MACH_RCV_INVALID_NAME || kr == MACH_RCV_PORT_DIED) return NULL;
            continue;
        }
        if (!atomic_flag_test_and_set(&g_handled)) {
            thread_t crashed = msg.thread.name;
            uintptr_t frames[SC_MAX_FRAMES];
            size_t n = 0;
            uintptr_t pc, lr, fp;
            if (thread_registers(crashed, &pc, &lr, &fp)) n = walk(pc, lr, fp, frames, SC_MAX_FRAMES);
            int64_t code = msg.code_count > 0 ? msg.code[0] : 0;
            write_report("crash", mach_exception_name(msg.exception), mach_code_name(msg.exception, code),
                         mach_exception_signal(msg.exception, code), "", crashed, crashed == g_main_thread, frames, n);
        }
        // Give the exception back: the kernel turns it into a signal, which the signal handlers chain.
        task_set_exception_ports(mach_task_self(),
                                 EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC |
                                     EXC_MASK_SOFTWARE | EXC_MASK_BREAKPOINT,
                                 MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
        sc_reply_message reply;
        memset(&reply, 0, sizeof(reply));
        reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(msg.header.msgh_bits), 0);
        reply.header.msgh_remote_port = msg.header.msgh_remote_port;
        reply.header.msgh_local_port = MACH_PORT_NULL;
        reply.header.msgh_size = sizeof(reply);
        reply.header.msgh_id = msg.header.msgh_id + 100;
        reply.ndr = NDR_record;
        reply.result = KERN_FAILURE;
        mach_msg(&reply.header, MACH_SEND_MSG, sizeof(reply), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE,
                 MACH_PORT_NULL);
    }
    return NULL;
}

static int debugger_attached(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return 0;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

static int install_mach(void) {
    exception_mask_t mask =
        EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_SOFTWARE | EXC_MASK_BREAKPOINT;
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_port_t ports[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    if (task_get_exception_ports(mach_task_self(), mask, masks, &count, ports, behaviors, flavors) != KERN_SUCCESS)
        return 0;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        // Another crash reporter (or a debugger) holds the exception ports: leave them to it, signals still report.
        if (MACH_PORT_VALID(ports[i])) return 0;
    }
    if (debugger_attached()) return 0;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_exception_port) != KERN_SUCCESS) return 0;
    if (mach_port_insert_right(mach_task_self(), g_exception_port, g_exception_port, MACH_MSG_TYPE_MAKE_SEND) !=
        KERN_SUCCESS)
        return 0;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int ok = pthread_create(&g_mach_thread, &attr, mach_handler_thread, NULL) == 0;
    pthread_attr_destroy(&attr);
    if (!ok) return 0;
    if (task_set_exception_ports(mach_task_self(), mask, g_exception_port,
                                 (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES),
                                 THREAD_STATE_NONE) != KERN_SUCCESS)
        return 0;
    return 1;
}

// ---------------------------------------------------------------------------------------------------- API

int scruter_crash_install(const char *report_path, int use_mach) {
    if (atomic_load(&g_installed)) return 0;
    if (!report_path) return -1;
    g_fd = open(report_path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (g_fd < 0) return -1;
    // Installed from the main thread (the SDK does): its Mach port names the main thread in reports.
    if (pthread_main_np()) g_main_thread = pthread_mach_thread_np(pthread_self());
    _dyld_register_func_for_add_image(on_add_image);

    stack_t ss;
    memset(&ss, 0, sizeof(ss));
    ss.ss_sp = g_altstack;
    ss.ss_size = sizeof(g_altstack);
    sigaltstack(&ss, NULL);
    for (size_t i = 0; i < SC_SIGNAL_COUNT; i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = on_signal;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&sa.sa_mask);
        sigaction(g_signals[i], &sa, &g_previous[i]);
    }
    int mach = use_mach ? install_mach() : 0;
    atomic_store(&g_installed, mach ? 2 : 1);
    return 0;
}

void scruter_crash_uninstall(void) {
    if (!atomic_load(&g_installed)) return;
    for (size_t i = 0; i < SC_SIGNAL_COUNT; i++) sigaction(g_signals[i], &g_previous[i], NULL);
    if (g_exception_port != MACH_PORT_NULL) {
        task_set_exception_ports(mach_task_self(),
                                 EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC |
                                     EXC_MASK_SOFTWARE | EXC_MASK_BREAKPOINT,
                                 MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
    }
    atomic_store(&g_installed, 0);
}

int scruter_crash_installed(void) { return atomic_load(&g_installed); }

void scruter_crash_mute(uint32_t milliseconds) { atomic_store(&g_muted_until, now_ms() + milliseconds); }

void scruter_crash_set_context(const char *json, size_t length) {
    if (!json) return;
    pthread_mutex_lock(&g_context_lock);
    int next = 1 - atomic_load(&g_context_index);
    size_t n = length < SC_CONTEXT_SIZE ? length : SC_CONTEXT_SIZE;
    for (size_t i = 0; i < n; i++) {
        char c = json[i];
        g_context[next][i] = (c == '\n' || c == '\r') ? ' ' : c;
    }
    g_context_len[next] = n;
    atomic_store(&g_context_index, next);
    pthread_mutex_unlock(&g_context_lock);
}

int scruter_crash_write_exception(const char *type, const char *reason, const uintptr_t *addresses, size_t count) {
    if (atomic_flag_test_and_set(&g_handled)) return -1;
    uintptr_t frames[SC_MAX_FRAMES];
    size_t n = 0;
    for (size_t i = 0; i < count && n < SC_MAX_FRAMES; i++) frames[n++] = strip(addresses[i]);
    write_report("crash", type ? type : "NSException", "", "SIGABRT", reason, mach_thread_self(), pthread_main_np(),
                 frames, n);
    return 0;
}

int scruter_crash_write_test_report(const char *type) {
    uintptr_t frames[SC_MAX_FRAMES];
    uintptr_t fp = (uintptr_t)__builtin_frame_address(0);
    uintptr_t pc = (uintptr_t)__builtin_return_address(0);
    size_t n = walk(pc, 0, fp, frames, SC_MAX_FRAMES);
    write_report("nonfatal", type ? type : "Test", "", "", "test report", mach_thread_self(), pthread_main_np(), frames,
                 n);
    return 0;
}

#else  // Not an Apple platform: the core is tested on Linux, the handlers only exist on iOS.

int scruter_crash_install(const char *report_path, int use_mach) {
    (void)report_path;
    (void)use_mach;
    return -1;
}
void scruter_crash_uninstall(void) {}
void scruter_crash_mute(uint32_t milliseconds) { (void)milliseconds; }
void scruter_crash_set_context(const char *json, size_t length) {
    (void)json;
    (void)length;
}
int scruter_crash_write_exception(const char *type, const char *reason, const uintptr_t *addresses, size_t count) {
    (void)type;
    (void)reason;
    (void)addresses;
    (void)count;
    return -1;
}
int scruter_crash_write_test_report(const char *type) {
    (void)type;
    return -1;
}
int scruter_crash_installed(void) { return 0; }

#endif
