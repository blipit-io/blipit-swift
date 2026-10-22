#include "BlipitNuggets.h"

#include <TargetConditionals.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

#define BN_MACH (!TARGET_OS_WATCH && !TARGET_OS_TV)
#define BN_MAX_IMAGES 2048
#define BN_MAX_FRAMES 128

typedef struct {
    uintptr_t base;
    uintptr_t size;
    uint8_t uuid[16];
    const char *path;
} bn_image;

static bn_image images[BN_MAX_IMAGES];
static volatile int image_count = 0;
static pthread_mutex_t image_lock = PTHREAD_MUTEX_INITIALIZER;
static char crash_path[1024];
static volatile int installed = 0;
static volatile int claimed = 0;
static mach_port_t main_port = MACH_PORT_NULL;

static const int signals[] = {SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP, SIGSYS};
#define BN_SIGNAL_COUNT (sizeof(signals) / sizeof(signals[0]))
static struct sigaction previous[BN_SIGNAL_COUNT];

static uintptr_t strip(uintptr_t p) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)p, ptrauth_key_return_address);
#else
    return p;
#endif
}

static int safe_read(uintptr_t addr, void *dst, size_t len) {
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)addr, (vm_size_t)len, (vm_address_t)dst, &got) == KERN_SUCCESS && got == len;
}

static int walk(uintptr_t pc, uintptr_t lr, uintptr_t fp, uintptr_t *out, int max) {
    int n = 0;
    if (pc && n < max) out[n++] = strip(pc);
    uintptr_t rec[2] = {0, 0};
    int have = fp && !(fp & 0x7) && safe_read(fp, rec, sizeof rec);
    if (lr && n < max && (!have || strip(rec[1]) != strip(lr))) out[n++] = strip(lr);
    while (have && n < max) {
        uintptr_t ret = strip(rec[1]);
        if (!ret) break;
        out[n++] = ret;
        if (rec[0] <= fp || (rec[0] & 0x7)) break;
        fp = rec[0];
        have = safe_read(fp, rec, sizeof rec);
    }
    return n;
}

static void on_image(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    bn_image image;
    memset(&image, 0, sizeof image);
    image.base = (uintptr_t)header;
    const uint8_t *cursor = (const uint8_t *)header + (header->magic == MH_MAGIC_64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header));
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, "__TEXT") == 0) image.size = (uintptr_t)seg->vmsize;
        } else if (cmd->cmd == LC_SEGMENT) {
            const struct segment_command *seg = (const struct segment_command *)cmd;
            if (strcmp(seg->segname, "__TEXT") == 0) image.size = (uintptr_t)seg->vmsize;
        } else if (cmd->cmd == LC_UUID) {
            memcpy(image.uuid, ((const struct uuid_command *)cmd)->uuid, 16);
        }
        cursor += cmd->cmdsize;
    }
    Dl_info info;
    if (dladdr(header, &info) && info.dli_fname) image.path = info.dli_fname;
    pthread_mutex_lock(&image_lock);
    if (image_count < BN_MAX_IMAGES) {
        images[image_count] = image;
        __atomic_store_n(&image_count, image_count + 1, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&image_lock);
}

static void track_images(void) {
    static int tracking = 0;
    if (__atomic_exchange_n(&tracking, 1, __ATOMIC_SEQ_CST)) return;
    _dyld_register_func_for_add_image(on_image);
}

static int image_of(uintptr_t addr) {
    int count = __atomic_load_n(&image_count, __ATOMIC_ACQUIRE);
    for (int i = 0; i < count; i++) {
        if (addr >= images[i].base && addr < images[i].base + images[i].size) return i;
    }
    return -1;
}

static void put(int fd, const char *s) {
    size_t len = 0;
    while (s[len]) len++;
    while (len > 0) {
        ssize_t n = write(fd, s, len);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return;
        }
        s += n;
        len -= (size_t)n;
    }
}

static void put_clean(int fd, const char *s, size_t max) {
    char buf[256];
    size_t used = 0;
    for (size_t i = 0; s && s[i] && i < max; i++) {
        char c = s[i];
        buf[used++] = (c == '\n' || c == '\r') ? ' ' : c;
        if (used == sizeof buf - 1) {
            buf[used] = 0;
            put(fd, buf);
            used = 0;
        }
    }
    buf[used] = 0;
    put(fd, buf);
}

static void put_hex(int fd, uint64_t v) {
    char buf[19];
    const char *digits = "0123456789abcdef";
    int i = 18;
    buf[i] = 0;
    do {
        buf[--i] = digits[v & 0xf];
        v >>= 4;
    } while (v && i > 2);
    buf[--i] = 'x';
    buf[--i] = '0';
    put(fd, buf + i);
}

static void put_dec(int fd, int64_t v) {
    char buf[24];
    int i = 23;
    int neg = v < 0;
    uint64_t u = neg ? (uint64_t)(-(v + 1)) + 1 : (uint64_t)v;
    buf[i] = 0;
    do {
        buf[--i] = (char)('0' + (u % 10));
        u /= 10;
    } while (u && i > 1);
    if (neg) buf[--i] = '-';
    put(fd, buf + i);
}

static void put_uuid(int fd, const uint8_t *uuid) {
    char buf[33];
    const char *digits = "0123456789abcdef";
    for (int i = 0; i < 16; i++) {
        buf[i * 2] = digits[uuid[i] >> 4];
        buf[i * 2 + 1] = digits[uuid[i] & 0xf];
    }
    buf[32] = 0;
    put(fd, buf);
}

static void write_report(const char *kind, int sig, int64_t code, uintptr_t addr, int exc, int64_t c0, int64_t c1, const char *name, const char *reason, const uintptr_t *frames, int count) {
    if (!crash_path[0]) return;
    int fd = open(crash_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    put(fd, "blipit-nuggets 1\ntime ");
    put_dec(fd, (int64_t)time(NULL));
    put(fd, "\nkind ");
    put(fd, kind);
    put(fd, "\nsignal ");
    put_dec(fd, sig);
    put(fd, "\ncode ");
    put_dec(fd, code);
    put(fd, "\naddr ");
    put_hex(fd, addr);
    put(fd, "\nmach ");
    put_dec(fd, exc);
    put(fd, " ");
    put_dec(fd, c0);
    put(fd, " ");
    put_dec(fd, c1);
    put(fd, "\n");
    if (name) {
        put(fd, "name ");
        put_clean(fd, name, 256);
        put(fd, "\n");
    }
    if (reason) {
        put(fd, "reason ");
        put_clean(fd, reason, 4096);
        put(fd, "\n");
    }
    static uint8_t used[BN_MAX_IMAGES];
    memset(used, 0, sizeof used);
    for (int i = 0; i < count; i++) {
        put(fd, "frame ");
        put_hex(fd, frames[i]);
        put(fd, "\n");
        int at = image_of(frames[i]);
        if (at >= 0) used[at] = 1;
    }
    int total = __atomic_load_n(&image_count, __ATOMIC_ACQUIRE);
    for (int i = 0; i < total; i++) {
        if (!used[i]) continue;
        put(fd, "image ");
        put_hex(fd, images[i].base);
        put(fd, " ");
        put_hex(fd, images[i].size);
        put(fd, " ");
        put_uuid(fd, images[i].uuid);
        put(fd, " ");
        put_clean(fd, images[i].path ? images[i].path : "?", 1000);
        put(fd, "\n");
    }
    put(fd, "end\n");
    close(fd);
}

static void restore_signals(void) {
    for (size_t i = 0; i < BN_SIGNAL_COUNT; i++) sigaction(signals[i], &previous[i], NULL);
}

#if !TARGET_OS_WATCH
static int thread_frames(thread_t thread, uintptr_t *out, int max) {
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS) return 0;
    return walk((uintptr_t)arm_thread_state64_get_pc(state), (uintptr_t)arm_thread_state64_get_lr(state), (uintptr_t)arm_thread_state64_get_fp(state), out, max);
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS) return 0;
    return walk((uintptr_t)state.__rip, 0, (uintptr_t)state.__rbp, out, max);
#else
    return 0;
#endif
}

#endif

#if BN_MACH
static mach_port_t exc_port = MACH_PORT_NULL;
static exception_mask_t prev_masks[EXC_TYPES_COUNT];
static mach_port_t prev_ports[EXC_TYPES_COUNT];
static exception_behavior_t prev_behaviors[EXC_TYPES_COUNT];
static thread_state_flavor_t prev_flavors[EXC_TYPES_COUNT];
static mach_msg_type_number_t prev_count = 0;
static const exception_mask_t exc_mask = EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_BREAKPOINT;

#pragma pack(push, 4)
typedef struct {
    mach_msg_header_t head;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t ndr;
    exception_type_t exception;
    mach_msg_type_number_t code_count;
    int64_t code[2];
    char padding[512];
} bn_exc_request;

typedef struct {
    mach_msg_header_t head;
    NDR_record_t ndr;
    kern_return_t ret;
} bn_exc_reply;
#pragma pack(pop)

static void restore_ports(void) {
    for (mach_msg_type_number_t i = 0; i < prev_count; i++) {
        task_set_exception_ports(mach_task_self(), prev_masks[i], prev_ports[i], prev_behaviors[i], prev_flavors[i]);
    }
}

static void *exc_server(void *arg) {
    (void)arg;
    pthread_setname_np("io.blipit.nuggets.mach");
    for (;;) {
        bn_exc_request req;
        memset(&req, 0, sizeof req);
        kern_return_t kr = mach_msg(&req.head, MACH_RCV_MSG, 0, sizeof req, exc_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) {
            if (kr == MACH_RCV_PORT_DIED || kr == MACH_RCV_INVALID_NAME) return NULL;
            continue;
        }
        if (!__atomic_exchange_n(&claimed, 1, __ATOMIC_SEQ_CST)) {
            uintptr_t frames[BN_MAX_FRAMES];
            int count = thread_frames(req.thread.name, frames, BN_MAX_FRAMES);
            uintptr_t addr = req.exception == EXC_BAD_ACCESS && req.code_count > 1 ? (uintptr_t)req.code[1] : 0;
            write_report("mach", 0, 0, addr, req.exception, req.code_count > 0 ? req.code[0] : 0, req.code_count > 1 ? req.code[1] : 0, NULL, NULL, frames, count);
        }
        restore_ports();
        bn_exc_reply reply;
        memset(&reply, 0, sizeof reply);
        reply.head.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(req.head.msgh_bits), 0);
        reply.head.msgh_remote_port = req.head.msgh_remote_port;
        reply.head.msgh_local_port = MACH_PORT_NULL;
        reply.head.msgh_size = sizeof reply;
        reply.head.msgh_id = req.head.msgh_id + 100;
        reply.ndr = NDR_record;
        reply.ret = KERN_FAILURE;
        mach_msg(&reply.head, MACH_SEND_MSG, sizeof reply, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        return NULL;
    }
}

static int install_mach(void) {
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &exc_port) != KERN_SUCCESS) return 0;
    if (mach_port_insert_right(mach_task_self(), exc_port, exc_port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) return 0;
    prev_count = EXC_TYPES_COUNT;
    if (task_get_exception_ports(mach_task_self(), exc_mask, prev_masks, &prev_count, prev_ports, prev_behaviors, prev_flavors) != KERN_SUCCESS) prev_count = 0;
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int started = pthread_create(&thread, &attr, exc_server, NULL) == 0;
    pthread_attr_destroy(&attr);
    if (!started) return 0;
    return task_set_exception_ports(mach_task_self(), exc_mask, exc_port, (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES), THREAD_STATE_NONE) == KERN_SUCCESS;
}
#endif

static void on_signal(int sig, siginfo_t *info, void *context) {
    if (!__atomic_exchange_n(&claimed, 1, __ATOMIC_SEQ_CST)) {
        uintptr_t frames[BN_MAX_FRAMES];
        int count = 0;
        ucontext_t *uc = (ucontext_t *)context;
        if (uc && uc->uc_mcontext) {
#if defined(__arm64__)
            count = walk((uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss), (uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss), (uintptr_t)__darwin_arm_thread_state64_get_fp(uc->uc_mcontext->__ss), frames, BN_MAX_FRAMES);
#elif defined(__x86_64__)
            count = walk((uintptr_t)uc->uc_mcontext->__ss.__rip, 0, (uintptr_t)uc->uc_mcontext->__ss.__rbp, frames, BN_MAX_FRAMES);
#endif
        }
        write_report("signal", sig, info ? info->si_code : 0, info ? (uintptr_t)info->si_addr : 0, 0, 0, 0, NULL, NULL, frames, count);
    }
    restore_signals();
    raise(sig);
}

int bn_install(const char *path, int use_mach) {
    if (!path || strlen(path) >= sizeof crash_path) return 0;
    strncpy(crash_path, path, sizeof crash_path - 1);
    track_images();
    if (__atomic_exchange_n(&installed, 1, __ATOMIC_SEQ_CST)) return 1;
#if BN_MACH
    static char *alt = NULL;
    if (!alt) {
        alt = malloc(SIGSTKSZ * 4);
        if (alt) {
            stack_t ss;
            ss.ss_sp = alt;
            ss.ss_size = SIGSTKSZ * 4;
            ss.ss_flags = 0;
            sigaltstack(&ss, NULL);
        }
    }
#endif
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = on_signal;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < BN_SIGNAL_COUNT; i++) sigaction(signals[i], &action, &previous[i]);
#if BN_MACH
    if (use_mach && !bn_debugger_attached()) install_mach();
#else
    (void)use_mach;
#endif
    return 1;
}

int bn_installed(void) {
    return installed;
}

void bn_mark_main_thread(void) {
    main_port = pthread_mach_thread_np(pthread_self());
}

int bn_main_backtrace(uintptr_t *out, int max) {
#if TARGET_OS_WATCH
    (void)out;
    (void)max;
    return 0;
#else
    if (main_port == MACH_PORT_NULL || main_port == pthread_mach_thread_np(pthread_self())) return 0;
    if (thread_suspend(main_port) != KERN_SUCCESS) return 0;
    int count = thread_frames(main_port, out, max);
    thread_resume(main_port);
    return count;
#endif
}

int bn_write_exception(const char *name, const char *reason, const uintptr_t *frames, int count) {
    if (__atomic_exchange_n(&claimed, 1, __ATOMIC_SEQ_CST)) return 0;
    write_report("exception", SIGABRT, 0, 0, 0, 0, 0, name, reason, frames, count > BN_MAX_FRAMES ? BN_MAX_FRAMES : count);
    return 1;
}

int bn_debugger_attached(void) {
    struct kinfo_proc info;
    memset(&info, 0, sizeof info);
    size_t size = sizeof info;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return 0;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

int64_t bn_boot_time(void) {
    struct timeval boot;
    size_t size = sizeof boot;
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &boot, &size, NULL, 0) != 0) return 0;
    return (int64_t)boot.tv_sec;
}

int64_t bn_process_start_ms(void) {
    struct kinfo_proc info;
    memset(&info, 0, sizeof info);
    size_t size = sizeof info;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return 0;
    return (int64_t)info.kp_proc.p_starttime.tv_sec * 1000 + info.kp_proc.p_starttime.tv_usec / 1000;
}

int bn_image_count(void) {
    track_images();
    return __atomic_load_n(&image_count, __ATOMIC_ACQUIRE);
}

int bn_image_at(int index, uintptr_t *base, uintptr_t *size, char *uuid_hex, const char **path) {
    if (index < 0 || index >= bn_image_count()) return 0;
    const char *digits = "0123456789abcdef";
    *base = images[index].base;
    *size = images[index].size;
    for (int i = 0; i < 16; i++) {
        uuid_hex[i * 2] = digits[images[index].uuid[i] >> 4];
        uuid_hex[i * 2 + 1] = digits[images[index].uuid[i] & 0xf];
    }
    uuid_hex[32] = 0;
    *path = images[index].path ? images[index].path : "?";
    return 1;
}

__attribute__((noinline)) int bn_backtrace(uintptr_t *out, int max, int skip) {
    uintptr_t fp = (uintptr_t)__builtin_frame_address(0);
    int n = 0;
    int seen = 0;
    while (fp && !(fp & 0x7) && n < max) {
        const uintptr_t *record = (const uintptr_t *)fp;
        uintptr_t ret = strip(record[1]);
        if (!ret) break;
        if (seen++ >= skip) out[n++] = ret;
        if (record[0] <= fp) break;
        fp = record[0];
    }
    return n;
}

void bn_crash(int how) {
    if (how == 1) abort();
    if (how == 2) __builtin_trap();
    volatile int *nowhere = (volatile int *)(uintptr_t)0x10;
    *nowhere = 1;
}
