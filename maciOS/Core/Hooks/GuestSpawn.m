//
//  GuestSpawn.m
//  maciOS
//

#import "GuestSpawn.h"
#import "GuestProcess.h"
#import "../JIT/ellekit/fishhook/fishhook.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <os/lock.h>
#include <sys/mman.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define CALLER ((uintptr_t)__builtin_return_address(0))

#pragma mark - Process table

#define GUEST_MAX 256
// Above the kernel's pid_max, so a guest pid never names a real process.
#define GUEST_PID_BASE 100000
// A guest's stdio descriptor that it has closed.
#define GUEST_FD_CLOSED (-2)

typedef struct {
    BOOL used;
    pid_t pid;
    pid_t ppid;             // 0 once the parent has exited
    BOOL spawned;           // started by another guest through fork/exec
    BOOL remapped;          // fds differs from the app's own stdio
    uintptr_t textStart, textEnd;
    int fds[3];             // -1: the app's own descriptor
    BOOL exited, reaped;
    int waitStatus;
    char instancePath[PATH_MAX];
    void *handle;           // from dlopen, closed once the program is gone
    thread_act_t *threads;  // threads the program started, so they can be stopped
    int threadCount, threadCapacity;
    struct region { uintptr_t start, end; } *regions;  // memory it mapped
    int regionCount, regionCapacity;
} guest_process;

// Guest threads only hold this for short, syscall-free stretches; guest_teardown
// stops a program's threads while holding it, so none of them can own it.
static os_unfair_lock guest_lock = OS_UNFAIR_LOCK_INIT;
// wait4 sleeps on guest_exit_cond; exits signal it after updating the table.
static pthread_mutex_t guest_wait_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t guest_exit_cond = PTHREAD_COND_INITIALIZER;
static guest_process guests[GUEST_MAX];
static pid_t guest_next_pid = GUEST_PID_BASE;
static int guest_remapped_count;
static guest_launcher_t guest_launcher;

static BOOL in_system_call(uintptr_t pc);

void guest_set_launcher(guest_launcher_t launcher) {
    guest_launcher = launcher;
    // Resolve it now rather than during a teardown, under guest_lock.
    in_system_call(0);
}

static guest_process *guest_alloc_locked(BOOL spawned) {
    for (int i = 0; i < GUEST_MAX; i++) {
        guest_process *g = &guests[i];
        if (g->used && !(g->exited && g->reaped)) continue;
        free(g->threads);
        free(g->regions);
        memset(g, 0, sizeof(*g));
        g->used = YES;
        g->pid = guest_next_pid++;
        g->spawned = spawned;
        g->fds[0] = g->fds[1] = g->fds[2] = -1;
        return g;
    }
    return NULL;
}

static guest_process *guest_find_pid_locked(pid_t pid) {
    for (int i = 0; i < GUEST_MAX; i++) {
        if (guests[i].used && guests[i].pid == pid) return &guests[i];
    }
    return NULL;
}

static guest_process *guest_find_address_locked(uintptr_t address) {
    for (int i = 0; i < GUEST_MAX; i++) {
        guest_process *g = &guests[i];
        if (g->used && address >= g->textStart && address < g->textEnd) return g;
    }
    return NULL;
}

static void guest_set_fds_locked(guest_process *g, const int fds[3]) {
    BOOL remapped = NO;
    for (int i = 0; i < 3; i++) {
        g->fds[i] = fds[i];
        if (fds[i] != -1) remapped = YES;
    }
    if (remapped != g->remapped) guest_remapped_count += remapped ? 1 : -1;
    g->remapped = remapped;
}

static void guest_close_fds_locked(guest_process *g) {
    for (int i = 0; i < 3; i++) {
        if (g->fds[i] >= 0) close(g->fds[i]);
        g->fds[i] = GUEST_FD_CLOSED;
    }
}

static void guest_mark_exited_locked(guest_process *g, int waitStatus) {
    if (g->exited) return;
    NSLog(@"Guest process %d exited with wait status %#x", g->pid, waitStatus);
    // The parent learns that a child is done by reading its pipes to EOF.
    if (g->remapped) {
        guest_close_fds_locked(g);
        g->remapped = NO;
        guest_remapped_count--;
    }
    if (g->instancePath[0]) unlink(g->instancePath);
    g->exited = YES;
    g->waitStatus = waitStatus;
    // Nobody will wait for a program started from the terminal, or an orphan.
    if (!g->spawned || g->ppid == 0) g->reaped = YES;
    for (int i = 0; i < GUEST_MAX; i++) {
        guest_process *child = &guests[i];
        if (!child->used || child->ppid != g->pid) continue;
        child->ppid = 0;
        if (child->exited) child->reaped = YES;
    }
}

/// Wakes wait4 callers; call after an exit is recorded, without guest_lock.
static void guest_notify_exit(void) {
    pthread_mutex_lock(&guest_wait_lock);
    pthread_cond_broadcast(&guest_exit_cond);
    pthread_mutex_unlock(&guest_wait_lock);
}

static BOOL grow(void **items, int *capacity, int count, size_t size) {
    if (count < *capacity) return YES;
    int newCapacity = *capacity ? *capacity * 2 : 16;
    void *grown = realloc(*items, (size_t)newCapacity * size);
    if (!grown) return NO;
    *items = grown;
    *capacity = newCapacity;
    return YES;
}

static void guest_add_thread_locked(guest_process *g, thread_act_t thread) {
    if (grow((void **)&g->threads, &g->threadCapacity, g->threadCount, sizeof(*g->threads))) {
        g->threads[g->threadCount++] = thread;
    } else {
        mach_port_deallocate(mach_task_self(), thread);
    }
}

static void guest_remove_region_locked(guest_process *g, uintptr_t start, uintptr_t end) {
    for (int i = 0; i < g->regionCount; i++) {
        struct region *r = &g->regions[i];
        if (r->end <= start || r->start >= end) continue;
        if (r->start < start && r->end > end) {
            // The hole splits the region in two.
            struct region tail = { end, r->end };
            r->end = start;
            if (grow((void **)&g->regions, &g->regionCapacity, g->regionCount, sizeof(*g->regions))) {
                g->regions[g->regionCount++] = tail;
            }
        } else if (r->start < start) {
            r->end = start;
        } else if (r->end > end) {
            r->start = end;
        } else {
            g->regions[i--] = g->regions[--g->regionCount];
        }
    }
}

static void guest_add_region_locked(guest_process *g, uintptr_t start, uintptr_t end) {
    guest_remove_region_locked(g, start, end);
    if (grow((void **)&g->regions, &g->regionCapacity, g->regionCount, sizeof(*g->regions))) {
        g->regions[g->regionCount++] = (struct region){ start, end };
    }
}

static BOOL text_range(const struct mach_header_64 *header, intptr_t slide, uintptr_t *start, uintptr_t *end);

/// libsystem_kernel's text: a thread stopped there is in a system call and
/// holds no user-space locks.
static BOOL in_system_call(uintptr_t pc) {
    static uintptr_t start, end;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((const void *)getpid, &info) && info.dli_fbase) {
            const struct mach_header_64 *header = info.dli_fbase;
            for (uint32_t i = 0; i < _dyld_image_count(); i++) {
                if (_dyld_get_image_header(i) == (const struct mach_header *)header) {
                    text_range(header, _dyld_get_image_vmaddr_slide(i), &start, &end);
                    break;
                }
            }
        }
    });
    return pc >= start && pc < end;
}

static int guest_exiting_threads;

/// Where a stopped guest thread is sent to end itself: pthreads cannot be
/// terminated from outside, so each one is made to call pthread_exit.
static void guest_thread_exit(void) {
    sigset_t all;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, NULL);
    stack_t disable = { .ss_flags = SS_DISABLE };
    sigaltstack(&disable, NULL);
    __atomic_sub_fetch(&guest_exiting_threads, 1, __ATOMIC_SEQ_CST);
    pthread_exit(NULL);
}

/// Stops a thread outside shared libraries' critical sections: in the
/// program's own code or blocked in a system call.
static BOOL guest_suspend_quiescent(guest_process *g, thread_act_t thread, arm_thread_state64_t *state) {
    if (thread_suspend(thread) != KERN_SUCCESS) return NO;
    for (int attempt = 0; ; attempt++) {
        mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)state, &count) != KERN_SUCCESS) {
            thread_resume(thread);
            return NO;
        }
        uintptr_t pc = (uintptr_t)arm_thread_state64_get_pc(*state);
        if ((pc >= g->textStart && pc < g->textEnd) || in_system_call(pc) || attempt == 200) return YES;
        thread_resume(thread);
        usleep(500);
        if (thread_suspend(thread) != KERN_SUCCESS) return NO;
    }
}

/// Ends the threads of a program that has exited and releases the memory it
/// mapped. Its runtime would otherwise keep running inside the app.
static BOOL guest_teardown_locked(guest_process *g) {
    BOOL stopped = YES;
    thread_act_t self = mach_thread_self();
    for (int i = 0; i < g->threadCount; i++) {
        thread_act_t thread = g->threads[i];
        arm_thread_state64_t state;
        pthread_t pthread = pthread_from_mach_thread_np(thread);
        if (thread != self && pthread && guest_suspend_quiescent(g, thread, &state)) {
            // Run guest_thread_exit at the top of the thread's own pthread
            // stack; it may have been on a goroutine stack that is about to go.
            uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(pthread) & ~(uintptr_t)15;
            thread_abort(thread);
            arm_thread_state64_set_pc_fptr(state, guest_thread_exit);
            arm_thread_state64_set_lr_fptr(state, guest_thread_exit);
            arm_thread_state64_set_sp(state, top - 256);
            arm_thread_state64_set_fp(state, 0);
            if (thread_set_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT) == KERN_SUCCESS) {
                __atomic_add_fetch(&guest_exiting_threads, 1, __ATOMIC_SEQ_CST);
            } else {
                stopped = NO;
            }
            thread_resume(thread);
        } else if (thread != self && pthread) {
            stopped = NO;
        }
        mach_port_deallocate(mach_task_self(), thread);
    }
    mach_port_deallocate(mach_task_self(), self);
    g->threadCount = 0;

    // Their signal stacks are in the memory about to be unmapped.
    for (int wait = 0; wait < 400 && __atomic_load_n(&guest_exiting_threads, __ATOMIC_SEQ_CST) > 0; wait++) {
        usleep(500);
    }
    if (__atomic_load_n(&guest_exiting_threads, __ATOMIC_SEQ_CST) > 0) stopped = NO;
    stack_t disable = { .ss_flags = SS_DISABLE };
    sigaltstack(&disable, NULL);
    for (int i = 0; i < g->regionCount; i++) {
        munmap((void *)g->regions[i].start, g->regions[i].end - g->regions[i].start);
    }
    g->regionCount = 0;
    // Its address range may be reused by the next image that is loaded.
    g->textStart = g->textEnd = 0;
    return stopped;
}

pid_t guest_register_toplevel(void) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_alloc_locked(NO);
    pid_t pid = g ? g->pid : -1;
    os_unfair_lock_unlock(&guest_lock);
    return pid;
}

void guest_adopt_current_thread(pid_t pid) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_pid_locked(pid);
    if (g) guest_add_thread_locked(g, mach_thread_self());
    os_unfair_lock_unlock(&guest_lock);
}

void guest_entry_returned(pid_t pid, int status) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_pid_locked(pid);
    if (g) guest_mark_exited_locked(g, W_EXITCODE(status & 0xff, 0));
    os_unfair_lock_unlock(&guest_lock);
    guest_notify_exit();
}

/// Maps a guest's stdin/stdout/stderr to the descriptors it was started with.
static int guest_translate_fd(int fd, uintptr_t caller) {
    if (fd < 0 || fd > 2 || __atomic_load_n(&guest_remapped_count, __ATOMIC_RELAXED) == 0) return fd;
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    int real = g ? g->fds[fd] : -1;
    os_unfair_lock_unlock(&guest_lock);
    if (real == -1) return fd;
    if (real == GUEST_FD_CLOSED) return INT_MAX; // fails with EBADF
    return real;
}

static BOOL guest_is_spawned(uintptr_t caller) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    BOOL spawned = g && g->spawned;
    os_unfair_lock_unlock(&guest_lock);
    return spawned;
}

__attribute__((noreturn))
static void guest_exit_current(uintptr_t caller, int waitStatus) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    // Programs started by another guest never installed their signal handlers.
    // Put the app's back before the handlers' memory goes away.
    if (!g || !g->spawned) guest_restore_signal_handlers();
    void *handle = NULL;
    if (g) {
        guest_mark_exited_locked(g, waitStatus);
        if (guest_teardown_locked(g)) handle = g->handle;
        g->handle = NULL;
    }
    os_unfair_lock_unlock(&guest_lock);
    guest_notify_exit();
    // Nothing runs the program's code any more, apart from this thread, which
    // will not return into it.
    if (handle) dlclose(handle);
    pthread_exit(NULL);
}

#pragma mark - vfork emulation

#define CHILD_MAX_FDS 1024
#define RESUME_STACK_SIZE (64 * 1024)

enum { CHILD_FD_INHERITED = 0, CHILD_FD_CLOSED, CHILD_FD_OWNED };

typedef struct {
    uint8_t state;
    int8_t cloexec;     // -1: as the inherited descriptor
    int real;           // CHILD_FD_OWNED: a descriptor this table owns
} child_fd;

typedef struct {
    uintptr_t address;
    size_t length;
    void *copy;
} stack_snapshot;

typedef struct {
    // Shared with GuestFork_arm64.s.
    uint64_t regs[12];          // x19..x28, x29, x30
    uint64_t sp;
    uint64_t fpregs[8];         // d8..d15
    uintptr_t resumeStackTop;

    BOOL active;
    pid_t pid;
    pid_t parentPid;
    stack_snapshot snapshots[2];
    char cwd[PATH_MAX];
    void *resumeStack;
    child_fd fds[CHILD_MAX_FDS];
} vfork_ctx;

_Static_assert(offsetof(vfork_ctx, sp) == 96, "layout shared with GuestFork_arm64.s");
_Static_assert(offsetof(vfork_ctx, fpregs) == 104, "layout shared with GuestFork_arm64.s");
_Static_assert(offsetof(vfork_ctx, resumeStackTop) == 168, "layout shared with GuestFork_arm64.s");

int guest_fork_hook(void);
__attribute__((noreturn)) void guest_vfork_resume(vfork_ctx *ctx, pid_t pid);

static pthread_key_t vfork_key;
static BOOL vfork_key_ready;

static void vfork_ctx_free(void *context) {
    vfork_ctx *c = context;
    free(c->resumeStack);
    free(c);
}

/// The calling thread's fork context, or NULL if it cannot fork right now.
vfork_ctx *guest_vfork_context(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vfork_key_ready = pthread_key_create(&vfork_key, vfork_ctx_free) == 0;
    });
    if (!vfork_key_ready) return NULL;
    vfork_ctx *c = pthread_getspecific(vfork_key);
    if (c) return c->active ? NULL : c;
    c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->resumeStack = malloc(RESUME_STACK_SIZE);
    if (!c->resumeStack) {
        free(c);
        return NULL;
    }
    c->resumeStackTop = ((uintptr_t)c->resumeStack + RESUME_STACK_SIZE) & ~(uintptr_t)15;
    pthread_setspecific(vfork_key, c);
    return c;
}

int guest_vfork_unavailable(void) {
    errno = EAGAIN;
    return -1;
}

/// The fork context of the calling thread while it runs a child's code.
static vfork_ctx *child_ctx(void) {
    if (!vfork_key_ready) return NULL;
    vfork_ctx *c = pthread_getspecific(vfork_key);
    return (c && c->active) ? c : NULL;
}

static BOOL read_word(uintptr_t address, uintptr_t *out) {
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), address, sizeof(*out), (vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == sizeof(*out);
}

static BOOL take_snapshot(stack_snapshot *s, uintptr_t start, uintptr_t end) {
    s->address = start;
    s->length = end > start ? end - start : 0;
    s->copy = NULL;
    if (s->length == 0) return YES;
    s->copy = malloc(s->length);
    if (!s->copy) return NO;
    memcpy(s->copy, (void *)start, s->length);
    return YES;
}

static void free_snapshots(vfork_ctx *c) {
    for (int i = 0; i < 2; i++) {
        free(c->snapshots[i].copy);
        c->snapshots[i].copy = NULL;
        c->snapshots[i].length = 0;
    }
}

/// Saves the stack memory the child's code will overwrite before the parent
/// gets to return from fork().
static BOOL snapshot_stacks(vfork_ctx *c) {
    uintptr_t sp = c->sp;
    uintptr_t stackTop = (uintptr_t)pthread_get_stackaddr_np(pthread_self());

    // A Go program calls fork on its system stack (g0, held in x28), having
    // switched there from the goroutine's stack. asmcgocall left the
    // goroutine and its depth in that stack just below g0.sched.sp. Each
    // syscall the child makes goes through the same frames on both stacks.
    uintptr_t g0 = c->regs[9];
    uintptr_t lo, hi, g0sp, gp, depth, glo, ghi;
    if (read_word(g0, &lo) && read_word(g0 + 8, &hi) && lo <= sp && sp < hi &&
        read_word(g0 + 56, &g0sp) && sp < g0sp && g0sp <= hi && g0sp - sp < 64 * 1024 &&
        read_word(g0sp - 16, &gp) && read_word(g0sp - 8, &depth) &&
        read_word(gp, &glo) && read_word(gp + 8, &ghi) && glo < ghi && depth <= ghi - glo) {
        uintptr_t gsp = ghi - depth;
        uintptr_t gend = gsp + 16 * 1024 < ghi ? gsp + 16 * 1024 : ghi;
        return take_snapshot(&c->snapshots[0], sp, g0sp) && take_snapshot(&c->snapshots[1], gsp, gend);
    }

    uintptr_t end = sp + 64 * 1024 < stackTop ? sp + 64 * 1024 : stackTop;
    c->snapshots[1] = (stack_snapshot){ 0 };
    return take_snapshot(&c->snapshots[0], sp, end);
}

/// Called from guest_fork_hook with the caller's registers saved. Returns 0
/// to run the child's code on this thread.
int guest_vfork_begin(vfork_ctx *c) {
    if (!snapshot_stacks(c)) {
        free_snapshots(c);
        errno = ENOMEM;
        return -1;
    }

    os_unfair_lock_lock(&guest_lock);
    guest_process *parent = guest_find_address_locked((uintptr_t)c->regs[11]);
    guest_process *child = guest_alloc_locked(YES);
    if (child) child->ppid = parent ? parent->pid : 0;
    os_unfair_lock_unlock(&guest_lock);
    if (!child) {
        free_snapshots(c);
        errno = EAGAIN;
        return -1;
    }

    c->pid = child->pid;
    c->parentPid = parent ? parent->pid : 0;
    c->cwd[0] = '\0';
    for (int i = 0; i < CHILD_MAX_FDS; i++) {
        c->fds[i] = (child_fd){ CHILD_FD_INHERITED, -1, -1 };
    }
    c->active = YES;
    return 0;
}

/// Runs on the resume stack, just before the parent returns from fork().
void guest_vfork_restore_stacks(vfork_ctx *c) {
    for (int i = 0; i < 2; i++) {
        stack_snapshot *s = &c->snapshots[i];
        if (s->copy) memcpy((void *)s->address, s->copy, s->length);
    }
    free_snapshots(c);
}

static void child_release(vfork_ctx *c, int fd) {
    child_fd *e = &c->fds[fd];
    if (e->state == CHILD_FD_OWNED) close(e->real);
    *e = (child_fd){ CHILD_FD_CLOSED, -1, -1 };
}

/// Ends the child's part and returns from the original fork() with its pid.
__attribute__((noreturn))
static void child_finish(vfork_ctx *c) {
    for (int i = 0; i < CHILD_MAX_FDS; i++) {
        if (c->fds[i].state == CHILD_FD_OWNED) child_release(c, i);
    }
    c->active = NO;
    guest_vfork_resume(c, c->pid);
}

/// The real descriptor behind the child's `fd`, or -1.
static int child_resolve(vfork_ctx *c, int fd) {
    if (fd < 0) return -1;
    if (fd >= CHILD_MAX_FDS) return fd;
    child_fd *e = &c->fds[fd];
    if (e->state == CHILD_FD_CLOSED) return -1;
    if (e->state == CHILD_FD_OWNED) return e->real;
    if (fd <= 2 && c->parentPid) {
        os_unfair_lock_lock(&guest_lock);
        guest_process *parent = guest_find_pid_locked(c->parentPid);
        int real = parent ? parent->fds[fd] : -1;
        os_unfair_lock_unlock(&guest_lock);
        if (real == GUEST_FD_CLOSED) return -1;
        if (real >= 0) return real;
    }
    return fd;
}

static BOOL child_is_open(vfork_ctx *c, int fd) {
    int real = child_resolve(c, fd);
    return real >= 0 && fcntl(real, F_GETFD) != -1;
}

static BOOL child_is_cloexec(vfork_ctx *c, int fd) {
    child_fd *e = &c->fds[fd];
    if (e->cloexec >= 0) return e->cloexec;
    if (e->state != CHILD_FD_INHERITED || fd <= 2) return NO;
    int flags = fcntl(child_resolve(c, fd), F_GETFD);
    return flags >= 0 && (flags & FD_CLOEXEC);
}

static int child_dup_to(vfork_ctx *c, int source, int fd, BOOL cloexec) {
    int real = child_resolve(c, source);
    if (real < 0 || fd < 0 || fd >= CHILD_MAX_FDS) {
        errno = EBADF;
        return -1;
    }
    int copy = fcntl(real, F_DUPFD_CLOEXEC, 0);
    if (copy < 0) return -1;
    child_release(c, fd);
    c->fds[fd] = (child_fd){ CHILD_FD_OWNED, cloexec, copy };
    return fd;
}

static int child_lowest_free(vfork_ctx *c, int from) {
    for (int fd = from < 0 ? 0 : from; fd < CHILD_MAX_FDS; fd++) {
        if (!child_is_open(c, fd)) return fd;
    }
    errno = EMFILE;
    return -1;
}

/// The descriptors the exec'd program gets as stdin/stdout/stderr.
static void child_take_stdio(vfork_ctx *c, int out[3]) {
    for (int i = 0; i < 3; i++) {
        child_fd *e = &c->fds[i];
        out[i] = GUEST_FD_CLOSED;
        if (child_is_cloexec(c, i)) {
            // closed by exec
        } else if (e->state == CHILD_FD_OWNED) {
            out[i] = e->real;
            *e = (child_fd){ CHILD_FD_CLOSED, -1, -1 };
        } else if (e->state == CHILD_FD_INHERITED) {
            int real = child_resolve(c, i);
            if (real == i) {
                out[i] = -1;
            } else if (real >= 0) {
                int copy = fcntl(real, F_DUPFD_CLOEXEC, 0);
                if (copy >= 0) out[i] = copy;
            }
        }
        // Go's runtime insists that 0, 1 and 2 are open.
        if (out[i] == GUEST_FD_CLOSED) {
            int null = open("/dev/null", O_RDWR | O_CLOEXEC);
            if (null >= 0) out[i] = null;
        }
    }
}

typedef struct {
    const char *path;
    char *const *argv;
    char *const *envp;
    pid_t pid;
    int result;
} launch_request;

static void *launch_thread(void *arg) {
    launch_request *r = arg;
    r->result = guest_launcher(r->path, r->argv, r->envp, r->pid);
    return NULL;
}

/// Loads and starts the program on a thread of its own: the forking thread
/// may be on a small stack, and is in the middle of the child's code.
static int launch_guest(const char *path, char *const argv[], char *const envp[], pid_t pid) {
    launch_request request = { path, argv, envp, pid, ENOEXEC };
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8 * 1024 * 1024);
    pthread_t thread;
    int err = pthread_create(&thread, &attr, launch_thread, &request);
    pthread_attr_destroy(&attr);
    if (err != 0) return err;
    pthread_join(thread, NULL);
    return request.result;
}

static BOOL is_mach_o(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    uint32_t magic = 0;
    ssize_t n = read(fd, &magic, sizeof(magic));
    close(fd);
    return n == sizeof(magic) && (magic == MH_MAGIC_64 || magic == FAT_MAGIC || magic == FAT_CIGAM);
}

static int child_execve(vfork_ctx *c, const char *path, char *const argv[], char *const envp[]) {
    if (!path || !argv) {
        errno = EFAULT;
        return -1;
    }
    char resolved[PATH_MAX];
    if (path[0] != '/' && c->cwd[0]) {
        snprintf(resolved, sizeof(resolved), "%s/%s", c->cwd, path);
    } else {
        strlcpy(resolved, path, sizeof(resolved));
    }

    struct stat st;
    if (stat(resolved, &st) != 0) return -1;
    if (!S_ISREG(st.st_mode) || access(resolved, X_OK) != 0) {
        errno = EACCES;
        return -1;
    }
    if (!is_mach_o(resolved) || !guest_launcher) {
        errno = ENOEXEC;
        return -1;
    }

    int fds[3];
    child_take_stdio(c, fds);
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_pid_locked(c->pid);
    if (g) guest_set_fds_locked(g, fds);
    os_unfair_lock_unlock(&guest_lock);

    static char *const emptyEnvironment[] = { NULL };
    int err = launch_guest(resolved, argv, envp ? envp : emptyEnvironment, c->pid);
    if (err != 0) {
        os_unfair_lock_lock(&guest_lock);
        if (g) {
            for (int i = 0; i < 3; i++) {
                if (g->fds[i] >= 0) close(g->fds[i]);
            }
            int identity[3] = { -1, -1, -1 };
            guest_set_fds_locked(g, identity);
        }
        os_unfair_lock_unlock(&guest_lock);
        errno = err;
        return -1;
    }
    child_finish(c);
}

#pragma mark - Hooks

static int hook_execve(const char *path, char *const argv[], char *const envp[]) {
    vfork_ctx *c = child_ctx();
    if (c) return child_execve(c, path, argv, envp);
    return execve(path, argv, envp);
}

__attribute__((noreturn))
static void hook_exit(int status) {
    vfork_ctx *c = child_ctx();
    if (c) {
        os_unfair_lock_lock(&guest_lock);
        guest_process *g = guest_find_pid_locked(c->pid);
        if (g) guest_mark_exited_locked(g, W_EXITCODE(status & 0xff, 0));
        os_unfair_lock_unlock(&guest_lock);
        guest_notify_exit();
        child_finish(c);
    }
    guest_exit_current(CALLER, W_EXITCODE(status & 0xff, 0));
}

static pid_t hook_wait4(pid_t pid, int *status, int options, struct rusage *usage) {
    if (pid > 0 && pid < GUEST_PID_BASE) return wait4(pid, status, options, usage);

    os_unfair_lock_lock(&guest_lock);
    guest_process *caller = guest_find_address_locked(CALLER);
    pid_t callerPid = caller ? caller->pid : 0;
    os_unfair_lock_unlock(&guest_lock);

    pthread_mutex_lock(&guest_wait_lock);
    for (;;) {
        os_unfair_lock_lock(&guest_lock);
        guest_process *done = NULL;
        BOOL waiting = NO;
        for (int i = 0; i < GUEST_MAX; i++) {
            guest_process *g = &guests[i];
            if (!g->used || !g->spawned || g->reaped) continue;
            if (pid > 0 ? g->pid != pid : g->ppid != callerPid) continue;
            waiting = YES;
            if (g->exited) {
                done = g;
                break;
            }
        }
        pid_t donePid = 0;
        if (done) {
            done->reaped = YES;
            donePid = done->pid;
            if (status) *status = done->waitStatus;
        }
        os_unfair_lock_unlock(&guest_lock);

        if (done) {
            pthread_mutex_unlock(&guest_wait_lock);
            if (usage) memset(usage, 0, sizeof(*usage));
            return donePid;
        }
        if (!waiting) {
            pthread_mutex_unlock(&guest_wait_lock);
            if (pid > 0) {
                errno = ECHILD;
                return -1;
            }
            return wait4(pid, status, options, usage);
        }
        if (options & WNOHANG) {
            pthread_mutex_unlock(&guest_wait_lock);
            return 0;
        }
        pthread_cond_wait(&guest_exit_cond, &guest_wait_lock);
    }
}

static pid_t hook_waitpid(pid_t pid, int *status, int options) {
    return hook_wait4(pid, status, options, NULL);
}

static int hook_kill(pid_t pid, int sig) {
    if (pid >= GUEST_PID_BASE) {
        os_unfair_lock_lock(&guest_lock);
        guest_process *g = guest_find_pid_locked(pid);
        BOOL alive = g && !g->reaped;
        os_unfair_lock_unlock(&guest_lock);
        if (!alive) {
            errno = ESRCH;
            return -1;
        }
        // Guests are threads of this process; there is no way to deliver it.
        if (sig != 0) NSLog(@"kill(%d, %d) on a guest process is not supported", pid, sig);
        return 0;
    }
    if (pid == getpid() && sig != 0 && guest_is_spawned(CALLER)) {
        guest_exit_current(CALLER, sig);
    }
    return kill(pid, sig);
}

static int hook_raise(int sig) {
    if (guest_is_spawned(CALLER)) guest_exit_current(CALLER, sig);
    return raise(sig);
}

static int hook_sigaction(int sig, const struct sigaction *act, struct sigaction *oact) {
    // Handlers are process-wide. A forked child must not clear its parent's,
    // and a program started by another guest must not replace them.
    if (child_ctx() || (act && guest_is_spawned(CALLER))) {
        return oact ? sigaction(sig, NULL, oact) : 0;
    }
    return sigaction(sig, act, oact);
}

static pid_t hook_getpid(void) {
    vfork_ctx *c = child_ctx();
    return c ? c->pid : getpid();
}

static pid_t hook_setsid(void) {
    vfork_ctx *c = child_ctx();
    return c ? c->pid : setsid();
}

static int hook_setpgid(pid_t pid, pid_t pgid) {
    return child_ctx() ? 0 : setpgid(pid, pgid);
}

static int hook_setrlimit(int resource, const struct rlimit *rlp) {
    return child_ctx() ? 0 : setrlimit(resource, rlp);
}

static int hook_setgid(gid_t gid) {
    return child_ctx() ? 0 : setgid(gid);
}

static int hook_setuid(uid_t uid) {
    return child_ctx() ? 0 : setuid(uid);
}

static int hook_setgroups(int ngroups, const gid_t *groups) {
    return child_ctx() ? 0 : setgroups(ngroups, groups);
}

static int hook_chroot(const char *path) {
    return child_ctx() ? 0 : chroot(path);
}

static int hook_chdir(const char *path) {
    vfork_ctx *c = child_ctx();
    if (!c) return chdir(path);
    // The working directory is process-wide; the exec'd program gets $PWD.
    char resolved[PATH_MAX];
    if (path[0] == '/') {
        strlcpy(resolved, path, sizeof(resolved));
    } else {
        char base[PATH_MAX];
        if (c->cwd[0]) strlcpy(base, c->cwd, sizeof(base));
        else if (!getcwd(base, sizeof(base))) return -1;
        snprintf(resolved, sizeof(resolved), "%s/%s", base, path);
    }
    struct stat st;
    if (stat(resolved, &st) != 0) return -1;
    if (!S_ISDIR(st.st_mode)) {
        errno = ENOTDIR;
        return -1;
    }
    strlcpy(c->cwd, resolved, sizeof(c->cwd));
    return 0;
}

static int map_fd(int fd, uintptr_t caller) {
    vfork_ctx *c = child_ctx();
    if (c) {
        int real = child_resolve(c, fd);
        return real < 0 ? INT_MAX : real;
    }
    return guest_translate_fd(fd, caller);
}

static int hook_close(int fd) {
    vfork_ctx *c = child_ctx();
    if (c) {
        // A child's close never affects the parent's descriptors.
        if (fd >= CHILD_MAX_FDS) return 0;
        if (!child_is_open(c, fd)) {
            errno = EBADF;
            return -1;
        }
        child_release(c, fd);
        return 0;
    }
    if (fd >= 0 && fd <= 2 && __atomic_load_n(&guest_remapped_count, __ATOMIC_RELAXED) > 0) {
        os_unfair_lock_lock(&guest_lock);
        guest_process *g = guest_find_address_locked(CALLER);
        if (g && g->fds[fd] != -1) {
            int real = g->fds[fd];
            g->fds[fd] = GUEST_FD_CLOSED;
            os_unfair_lock_unlock(&guest_lock);
            if (real < 0) {
                errno = EBADF;
                return -1;
            }
            return close(real);
        }
        os_unfair_lock_unlock(&guest_lock);
    }
    return close(fd);
}

static int hook_dup(int fd) {
    vfork_ctx *c = child_ctx();
    if (c) {
        int target = child_lowest_free(c, 0);
        return target < 0 ? -1 : child_dup_to(c, fd, target, NO);
    }
    return dup(guest_translate_fd(fd, CALLER));
}

static int hook_dup2(int fd, int target) {
    vfork_ctx *c = child_ctx();
    if (c) {
        if (fd != target) return child_dup_to(c, fd, target, NO);
        if (child_is_open(c, fd)) return fd;
        errno = EBADF;
        return -1;
    }
    uintptr_t caller = CALLER;
    int source = guest_translate_fd(fd, caller);
    if (target >= 0 && target <= 2 && __atomic_load_n(&guest_remapped_count, __ATOMIC_RELAXED) > 0) {
        os_unfair_lock_lock(&guest_lock);
        guest_process *g = guest_find_address_locked(caller);
        if (g && g->fds[target] != -1) {
            int result;
            if (g->fds[target] >= 0) {
                result = dup2(source, g->fds[target]);
            } else {
                result = fcntl(source, F_DUPFD_CLOEXEC, 0);
                if (result >= 0) g->fds[target] = result;
            }
            os_unfair_lock_unlock(&guest_lock);
            return result < 0 ? -1 : target;
        }
        os_unfair_lock_unlock(&guest_lock);
    }
    return dup2(source, target);
}

static int hook_fcntl(int fd, int cmd, ...) {
    va_list args;
    va_start(args, cmd);
    long arg = va_arg(args, long);
    va_end(args);

    vfork_ctx *c = child_ctx();
    if (c && fd >= 0 && fd < CHILD_MAX_FDS) {
        if (!child_is_open(c, fd)) {
            errno = EBADF;
            return -1;
        }
        switch (cmd) {
            case F_GETFD:
                return child_is_cloexec(c, fd) ? FD_CLOEXEC : 0;
            case F_SETFD:
                c->fds[fd].cloexec = (arg & FD_CLOEXEC) ? 1 : 0;
                return 0;
            case F_DUPFD:
            case F_DUPFD_CLOEXEC: {
                int target = child_lowest_free(c, (int)arg);
                return target < 0 ? -1 : child_dup_to(c, fd, target, cmd == F_DUPFD_CLOEXEC);
            }
            default:
                return fcntl(child_resolve(c, fd), cmd, arg);
        }
    }
    return fcntl(map_fd(fd, CALLER), cmd, arg);
}

static int hook_ioctl(int fd, unsigned long request, ...) {
    va_list args;
    va_start(args, request);
    void *arg = va_arg(args, void *);
    va_end(args);

    if (child_ctx() && (request == TIOCSPGRP || request == TIOCSCTTY || request == TIOCNOTTY)) return 0;
    return ioctl(map_fd(fd, CALLER), request, arg);
}

static ssize_t hook_read(int fd, void *buf, size_t count) {
    return read(map_fd(fd, CALLER), buf, count);
}

static ssize_t hook_write(int fd, const void *buf, size_t count) {
    return write(map_fd(fd, CALLER), buf, count);
}

static ssize_t hook_pread(int fd, void *buf, size_t count, off_t offset) {
    return pread(map_fd(fd, CALLER), buf, count, offset);
}

static ssize_t hook_pwrite(int fd, const void *buf, size_t count, off_t offset) {
    return pwrite(map_fd(fd, CALLER), buf, count, offset);
}

static ssize_t hook_readv(int fd, const struct iovec *iov, int count) {
    return readv(map_fd(fd, CALLER), iov, count);
}

static ssize_t hook_writev(int fd, const struct iovec *iov, int count) {
    return writev(map_fd(fd, CALLER), iov, count);
}

static off_t hook_lseek(int fd, off_t offset, int whence) {
    return lseek(map_fd(fd, CALLER), offset, whence);
}

static int hook_fstat(int fd, struct stat *st) {
    return fstat(map_fd(fd, CALLER), st);
}

static int hook_fsync(int fd) {
    return fsync(map_fd(fd, CALLER));
}

static int hook_ftruncate(int fd, off_t length) {
    return ftruncate(map_fd(fd, CALLER), length);
}

static int hook_isatty(int fd) {
    return isatty(map_fd(fd, CALLER));
}

static int hook_tcgetattr(int fd, struct termios *t) {
    return tcgetattr(map_fd(fd, CALLER), t);
}

static int hook_tcsetattr(int fd, int action, const struct termios *t) {
    return tcsetattr(map_fd(fd, CALLER), action, t);
}

typedef struct {
    void *(*start)(void *);
    void *arg;
    pid_t pid;
} thread_start;

static void *guest_thread_main(void *context) {
    thread_start start = *(thread_start *)context;
    os_unfair_lock_lock(&guest_lock);
    free(context);
    guest_process *g = guest_find_pid_locked(start.pid);
    if (!g || g->exited) {
        // The program exited while this thread was being created.
        os_unfair_lock_unlock(&guest_lock);
        pthread_exit(NULL);
    }
    guest_add_thread_locked(g, mach_thread_self());
    os_unfair_lock_unlock(&guest_lock);
    return start.start(start.arg);
}

static int hook_pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*routine)(void *), void *arg) {
    // Everything here happens under guest_lock, so guest_teardown never stops
    // a thread in the middle of malloc or pthread_create.
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(CALLER);
    int result;
    thread_start *start = g ? malloc(sizeof(*start)) : NULL;
    if (start) {
        *start = (thread_start){ routine, arg, g->pid };
        result = pthread_create(thread, attr, guest_thread_main, start);
        if (result != 0) free(start);
    } else {
        result = pthread_create(thread, attr, routine, arg);
    }
    os_unfair_lock_unlock(&guest_lock);
    return result;
}

static void *hook_mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    os_unfair_lock_lock(&guest_lock);
    void *result = mmap(addr, length, prot, flags, fd, offset);
    if (result != MAP_FAILED) {
        guest_process *g = guest_find_address_locked(CALLER);
        if (g) guest_add_region_locked(g, (uintptr_t)result, (uintptr_t)result + round_page(length));
    }
    os_unfair_lock_unlock(&guest_lock);
    return result;
}

static int hook_munmap(void *addr, size_t length) {
    // Under the lock, so the range cannot be handed to someone else while it
    // is still recorded as the program's.
    os_unfair_lock_lock(&guest_lock);
    int result = munmap(addr, length);
    if (result == 0) {
        guest_process *g = guest_find_address_locked(CALLER);
        if (g) guest_remove_region_locked(g, (uintptr_t)addr, (uintptr_t)addr + round_page(length));
    }
    os_unfair_lock_unlock(&guest_lock);
    return result;
}

#pragma mark - Images

static BOOL text_range(const struct mach_header_64 *header, intptr_t slide, uintptr_t *start, uintptr_t *end) {
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_TEXT) == 0) {
                *start = (uintptr_t)(seg->vmaddr + slide);
                *end = *start + (uintptr_t)seg->vmsize;
                return YES;
            }
        }
        cursor += lc->cmdsize;
    }
    return NO;
}

BOOL guest_attach_image(pid_t pid, const char *imagePath, void *handle, const char *instancePath) {
    char wanted[PATH_MAX];
    if (!realpath(imagePath, wanted)) strlcpy(wanted, imagePath, sizeof(wanted));

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        char resolved[PATH_MAX];
        if (!name) continue;
        if (!realpath(name, resolved)) strlcpy(resolved, name, sizeof(resolved));
        if (strcmp(resolved, wanted) != 0) continue;

        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        uintptr_t start = 0, end = 0;
        if (!text_range(header, slide, &start, &end)) return NO;

        os_unfair_lock_lock(&guest_lock);
        guest_process *g = guest_find_pid_locked(pid);
        if (g) {
            g->textStart = start;
            g->textEnd = end;
            g->handle = handle;
            if (instancePath) strlcpy(g->instancePath, instancePath, sizeof(g->instancePath));
        }
        os_unfair_lock_unlock(&guest_lock);
        if (!g) return NO;

        struct rebinding rebindings[] = {
            { "fork", (void *)guest_fork_hook, NULL },
            { "vfork", (void *)guest_fork_hook, NULL },
            { "execve", (void *)hook_execve, NULL },
            { "exit", (void *)hook_exit, NULL },
            { "_exit", (void *)hook_exit, NULL },
            { "wait4", (void *)hook_wait4, NULL },
            { "waitpid", (void *)hook_waitpid, NULL },
            { "kill", (void *)hook_kill, NULL },
            { "raise", (void *)hook_raise, NULL },
            { "sigaction", (void *)hook_sigaction, NULL },
            { "getpid", (void *)hook_getpid, NULL },
            { "setsid", (void *)hook_setsid, NULL },
            { "setpgid", (void *)hook_setpgid, NULL },
            { "setrlimit", (void *)hook_setrlimit, NULL },
            { "setgid", (void *)hook_setgid, NULL },
            { "setuid", (void *)hook_setuid, NULL },
            { "setgroups", (void *)hook_setgroups, NULL },
            { "chroot", (void *)hook_chroot, NULL },
            { "chdir", (void *)hook_chdir, NULL },
            { "close", (void *)hook_close, NULL },
            { "dup", (void *)hook_dup, NULL },
            { "dup2", (void *)hook_dup2, NULL },
            { "fcntl", (void *)hook_fcntl, NULL },
            { "ioctl", (void *)hook_ioctl, NULL },
            { "read", (void *)hook_read, NULL },
            { "write", (void *)hook_write, NULL },
            { "pread", (void *)hook_pread, NULL },
            { "pwrite", (void *)hook_pwrite, NULL },
            { "readv", (void *)hook_readv, NULL },
            { "writev", (void *)hook_writev, NULL },
            { "lseek", (void *)hook_lseek, NULL },
            { "fstat", (void *)hook_fstat, NULL },
            { "fsync", (void *)hook_fsync, NULL },
            { "ftruncate", (void *)hook_ftruncate, NULL },
            { "isatty", (void *)hook_isatty, NULL },
            { "tcgetattr", (void *)hook_tcgetattr, NULL },
            { "tcsetattr", (void *)hook_tcsetattr, NULL },
            { "pthread_create", (void *)hook_pthread_create, NULL },
            { "mmap", (void *)hook_mmap, NULL },
            { "munmap", (void *)hook_munmap, NULL },
        };
        return rebind_symbols_image((void *)header, slide, rebindings, sizeof(rebindings) / sizeof(rebindings[0])) == 0;
    }
    return NO;
}
