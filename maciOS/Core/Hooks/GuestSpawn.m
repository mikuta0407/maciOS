//
//  GuestSpawn.m
//  maciOS
//

#import "GuestSpawn.h"
#import "GuestProcess.h"
#import "GuestRoot.h"
#import "GuestHeap.h"
#import "../JIT/ellekit/fishhook/fishhook.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <crt_externs.h>
#include <dirent.h>
#include <dlfcn.h>
#include <grp.h>
#include <pwd.h>
#include <removefile.h>
#include <err.h>
#include <malloc/malloc.h>
#include <spawn.h>
#include <stdio.h>
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
#include <sys/mount.h>
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
    void **opened;          // what the program dlopen()ed and has not closed
    int openedCount, openedCapacity;
    thread_act_t *threads;  // threads the program started, so they can be stopped
    int threadCount, threadCapacity;
    struct region { uintptr_t start, end; } *regions;  // memory it mapped
    int regionCount, regionCapacity;
    const struct mach_header_64 *header;  // the program's image
    intptr_t slide;
    int argc;
    char **argv;
    char executablePath[PATH_MAX];
    char **environ;         // what the program's environ and getenv() see
    char **ownedEnviron;    // the last environment setenv() here allocated; the program may have replaced it
    FILE *stdio[3];         // the program's stdin, stdout and stderr
    guest_heap *heap;       // for programs that fork without threads; see GuestHeap.h
    char cwd[PATH_MAX];     // its working directory; each of its threads has it as its own
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
static guest_library_loader_t guest_library_loader;
static guest_exit_observer_t guest_toplevel_exit_observer;
// The program a thread belongs to.
static pthread_key_t guest_thread_key;

// The working directory is per process, and guests share the app's process,
// so each guest thread gets one of its own instead.
int pthread_chdir_np(const char *path);
int pthread_fchdir_np(int fd);

static BOOL in_system_call(uintptr_t pc);
static void guest_flush_stdio(pid_t pid);
static void guest_hook_libraries(guest_process *owner);

void guest_set_toplevel_exit_observer(guest_exit_observer_t observer) {
    guest_toplevel_exit_observer = observer;
}

void guest_set_library_loader(guest_library_loader_t loader) {
    guest_library_loader = loader;
}

void guest_set_launcher(guest_launcher_t launcher) {
    // The key first: guest_find_address_locked uses it once there is a launcher.
    pthread_key_create(&guest_thread_key, NULL);
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
        free(g->ownedEnviron);
        for (int fd = 0; fd < 3; fd++) {
            if (g->stdio[fd]) fclose(g->stdio[fd]);
        }
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

/// The program whose code is at `address`. Code outside every program's own
/// image, such as a library one loaded, acts for the program whose thread
/// runs it.
static guest_process *guest_find_address_locked(uintptr_t address) {
    for (int i = 0; i < GUEST_MAX; i++) {
        guest_process *g = &guests[i];
        if (g->used && address >= g->textStart && address < g->textEnd) return g;
    }
    guest_process *g = guest_launcher ? pthread_getspecific(guest_thread_key) : NULL;
    return g && g->used ? g : NULL;
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

/// Deletes a program's loaded copy. One in its own directory under
/// GuestInstances goes with that directory, which holds the libraries cloned
/// for it (see Execute.instantiate).
static void guest_remove_instance(const char *path) {
    static const char container[] = "/GuestInstances/";
    char directory[PATH_MAX];
    strlcpy(directory, path, sizeof(directory));
    char *slash = strrchr(directory, '/');
    const char *found = strstr(directory, container);
    if (slash && found && slash > found + sizeof(container) - 1 &&
        !memchr(found + sizeof(container) - 1, '/', (size_t)(slash - (found + sizeof(container) - 1)))) {
        *slash = '\0';
        removefile(directory, NULL, REMOVEFILE_RECURSIVE);
        return;
    }
    unlink(path);
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
    if (g->instancePath[0]) guest_remove_instance(g->instancePath);
    g->exited = YES;
    g->waitStatus = waitStatus;
    if (!g->spawned && guest_toplevel_exit_observer) guest_toplevel_exit_observer(g->pid, waitStatus);
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

/// Takes the libraries a program dlopen()ed, to be closed once it is gone
/// (guest_close_opened), as its exit would.
static void **guest_take_opened_locked(guest_process *g, int *count) {
    void **opened = g->opened;
    *count = g->openedCount;
    g->opened = NULL;
    g->openedCount = g->openedCapacity = 0;
    return opened;
}

static void guest_close_opened(void **opened, int count) {
    for (int i = count - 1; i >= 0; i--) dlclose(opened[i]);
    free(opened);
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
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) cwd[0] = '\0';
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_alloc_locked(NO);
    pid_t pid = g ? g->pid : -1;
    if (g) strlcpy(g->cwd, cwd, sizeof(g->cwd));
    os_unfair_lock_unlock(&guest_lock);
    return pid;
}

/// Gives the calling thread the program's working directory.
static void guest_enter_cwd(guest_process *g) {
    char cwd[PATH_MAX];
    os_unfair_lock_lock(&guest_lock);
    strlcpy(cwd, g->cwd, sizeof(cwd));
    os_unfair_lock_unlock(&guest_lock);
    if (cwd[0]) pthread_chdir_np(cwd);
}

void guest_adopt_current_thread(pid_t pid) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_pid_locked(pid);
    if (g) guest_add_thread_locked(g, mach_thread_self());
    os_unfair_lock_unlock(&guest_lock);
    pthread_setspecific(guest_thread_key, g);
    if (g) guest_enter_cwd(g);
}

void guest_entry_returned(pid_t pid, int status) {
    // As exit() would; the program's output may still be buffered.
    guest_flush_stdio(pid);
    void *handle = NULL;
    void **opened = NULL;
    int openedCount = 0;
    guest_heap *heap = NULL;
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_pid_locked(pid);
    if (g) {
        guest_mark_exited_locked(g, W_EXITCODE(status & 0xff, 0));
        if (guest_teardown_locked(g)) {
            handle = g->handle;
            opened = guest_take_opened_locked(g, &openedCount);
            heap = g->heap;
            g->heap = NULL;
        }
        g->handle = NULL;
    }
    os_unfair_lock_unlock(&guest_lock);
    if (heap) guest_heap_destroy(heap);
    guest_notify_exit();
    // As in guest_exit_current: unloads the program and the libraries cloned for it.
    if (handle) dlclose(handle);
    guest_close_opened(opened, openedCount);
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

static pid_t guest_pid_at(uintptr_t caller) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    pid_t pid = g ? g->pid : 0;
    os_unfair_lock_unlock(&guest_lock);
    return pid;
}

__attribute__((noreturn))
static void guest_exit_current(uintptr_t caller, int waitStatus) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    // Programs started by another guest never installed their signal handlers.
    // Put the app's back before the handlers' memory goes away.
    if (!g || !g->spawned) guest_restore_signal_handlers();
    void *handle = NULL;
    void **opened = NULL;
    int openedCount = 0;
    guest_heap *heap = NULL;
    if (g) {
        guest_mark_exited_locked(g, waitStatus);
        if (guest_teardown_locked(g)) {
            handle = g->handle;
            opened = guest_take_opened_locked(g, &openedCount);
            heap = g->heap;
            g->heap = NULL;
        }
        g->handle = NULL;
    }
    os_unfair_lock_unlock(&guest_lock);
    if (heap) guest_heap_destroy(heap);
    guest_notify_exit();
    // Nothing runs the program's code any more, apart from this thread, which
    // will not return into it.
    if (handle) dlclose(handle);
    guest_close_opened(opened, openedCount);
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

typedef struct vfork_ctx {
    // Shared with GuestFork_arm64.s.
    uint64_t regs[12];          // x19..x28, x29, x30
    uint64_t sp;
    uint64_t fpregs[8];         // d8..d15
    uintptr_t resumeStackTop;

    BOOL active;
    pid_t pid;
    pid_t parentPid;
    pid_t programPid;           // the program whose code the child runs
    struct vfork_ctx *outer;    // the child this one was forked from, if any
    stack_snapshot snapshots[2];
    // The program's globals, saved when nothing else in it runs while the
    // child does. The child's changes to them are undone when it ends.
    stack_snapshot *data;
    int dataCount;
    guest_heap *heap;           // and its heap, likewise
    guest_heap_snapshot *heapSnapshot;
    char **environ;             // the parent's, which the child may replace
    sigset_t mask;
    char cwd[PATH_MAX];         // the thread's working directory at the fork
    BOOL changedCwd;
    void *resumeStack;
    child_fd fds[CHILD_MAX_FDS];
} vfork_ctx;

_Static_assert(offsetof(vfork_ctx, sp) == 96, "layout shared with GuestFork_arm64.s");
_Static_assert(offsetof(vfork_ctx, fpregs) == 104, "layout shared with GuestFork_arm64.s");
_Static_assert(offsetof(vfork_ctx, resumeStackTop) == 168, "layout shared with GuestFork_arm64.s");

int guest_fork_hook(void);
__attribute__((noreturn)) void guest_vfork_resume(vfork_ctx *ctx, pid_t pid);

// A child can fork again (a shell's subshell running a pipeline), so each
// thread has a stack of contexts; the innermost active one is the child
// whose code the thread is running.
#define VFORK_MAX_DEPTH 8

typedef struct {
    int depth;
    vfork_ctx *contexts[VFORK_MAX_DEPTH];
} vfork_thread;

static pthread_key_t vfork_key;
static BOOL vfork_key_ready;

static void vfork_thread_free(void *value) {
    vfork_thread *t = value;
    for (int i = 0; i < VFORK_MAX_DEPTH; i++) {
        if (!t->contexts[i]) continue;
        free(t->contexts[i]->resumeStack);
        free(t->contexts[i]);
    }
    free(t);
}

/// The context for a fork the calling thread is about to make, or NULL if
/// it cannot fork right now.
vfork_ctx *guest_vfork_context(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vfork_key_ready = pthread_key_create(&vfork_key, vfork_thread_free) == 0;
    });
    if (!vfork_key_ready) return NULL;
    vfork_thread *t = pthread_getspecific(vfork_key);
    if (!t) {
        t = calloc(1, sizeof(*t));
        if (!t) return NULL;
        pthread_setspecific(vfork_key, t);
    }
    if (t->depth == VFORK_MAX_DEPTH) return NULL;
    vfork_ctx *c = t->contexts[t->depth];
    if (c) return c;
    c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->resumeStack = malloc(RESUME_STACK_SIZE);
    if (!c->resumeStack) {
        free(c);
        return NULL;
    }
    c->resumeStackTop = ((uintptr_t)c->resumeStack + RESUME_STACK_SIZE) & ~(uintptr_t)15;
    t->contexts[t->depth] = c;
    return c;
}

int guest_vfork_unavailable(void) {
    errno = EAGAIN;
    return -1;
}

/// The fork context of the calling thread while it runs a child's code.
static inline vfork_ctx *child_ctx(void) {
    if (!vfork_key_ready) return NULL;
    vfork_thread *t = pthread_getspecific(vfork_key);
    return (t && t->depth > 0) ? t->contexts[t->depth - 1] : NULL;
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
    for (int i = 0; i < c->dataCount; i++) {
        free(c->data[i].copy);
    }
    free(c->data);
    c->data = NULL;
    c->dataCount = 0;
    if (c->heapSnapshot) guest_heap_discard(c->heapSnapshot);
    c->heapSnapshot = NULL;
    c->heap = NULL;
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

    // Otherwise save all of the stack in use: a shell's child returns
    // through some of the frames above the fork before it ends.
    c->snapshots[1] = (stack_snapshot){ 0 };
    return take_snapshot(&c->snapshots[0], sp, stackTop);
}

/// Saves the writable data segments of a program's image.
static BOOL snapshot_data(vfork_ctx *c, const struct mach_header_64 *header, intptr_t slide) {
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    int count = 0;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__DATA") == 0 || strcmp(seg->segname, "__DATA_DIRTY") == 0) count++;
        }
        cursor += lc->cmdsize;
    }
    if (count == 0) return YES;
    c->data = calloc((size_t)count, sizeof(*c->data));
    if (!c->data) return NO;
    cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        cursor += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strcmp(seg->segname, "__DATA") != 0 && strcmp(seg->segname, "__DATA_DIRTY") != 0) continue;
        uintptr_t start = (uintptr_t)(seg->vmaddr + slide);
        if (!take_snapshot(&c->data[c->dataCount++], start, start + (uintptr_t)seg->vmsize)) return NO;
    }
    return YES;
}

/// Called from guest_fork_hook with the caller's registers saved. Returns 0
/// to run the child's code on this thread.
int guest_vfork_begin(vfork_ctx *c) {
    vfork_ctx *outer = child_ctx();
    if (!snapshot_stacks(c)) {
        free_snapshots(c);
        errno = ENOMEM;
        return -1;
    }

    os_unfair_lock_lock(&guest_lock);
    guest_process *program = guest_find_address_locked((uintptr_t)c->regs[11]);
    pid_t parentPid = outer ? outer->pid : (program ? program->pid : 0);
    guest_process *child = guest_alloc_locked(YES);
    if (child) child->ppid = parentPid;
    // With no other thread running the program's code, the child is the only
    // one changing its globals, so they can be put back afterwards. A shell
    // relies on that: its subshells run its own code, not another program.
    BOOL alone = program && program->threadCount <= 1;
    const struct mach_header_64 *header = alone ? program->header : NULL;
    intptr_t slide = program ? program->slide : 0;
    guest_heap *heap = alone ? program->heap : NULL;
    c->environ = program ? program->environ : NULL;
    pid_t programPid = program ? program->pid : 0;
    os_unfair_lock_unlock(&guest_lock);
    if (!child) {
        free_snapshots(c);
        errno = EAGAIN;
        return -1;
    }
    if (heap) {
        c->heap = heap;
        c->heapSnapshot = guest_heap_save(heap);
    }
    if ((header && !snapshot_data(c, header, slide)) || (heap && !c->heapSnapshot)) {
        free_snapshots(c);
        os_unfair_lock_lock(&guest_lock);
        child->exited = child->reaped = YES;
        os_unfair_lock_unlock(&guest_lock);
        errno = ENOMEM;
        return -1;
    }

    c->pid = child->pid;
    c->parentPid = parentPid;
    c->programPid = programPid;
    c->outer = outer;
    if (!getcwd(c->cwd, sizeof(c->cwd))) c->cwd[0] = '\0';
    c->changedCwd = NO;
    pthread_sigmask(SIG_SETMASK, NULL, &c->mask);
    for (int i = 0; i < CHILD_MAX_FDS; i++) {
        c->fds[i] = (child_fd){ CHILD_FD_INHERITED, -1, -1 };
    }
    c->active = YES;
    vfork_thread *t = pthread_getspecific(vfork_key);
    t->depth++;
    return 0;
}

/// Runs on the resume stack, just before the parent returns from fork().
void guest_vfork_restore_stacks(vfork_ctx *c) {
    for (int i = 0; i < 2; i++) {
        stack_snapshot *s = &c->snapshots[i];
        if (s->copy) memcpy((void *)s->address, s->copy, s->length);
    }
    for (int i = 0; i < c->dataCount; i++) {
        stack_snapshot *s = &c->data[i];
        if (s->copy) memcpy((void *)s->address, s->copy, s->length);
    }
    if (c->heapSnapshot) {
        guest_heap_restore(c->heap, c->heapSnapshot);
        c->heapSnapshot = NULL;
    }
    pthread_sigmask(SIG_SETMASK, &c->mask, NULL);
    // The child's chdir() changed this thread's directory, which is the parent's.
    if (c->changedCwd && c->cwd[0]) pthread_chdir_np(c->cwd);
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
    os_unfair_lock_lock(&guest_lock);
    // The child may have replaced the environment, as Rust does before exec.
    guest_process *program = guest_find_address_locked((uintptr_t)c->regs[11]);
    if (program) program->environ = c->environ;
    os_unfair_lock_unlock(&guest_lock);
    c->active = NO;
    vfork_thread *t = pthread_getspecific(vfork_key);
    t->depth--;
    guest_vfork_resume(c, c->pid);
}

/// The real descriptor behind the child's `fd`, or -1.
static int child_resolve(vfork_ctx *c, int fd) {
    if (fd < 0) return -1;
    if (fd >= CHILD_MAX_FDS) return fd;
    child_fd *e = &c->fds[fd];
    if (e->state == CHILD_FD_CLOSED) return -1;
    if (e->state == CHILD_FD_OWNED) return e->real;
    if (c->outer) return child_resolve(c->outer, fd);
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
    if (e->state != CHILD_FD_INHERITED) return NO;
    if (c->outer) return child_is_cloexec(c->outer, fd);
    if (fd <= 2) return NO;
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

/// Makes a descriptor the child just created its own, so that it closes
/// with the child. Returns the number the child knows it by.
static int child_adopt(vfork_ctx *c, int real, BOOL cloexec) {
    if (real < 0 || real >= CHILD_MAX_FDS) return real;
    int fd = real;
    child_fd *e = &c->fds[real];
    BOOL unused = e->state == CHILD_FD_CLOSED || (e->state == CHILD_FD_INHERITED && child_resolve(c, real) == real);
    if (!unused) {
        // The child already uses that number for something else.
        fd = child_lowest_free(c, 0);
        if (fd < 0) {
            close(real);
            return -1;
        }
    }
    c->fds[fd] = (child_fd){ CHILD_FD_OWNED, cloexec ? 1 : 0, real };
    return fd;
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
            // A copy, as fork() would give: the parent may point its own
            // descriptor elsewhere afterwards (a shell redirecting a builtin).
            int real = child_resolve(c, i);
            if (real >= 0) {
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

#define EXEC_MAX_INTERPRETERS 4
#define SHEBANG_MAX 512

static void free_argv(char **argv) {
    if (!argv) return;
    for (char **arg = argv; *arg; arg++) free(*arg);
    free(argv);
}

static char **copy_argv(char *const argv[], int skip, char *const prefix[], int prefixCount) {
    int count = 0;
    while (argv[count]) count++;
    int kept = count > skip ? count - skip : 0;
    char **result = calloc((size_t)(prefixCount + kept + 1), sizeof(char *));
    if (!result) return NULL;
    for (int i = 0; i < prefixCount; i++) result[i] = strdup(prefix[i]);
    for (int i = 0; i < kept; i++) result[prefixCount + i] = strdup(argv[skip + i]);
    return result;
}

/// faccessat, except that X_OK is answered from the mode bits, as on macOS:
/// a device's sandbox refuses X_OK for every file in the app's container, and
/// guests are loaded into the app rather than executed by the kernel.
static int guest_faccessat(int fd, const char *path, int mode, int flag) {
    if (!(mode & X_OK)) return faccessat(fd, path, mode, flag);
    if (faccessat(fd, path, (mode & ~X_OK) ?: F_OK, flag) != 0) return -1;
    struct stat st;
    if (fstatat(fd, path, &st, flag & AT_SYMLINK_NOFOLLOW) != 0) return -1;
    if (!(st.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH))) {
        errno = EACCES;
        return -1;
    }
    return 0;
}

/// Works out what running `path` means: a Mach-O file to load, or for a
/// script, the interpreter its "#!" line names. On success `resolved` is the
/// file to load and `*newArgv`, unless NULL, replaces `argv`. Returns an
/// errno value. A relative `path` is made absolute against the calling
/// thread's working directory, since the program is loaded on another thread.
static int resolve_exec(const char *path, char *const argv[], char resolved[PATH_MAX], char ***newArgv) {
    *newArgv = NULL;
    char current[PATH_MAX];
    char cwd[PATH_MAX];
    if (path[0] != '/' && getcwd(cwd, sizeof(cwd))) {
        snprintf(current, sizeof(current), "%s/%s", cwd, path);
    } else {
        strlcpy(current, path, sizeof(current));
    }

    for (int depth = 0; ; depth++) {
        char buffer[PATH_MAX];
        strlcpy(resolved, guest_root_map(current, buffer), PATH_MAX);
        struct stat st;
        if (stat(resolved, &st) != 0) return errno;
        if (!S_ISREG(st.st_mode) || guest_faccessat(AT_FDCWD, resolved, X_OK, 0) != 0) return EACCES;

        int fd = open(resolved, O_RDONLY | O_CLOEXEC);
        if (fd < 0) return errno;
        char head[SHEBANG_MAX];
        ssize_t n = read(fd, head, sizeof(head) - 1);
        close(fd);
        if (n < 2) return ENOEXEC;
        head[n] = '\0';
        uint32_t magic;
        memcpy(&magic, head, sizeof(magic));
        if (n >= 4 && (magic == MH_MAGIC_64 || magic == FAT_MAGIC || magic == FAT_CIGAM)) return 0;
        if (head[0] != '#' || head[1] != '!' || depth == EXEC_MAX_INTERPRETERS) return ENOEXEC;

        // "#!interpreter [args...]": like Darwin, split the arguments on
        // whitespace, then pass the script's path and the original arguments.
        char *line = head + 2;
        char *end = strchr(line, '\n');
        if (!end) return ENOEXEC;
        *end = '\0';
        char *words[16];
        int count = 0;
        for (char *word = strtok(line, " \t\r"); word && count < 15; word = strtok(NULL, " \t\r")) {
            words[count++] = word;
        }
        if (count == 0) return ENOEXEC;
        words[count++] = current;
        char **previous = *newArgv;
        char **next = copy_argv(previous ? previous : (char **)argv, 1, words, count);
        free_argv(previous);
        if (!next) return ENOMEM;
        *newArgv = next;
        strlcpy(current, words[0], sizeof(current));
    }
}

static int child_execve(vfork_ctx *c, const char *path, char *const argv[], char *const envp[]) {
    if (!path || !argv) {
        errno = EFAULT;
        return -1;
    }
    if (!guest_launcher) {
        errno = ENOEXEC;
        return -1;
    }
    char resolved[PATH_MAX];
    char **scriptArgv = NULL;
    int err = resolve_exec(path, argv, resolved, &scriptArgv);
    if (err != 0) {
        errno = err;
        return -1;
    }

    int fds[3];
    child_take_stdio(c, fds);
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) cwd[0] = '\0';
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_pid_locked(c->pid);
    if (g) {
        guest_set_fds_locked(g, fds);
        strlcpy(g->cwd, cwd, sizeof(g->cwd));
    }
    os_unfair_lock_unlock(&guest_lock);

    static char *const emptyEnvironment[] = { NULL };
    err = launch_guest(resolved, scriptArgv ? scriptArgv : argv, envp ? envp : emptyEnvironment, c->pid);
    free_argv(scriptArgv);
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

/// execve() outside a fork: the new program takes over the caller's pid and
/// descriptors, and the old one's threads and memory go away.
static int exec_replace(uintptr_t caller, const char *path, char *const argv[], char *const envp[]) {
    if (!path || !argv) {
        errno = EFAULT;
        return -1;
    }
    if (!guest_launcher) {
        errno = ENOEXEC;
        return -1;
    }
    char resolved[PATH_MAX];
    char **scriptArgv = NULL;
    int err = resolve_exec(path, argv, resolved, &scriptArgv);
    if (err != 0) {
        errno = err;
        return -1;
    }

    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    if (!g) {
        os_unfair_lock_unlock(&guest_lock);
        free_argv(scriptArgv);
        errno = ENOEXEC;
        return -1;
    }
    pid_t pid = g->pid;
    guest_process old = *g;
    g->threads = NULL;
    g->threadCount = g->threadCapacity = 0;
    g->regions = NULL;
    g->regionCount = g->regionCapacity = 0;
    g->textStart = g->textEnd = 0;
    g->header = NULL;
    g->handle = NULL;
    g->opened = NULL;
    g->openedCount = g->openedCapacity = 0;
    g->heap = NULL;
    g->instancePath[0] = '\0';
    os_unfair_lock_unlock(&guest_lock);

    static char *const emptyEnvironment[] = { NULL };
    err = launch_guest(resolved, scriptArgv ? scriptArgv : argv, envp ? envp : emptyEnvironment, pid);
    free_argv(scriptArgv);
    if (err != 0) {
        os_unfair_lock_lock(&guest_lock);
        g->threads = old.threads;
        g->threadCount = old.threadCount;
        g->threadCapacity = old.threadCapacity;
        g->regions = old.regions;
        g->regionCount = old.regionCount;
        g->regionCapacity = old.regionCapacity;
        g->textStart = old.textStart;
        g->textEnd = old.textEnd;
        g->header = old.header;
        g->handle = old.handle;
        g->opened = old.opened;
        g->openedCount = old.openedCount;
        g->openedCapacity = old.openedCapacity;
        g->heap = old.heap;
        strlcpy(g->instancePath, old.instancePath, sizeof(g->instancePath));
        os_unfair_lock_unlock(&guest_lock);
        errno = err;
        return -1;
    }

    os_unfair_lock_lock(&guest_lock);
    BOOL stopped = guest_teardown_locked(&old);
    os_unfair_lock_unlock(&guest_lock);
    free(old.threads);
    free(old.regions);
    if (old.instancePath[0]) guest_remove_instance(old.instancePath);
    // This thread never returns into the old program's code.
    if (stopped && old.handle) dlclose(old.handle);
    if (stopped) guest_close_opened(old.opened, old.openedCount);
    if (stopped && old.heap) guest_heap_destroy(old.heap);
    pthread_exit(NULL);
}

static char **guest_current_environ(uintptr_t caller);

static int do_execve(uintptr_t caller, const char *path, char *const argv[], char *const envp[]) {
    vfork_ctx *c = child_ctx();
    if (c) return child_execve(c, path, argv, envp);
    return exec_replace(caller, path, argv, envp);
}

/// execvp() and friends: searches `searchPath` (PATH by default) for `file`.
static int exec_search(uintptr_t caller, const char *file, const char *searchPath, char *const argv[], char *const envp[]) {
    if (!file || !file[0]) {
        errno = ENOENT;
        return -1;
    }
    if (strchr(file, '/')) return do_execve(caller, file, argv, envp);
    if (!searchPath) {
        searchPath = "/usr/bin:/bin";
        for (char *const *entry = envp; entry && *entry; entry++) {
            if (strncmp(*entry, "PATH=", 5) == 0) {
                searchPath = *entry + 5;
                break;
            }
        }
    }
    int lastError = ENOENT;
    char *paths = strdup(searchPath);
    if (!paths) {
        errno = ENOMEM;
        return -1;
    }
    for (char *cursor = paths, *dir; (dir = strsep(&cursor, ":")); ) {
        char candidate[PATH_MAX];
        snprintf(candidate, sizeof(candidate), "%s/%s", dir[0] ? dir : ".", file);
        do_execve(caller, candidate, argv, envp);
        if (errno == ENOEXEC) {
            // Like execvp(3), run a file that is not a program with sh.
            char *prefix[] = { "sh", candidate };
            char **shellArgv = copy_argv(argv, 1, prefix, 2);
            if (shellArgv) do_execve(caller, "/bin/sh", shellArgv, envp);
            free_argv(shellArgv);
            lastError = errno;
            break;
        }
        if (errno == EACCES) lastError = EACCES;
        else if (errno != ENOENT && errno != ENOTDIR) {
            lastError = errno;
            break;
        }
    }
    free(paths);
    errno = lastError;
    return -1;
}

#pragma mark - Hooks

static int hook_execve(const char *path, char *const argv[], char *const envp[]) {
    return do_execve(CALLER, path, argv, envp);
}

static int hook_execv(const char *path, char *const argv[]) {
    uintptr_t caller = CALLER;
    return do_execve(caller, path, argv, guest_current_environ(caller));
}

static int hook_execvp(const char *file, char *const argv[]) {
    uintptr_t caller = CALLER;
    return exec_search(caller, file, NULL, argv, guest_current_environ(caller));
}

static int hook_execvP(const char *file, const char *searchPath, char *const argv[]) {
    uintptr_t caller = CALLER;
    return exec_search(caller, file, searchPath, argv, guest_current_environ(caller));
}

/// Collects the arguments of execl() and friends into an argv array.
#define COLLECT_EXECL_ARGS(first, args, withEnvironment, environment)          \
    int count_ = 1;                                                            \
    va_start(args, first);                                                     \
    while (va_arg(args, char *)) count_++;                                     \
    va_end(args);                                                              \
    char **argv_ = alloca(sizeof(char *) * (size_t)(count_ + 1));              \
    argv_[0] = (char *)first;                                                  \
    va_start(args, first);                                                     \
    for (int i_ = 1; i_ <= count_; i_++) argv_[i_] = va_arg(args, char *);     \
    if (withEnvironment) environment = va_arg(args, char **);                  \
    va_end(args);

static int hook_execl(const char *path, const char *arg0, ...) {
    uintptr_t caller = CALLER;
    va_list args;
    char **unused = NULL;
    COLLECT_EXECL_ARGS(arg0, args, NO, unused);
    (void)unused;
    return do_execve(caller, path, argv_, guest_current_environ(caller));
}

static int hook_execle(const char *path, const char *arg0, ...) {
    uintptr_t caller = CALLER;
    va_list args;
    char **environment = NULL;
    COLLECT_EXECL_ARGS(arg0, args, YES, environment);
    return do_execve(caller, path, argv_, environment);
}

static int hook_execlp(const char *file, const char *arg0, ...) {
    uintptr_t caller = CALLER;
    va_list args;
    char **unused = NULL;
    COLLECT_EXECL_ARGS(arg0, args, NO, unused);
    (void)unused;
    return exec_search(caller, file, NULL, argv_, guest_current_environ(caller));
}

/// Ends the calling program (or forked child) with `waitStatus`.
__attribute__((noreturn))
static void guest_end(uintptr_t caller, int waitStatus) {
    vfork_ctx *c = child_ctx();
    if (c) {
        // The child's output is still in the parent program's stdio buffers.
        guest_flush_stdio(c->programPid);
        os_unfair_lock_lock(&guest_lock);
        guest_process *g = guest_find_pid_locked(c->pid);
        if (g) guest_mark_exited_locked(g, waitStatus);
        os_unfair_lock_unlock(&guest_lock);
        guest_notify_exit();
        child_finish(c);
    }
    pid_t pid = guest_pid_at(caller);
    if (pid) guest_flush_stdio(pid);
    guest_exit_current(caller, waitStatus);
}

__attribute__((noreturn))
static void guest_exit_with(uintptr_t caller, int status) {
    guest_end(caller, W_EXITCODE(status & 0xff, 0));
}

/// A program that aborts dies of SIGABRT, as far as its parent can tell,
/// instead of leaving it waiting.
__attribute__((noreturn))
static void hook_abort(void) {
    uintptr_t caller = CALLER;
    if (!child_ctx() && !guest_pid_at(caller)) abort();
    NSLog(@"A guest called abort()");
    guest_end(caller, SIGABRT);
}

__attribute__((noreturn))
static void hook_exit(int status) {
    guest_exit_with(CALLER, status);
}

void guest_end_calling_thread(int waitStatus) {
    // Address 0 is in no image: the thread's own guest, if any, is used.
    if (!child_ctx() && !guest_pid_at(0)) return;
    guest_end(0, waitStatus);
}

static pid_t guest_wait(uintptr_t callerAddress, pid_t pid, int *status, int options, struct rusage *usage) {
    if (pid > 0 && pid < GUEST_PID_BASE) return wait4(pid, status, options, usage);

    vfork_ctx *c = child_ctx();
    os_unfair_lock_lock(&guest_lock);
    guest_process *caller = guest_find_address_locked(callerAddress);
    pid_t callerPid = c ? c->pid : (caller ? caller->pid : 0);
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

static pid_t hook_wait4(pid_t pid, int *status, int options, struct rusage *usage) {
    return guest_wait(CALLER, pid, status, options, usage);
}

static pid_t hook_waitpid(pid_t pid, int *status, int options) {
    return guest_wait(CALLER, pid, status, options, NULL);
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
        // A program signalling itself, as `kill $$` does, ends.
        BOOL fatal = sig == SIGTERM || sig == SIGKILL || sig == SIGINT || sig == SIGHUP || sig == SIGQUIT || sig == SIGABRT;
        if (fatal && !child_ctx() && guest_pid_at(CALLER) == pid) guest_exit_current(CALLER, sig);
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

// SIGPIPE stays ignored for the whole process: one guest writing to a closed
// pipe must not take the app and every other guest down. Guests get EPIPE,
// and see the disposition they asked for.
static struct sigaction guest_sigpipe_action = { .sa_handler = SIG_DFL };
static os_unfair_lock guest_sigpipe_lock = OS_UNFAIR_LOCK_INIT;

static int hook_sigaction(int sig, const struct sigaction *act, struct sigaction *oact) {
    BOOL mayChange = !child_ctx() && !(act && guest_is_spawned(CALLER));
    if (sig == SIGPIPE) {
        os_unfair_lock_lock(&guest_sigpipe_lock);
        if (oact) *oact = guest_sigpipe_action;
        if (act && mayChange) guest_sigpipe_action = *act;
        os_unfair_lock_unlock(&guest_sigpipe_lock);
        return 0;
    }
    // Handlers are process-wide. A forked child must not clear its parent's,
    // and a program started by another guest must not replace them.
    if (!mayChange) {
        return oact ? sigaction(sig, NULL, oact) : 0;
    }
    return sigaction(sig, act, oact);
}

static void (*hook_signal(int sig, void (*handler)(int)))(int) {
    if (sig != SIGPIPE) return signal(sig, handler);
    struct sigaction act = { .sa_handler = handler }, old;
    hook_sigaction(sig, &act, &old);
    return old.sa_handler;
}

static pid_t hook_getpid(void) {
    vfork_ctx *c = child_ctx();
    if (c) return c->pid;
    pid_t pid = guest_pid_at(CALLER);
    return pid ? pid : getpid();
}

static pid_t hook_getppid(void) {
    vfork_ctx *c = child_ctx();
    if (c) return c->parentPid ? c->parentPid : getpid();
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(CALLER);
    pid_t ppid = (g && g->spawned) ? (g->ppid ? g->ppid : 1) : getppid();
    os_unfair_lock_unlock(&guest_lock);
    return ppid;
}

static pid_t hook_setsid(void) {
    vfork_ctx *c = child_ctx();
    return c ? c->pid : setsid();
}

/// Guests share the app's process group and cannot leave it; a shell setting
/// up job control is told it succeeded.
static int hook_setpgid(pid_t pid, pid_t pgid) {
    if (child_ctx()) return 0;
    int result = setpgid(pid, pgid);
    return result != 0 && errno == EPERM ? 0 : result;
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

/// Records the calling thread's new working directory as its program's.
static void guest_note_cwd(uintptr_t caller) {
    vfork_ctx *c = child_ctx();
    if (c) {
        c->changedCwd = YES;
        return;
    }
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) return;
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    if (g) strlcpy(g->cwd, cwd, sizeof(g->cwd));
    os_unfair_lock_unlock(&guest_lock);
}

static int hook_chdir(const char *path) {
    char buffer[PATH_MAX];
    path = guest_root_map(path, buffer);
    if (pthread_chdir_np(path) != 0) return -1;
    guest_note_cwd(CALLER);
    return 0;
}

static int map_fd(int fd, uintptr_t caller);

static int hook_fchdir(int fd) {
    uintptr_t caller = CALLER;
    if (pthread_fchdir_np(map_fd(fd, caller)) != 0) return -1;
    guest_note_cwd(caller);
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
    pthread_setspecific(guest_thread_key, g);
    guest_enter_cwd(g);
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

#pragma mark - Process information

// Seen by callers outside any guest image, such as a library a program
// loaded: the most recently started program's.
static int fallback_argc;
static char **fallback_argv;
static char fallback_executable_path[PATH_MAX];

void guest_set_process_info(pid_t pid, int argc, char **argv, char **envp, const char *executablePath) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_pid_locked(pid);
    if (g) {
        g->argc = argc;
        g->argv = argv;
        strlcpy(g->executablePath, executablePath, sizeof(g->executablePath));
        // The old program's threads may still be reading the previous array
        // after an exec, so it is not freed.
        g->environ = envp;
        g->ownedEnviron = NULL;
    }
    fallback_argc = argc;
    fallback_argv = argv;
    strlcpy(fallback_executable_path, executablePath, sizeof(fallback_executable_path));
    os_unfair_lock_unlock(&guest_lock);
}

static int *hook_NSGetArgc(void) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(CALLER);
    int *result = g ? &g->argc : &fallback_argc;
    os_unfair_lock_unlock(&guest_lock);
    return result;
}

static char ***hook_NSGetArgv(void) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(CALLER);
    char ***result = g ? &g->argv : &fallback_argv;
    os_unfair_lock_unlock(&guest_lock);
    return result;
}

static int hook_NSGetExecutablePath(char *buf, uint32_t *bufsize) {
    char path[PATH_MAX];
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(CALLER);
    strlcpy(path, g ? g->executablePath : fallback_executable_path, sizeof(path));
    os_unfair_lock_unlock(&guest_lock);
    uint32_t needed = (uint32_t)strlen(path) + 1;
    if (*bufsize < needed) {
        *bufsize = needed;
        return -1;
    }
    memcpy(buf, path, needed);
    return 0;
}

static char ***hook_NSGetEnviron(void) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(CALLER);
    char ***result = g ? &g->environ : _NSGetEnviron();
    os_unfair_lock_unlock(&guest_lock);
    return result;
}

/// dlopen() for the program whose code is at `caller`, of a loadable copy
/// if `path` is a library built for macOS.
static void *guest_dlopen(uintptr_t caller, const char *path, int mode) {
    if (!path || !guest_library_loader) return dlopen(path, mode);
    char executablePath[PATH_MAX] = "";
    const void *header = NULL;
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    if (g) {
        header = g->header;
        strlcpy(executablePath, g->executablePath, sizeof(executablePath));
    }
    os_unfair_lock_unlock(&guest_lock);
    Dl_info image;
    if (!header || !dladdr(header, &image) || !image.dli_fname) return dlopen(path, mode);
    const char *programImage = image.dli_fname;
    char buffer[PATH_MAX];
    const char *mapped = guest_root_map(path, buffer);
    char loadable[PATH_MAX];
    if (mapped[0] == '/' && guest_library_loader(mapped, programImage, executablePath, loadable)) {
        void *handle = dlopen(loadable, mode);
        if (handle) {
            os_unfair_lock_lock(&guest_lock);
            guest_process *owner = guest_find_address_locked(caller);
            os_unfair_lock_unlock(&guest_lock);
            guest_hook_libraries(owner);
        }
        return handle;
    }
    return dlopen(path, mode);
}

/// Opens a patched copy of a library a program loads itself, such as a Ruby
/// extension: built for macOS, the original cannot be loaded here. What it
/// opens is closed when it exits.
static void *hook_dlopen(const char *path, int mode) {
    uintptr_t caller = CALLER;
    void *handle = guest_dlopen(caller, path, mode);
    if (!handle || !path) return handle;
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    if (g && grow((void **)&g->opened, &g->openedCapacity, g->openedCount, sizeof(void *))) {
        g->opened[g->openedCount++] = handle;
    }
    os_unfair_lock_unlock(&guest_lock);
    return handle;
}

static int hook_dlclose(void *handle) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(CALLER);
    for (int i = g ? g->openedCount - 1 : -1; i >= 0; i--) {
        if (g->opened[i] != handle) continue;
        memmove(&g->opened[i], &g->opened[i + 1], (size_t)(g->openedCount - i - 1) * sizeof(void *));
        g->openedCount--;
        break;
    }
    os_unfair_lock_unlock(&guest_lock);
    return dlclose(handle);
}

/// For an address in a program's own image, names the program's file rather
/// than the patched copy that was loaded, so programs that find their files
/// relative to themselves (Ruby's load path) look in the right place.
static int hook_dladdr(const void *address, Dl_info *info) {
    int result = dladdr(address, info);
    if (!result) return result;
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked((uintptr_t)address);
    if (g && info->dli_fbase == (void *)g->header && g->executablePath[0]) {
        info->dli_fname = g->executablePath;
    }
    os_unfair_lock_unlock(&guest_lock);
    return result;
}

static const char *hook_getprogname(void) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(CALLER);
    const char *name = (g && g->argv && g->argv[0]) ? g->argv[0] : NULL;
    os_unfair_lock_unlock(&guest_lock);
    if (!name) return getprogname();
    const char *slash = strrchr(name, '/');
    return slash ? slash + 1 : name;
}

static char **guest_current_environ(uintptr_t caller) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    char **result = g ? g->environ : *_NSGetEnviron();
    os_unfair_lock_unlock(&guest_lock);
    return result;
}

#pragma mark - Users and groups

// iOS has no account database for the app's user, so programs that look up
// their own user or group (id, Homebrew) get one made up here: "mobile",
// with the program's $HOME.
#define GUEST_USER_NAME "mobile"

static BOOL guest_is_own_uid(uid_t uid) { return uid == getuid() || uid == geteuid(); }
static BOOL guest_is_own_gid(gid_t gid) { return gid == getgid() || gid == getegid(); }

/// Copies `string` into the caller's buffer for a *_r lookup.
static char *guest_store(const char *string, char **buffer, size_t *remaining) {
    size_t length = strlen(string) + 1;
    if (length > *remaining) return NULL;
    char *result = memcpy(*buffer, string, length);
    *buffer += length;
    *remaining -= length;
    return result;
}

static int guest_own_passwd(uintptr_t caller, struct passwd *pw, char *buffer, size_t size) {
    const char *home = NULL;
    char **environment = guest_current_environ(caller);
    for (char **entry = environment; entry && *entry; entry++) {
        if (strncmp(*entry, "HOME=", 5) == 0) home = *entry + 5;
    }
    if (!home) home = "/";
    memset(pw, 0, sizeof(*pw));
    pw->pw_uid = geteuid();
    pw->pw_gid = getegid();
    if (!(pw->pw_name = guest_store(GUEST_USER_NAME, &buffer, &size)) ||
        !(pw->pw_passwd = guest_store("*", &buffer, &size)) ||
        !(pw->pw_gecos = guest_store("Mobile User", &buffer, &size)) ||
        !(pw->pw_dir = guest_store(home, &buffer, &size)) ||
        !(pw->pw_shell = guest_store("/bin/bash", &buffer, &size)) ||
        !(pw->pw_class = guest_store("", &buffer, &size))) {
        return ERANGE;
    }
    return 0;
}

static int guest_own_group(struct group *gr, char *buffer, size_t size) {
    memset(gr, 0, sizeof(*gr));
    gr->gr_gid = getegid();
    // gr_mem: a pointer-aligned, empty member list.
    uintptr_t aligned = ((uintptr_t)buffer + sizeof(char *) - 1) & ~(uintptr_t)(sizeof(char *) - 1);
    if (aligned + sizeof(char *) > (uintptr_t)buffer + size) return ERANGE;
    size -= aligned + sizeof(char *) - (uintptr_t)buffer;
    gr->gr_mem = (char **)aligned;
    gr->gr_mem[0] = NULL;
    buffer = (char *)(aligned + sizeof(char *));
    if (!(gr->gr_name = guest_store(GUEST_USER_NAME, &buffer, &size)) ||
        !(gr->gr_passwd = guest_store("*", &buffer, &size))) {
        return ERANGE;
    }
    return 0;
}

static struct passwd guest_passwd;
static char guest_passwd_buffer[PATH_MAX + 256];
static struct group guest_group;
static char guest_group_buffer[256];

static struct passwd *hook_getpwuid(uid_t uid) {
    struct passwd *result = getpwuid(uid);
    if (result || !guest_is_own_uid(uid)) return result;
    return guest_own_passwd(CALLER, &guest_passwd, guest_passwd_buffer, sizeof(guest_passwd_buffer)) == 0 ? &guest_passwd : NULL;
}

static struct passwd *hook_getpwnam(const char *name) {
    struct passwd *result = getpwnam(name);
    if (result || !name || strcmp(name, GUEST_USER_NAME) != 0) return result;
    return guest_own_passwd(CALLER, &guest_passwd, guest_passwd_buffer, sizeof(guest_passwd_buffer)) == 0 ? &guest_passwd : NULL;
}

static int hook_getpwuid_r(uid_t uid, struct passwd *pw, char *buffer, size_t size, struct passwd **result) {
    int err = getpwuid_r(uid, pw, buffer, size, result);
    if ((err == 0 && *result) || !guest_is_own_uid(uid)) return err;
    err = guest_own_passwd(CALLER, pw, buffer, size);
    *result = err == 0 ? pw : NULL;
    return err;
}

static int hook_getpwnam_r(const char *name, struct passwd *pw, char *buffer, size_t size, struct passwd **result) {
    int err = getpwnam_r(name, pw, buffer, size, result);
    if ((err == 0 && *result) || !name || strcmp(name, GUEST_USER_NAME) != 0) return err;
    err = guest_own_passwd(CALLER, pw, buffer, size);
    *result = err == 0 ? pw : NULL;
    return err;
}

static struct group *hook_getgrgid(gid_t gid) {
    struct group *result = getgrgid(gid);
    if (result || !guest_is_own_gid(gid)) return result;
    return guest_own_group(&guest_group, guest_group_buffer, sizeof(guest_group_buffer)) == 0 ? &guest_group : NULL;
}

static struct group *hook_getgrnam(const char *name) {
    struct group *result = getgrnam(name);
    if (result || !name || strcmp(name, GUEST_USER_NAME) != 0) return result;
    return guest_own_group(&guest_group, guest_group_buffer, sizeof(guest_group_buffer)) == 0 ? &guest_group : NULL;
}

static int hook_getgrgid_r(gid_t gid, struct group *gr, char *buffer, size_t size, struct group **result) {
    int err = getgrgid_r(gid, gr, buffer, size, result);
    if ((err == 0 && *result) || !guest_is_own_gid(gid)) return err;
    err = guest_own_group(gr, buffer, size);
    *result = err == 0 ? gr : NULL;
    return err;
}

static int hook_getgrnam_r(const char *name, struct group *gr, char *buffer, size_t size, struct group **result) {
    int err = getgrnam_r(name, gr, buffer, size, result);
    if ((err == 0 && *result) || !name || strcmp(name, GUEST_USER_NAME) != 0) return err;
    err = guest_own_group(gr, buffer, size);
    *result = err == 0 ? gr : NULL;
    return err;
}

#pragma mark - Environment

// Each program has its own environment, from the envp it was started with.
// Arrays replaced by setenv() are not freed: getenv() results point into
// them, and another thread may be reading one.

static char *env_find(char **env, const char *name, size_t length) {
    for (; env && *env; env++) {
        if (strncmp(*env, name, length) == 0 && (*env)[length] == '=') return *env;
    }
    return NULL;
}

/// Replaces the variable `entry` ("NAME=value") names, or adds it.
static int env_put_locked(guest_process *g, char *entry, size_t nameLength) {
    int count = 0;
    while (g->environ && g->environ[count]) count++;
    char **next = malloc(sizeof(char *) * (size_t)(count + 2));
    if (!next) return ENOMEM;
    int used = 0;
    BOOL replaced = NO;
    for (int i = 0; i < count; i++) {
        char *existing = g->environ[i];
        if (!replaced && strncmp(existing, entry, nameLength) == 0 && existing[nameLength] == '=') {
            next[used++] = entry;
            replaced = YES;
        } else {
            next[used++] = existing;
        }
    }
    if (!replaced) next[used++] = entry;
    next[used] = NULL;
    g->environ = next;
    g->ownedEnviron = next;
    return 0;
}

static char *hook_getenv(const char *name) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(CALLER);
    if (!g) {
        os_unfair_lock_unlock(&guest_lock);
        return getenv(name);
    }
    char *entry = name ? env_find(g->environ, name, strlen(name)) : NULL;
    os_unfair_lock_unlock(&guest_lock);
    return entry ? entry + strlen(name) + 1 : NULL;
}

static BOOL env_valid_name(const char *name) {
    return name && name[0] && !strchr(name, '=');
}

static int hook_setenv(const char *name, const char *value, int overwrite) {
    uintptr_t caller = CALLER;
    if (guest_pid_at(caller) == 0) return setenv(name, value, overwrite);
    if (!env_valid_name(name)) {
        errno = EINVAL;
        return -1;
    }
    size_t length = strlen(name);
    if (!value) value = "";
    char *entry = malloc(length + strlen(value) + 2);
    if (!entry) {
        errno = ENOMEM;
        return -1;
    }
    sprintf(entry, "%s=%s", name, value);
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    int err = 0;
    if (g && (overwrite || !env_find(g->environ, name, length))) {
        err = env_put_locked(g, entry, length);
    } else {
        free(entry);
    }
    os_unfair_lock_unlock(&guest_lock);
    if (err) {
        errno = err;
        return -1;
    }
    return 0;
}

static int hook_putenv(char *string) {
    uintptr_t caller = CALLER;
    if (guest_pid_at(caller) == 0) return putenv(string);
    char *equals = string ? strchr(string, '=') : NULL;
    if (!equals || equals == string) {
        errno = EINVAL;
        return -1;
    }
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    int err = g ? env_put_locked(g, string, (size_t)(equals - string)) : 0;
    os_unfair_lock_unlock(&guest_lock);
    if (err) {
        errno = err;
        return -1;
    }
    return 0;
}

static int hook_unsetenv(const char *name) {
    uintptr_t caller = CALLER;
    if (guest_pid_at(caller) == 0) return unsetenv(name);
    if (!env_valid_name(name)) {
        errno = EINVAL;
        return -1;
    }
    size_t length = strlen(name);
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    if (g && env_find(g->environ, name, length)) {
        int count = 0;
        while (g->environ[count]) count++;
        char **next = malloc(sizeof(char *) * (size_t)(count + 1));
        if (next) {
            int used = 0;
            for (int i = 0; i < count; i++) {
                char *existing = g->environ[i];
                if (strncmp(existing, name, length) == 0 && existing[length] == '=') continue;
                next[used++] = existing;
            }
            next[used] = NULL;
            g->environ = next;
            g->ownedEnviron = next;
        }
    }
    os_unfair_lock_unlock(&guest_lock);
    return 0;
}

#pragma mark - Standard I/O

// Each program gets its own stdin/stdout/stderr FILEs, which read and write
// whatever its descriptors 0, 1 and 2 are at the time, including a forked
// child's redirections. libc's own would use the app's descriptors.

static int guest_stdio_descriptor(void *cookie) {
    pid_t pid = (pid_t)((intptr_t)cookie >> 2);
    int fd = (int)((intptr_t)cookie & 3);
    vfork_ctx *c = child_ctx();
    if (c) return child_resolve(c, fd);
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_pid_locked(pid);
    int real = g ? g->fds[fd] : -1;
    os_unfair_lock_unlock(&guest_lock);
    if (real == -1) return fd;
    return real == GUEST_FD_CLOSED ? -1 : real;
}

static int guest_stdio_read(void *cookie, char *buffer, int length) {
    int fd = guest_stdio_descriptor(cookie);
    if (fd < 0) {
        errno = EBADF;
        return -1;
    }
    return (int)read(fd, buffer, (size_t)length);
}

static int guest_stdio_write(void *cookie, const char *buffer, int length) {
    int fd = guest_stdio_descriptor(cookie);
    if (fd < 0) {
        errno = EBADF;
        return -1;
    }
    return (int)write(fd, buffer, (size_t)length);
}

static int guest_stdio_close(void *cookie) {
    return 0;
}

static void guest_open_stdio_locked(guest_process *g) {
    for (int fd = 0; fd < 3; fd++) {
        if (g->stdio[fd]) continue;
        FILE *file = funopen((void *)(intptr_t)(g->pid * 4 + fd),
                             fd == 0 ? guest_stdio_read : NULL,
                             fd == 0 ? NULL : guest_stdio_write,
                             NULL, guest_stdio_close);
        if (!file) continue;
        // What fileno() returns; the program's hooked calls map it.
        file->_file = (short)fd;
        int real = g->fds[fd] == -1 ? fd : g->fds[fd];
        int mode = fd == 2 ? _IONBF : (fd == 1 && real >= 0 && isatty(real)) ? _IOLBF : _IOFBF;
        setvbuf(file, NULL, mode, mode == _IONBF ? 0 : BUFSIZ);
        g->stdio[fd] = file;
    }
}

static void guest_flush_stdio(pid_t pid) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_pid_locked(pid);
    FILE *out = g ? g->stdio[1] : NULL;
    FILE *err = g ? g->stdio[2] : NULL;
    os_unfair_lock_unlock(&guest_lock);
    if (out) fflush(out);
    if (err) fflush(err);
}

static FILE *guest_stdio(uintptr_t caller, int fd) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    FILE *file = g ? g->stdio[fd] : NULL;
    os_unfair_lock_unlock(&guest_lock);
    if (file) return file;
    return fd == 0 ? stdin : fd == 1 ? stdout : stderr;
}

static int hook_fclose(FILE *file) {
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(CALLER);
    BOOL own = g && file && (file == g->stdio[0] || file == g->stdio[1] || file == g->stdio[2]);
    os_unfair_lock_unlock(&guest_lock);
    // The FILE outlives the program's use of it; the descriptor stays open.
    if (own) return fflush(file);
    return fclose(file);
}

static int hook_printf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    int result = vfprintf(guest_stdio(CALLER, 1), format, args);
    va_end(args);
    return result;
}

static int hook_vprintf(const char *format, va_list args) {
    return vfprintf(guest_stdio(CALLER, 1), format, args);
}

static int hook_puts(const char *string) {
    FILE *file = guest_stdio(CALLER, 1);
    if (fputs(string, file) == EOF || putc('\n', file) == EOF) return EOF;
    return 0;
}

static int hook_putchar(int c) {
    return putc(c, guest_stdio(CALLER, 1));
}

static int hook_putchar_unlocked(int c) {
    return putc_unlocked(c, guest_stdio(CALLER, 1));
}

static int hook_getchar(void) {
    return getc(guest_stdio(CALLER, 0));
}

static int hook_getchar_unlocked(void) {
    return getc_unlocked(guest_stdio(CALLER, 0));
}

static int hook_scanf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    int result = vfscanf(guest_stdio(CALLER, 0), format, args);
    va_end(args);
    return result;
}

static int hook_vscanf(const char *format, va_list args) {
    return vfscanf(guest_stdio(CALLER, 0), format, args);
}

static void hook_perror(const char *message) {
    int code = errno;
    FILE *file = guest_stdio(CALLER, 2);
    if (message && message[0]) fprintf(file, "%s: ", message);
    fprintf(file, "%s\n", strerror(code));
    errno = code;
}

/// err(3) and warn(3), which would otherwise print the app's name to the app's stderr.
static void guest_vwarn(uintptr_t caller, BOOL withCode, int code, const char *format, va_list args) {
    FILE *file = guest_stdio(caller, 2);
    os_unfair_lock_lock(&guest_lock);
    guest_process *g = guest_find_address_locked(caller);
    const char *name = (g && g->argv && g->argv[0]) ? g->argv[0] : getprogname();
    os_unfair_lock_unlock(&guest_lock);
    const char *slash = strrchr(name, '/');
    fprintf(file, "%s: ", slash ? slash + 1 : name);
    if (format) {
        vfprintf(file, format, args);
        if (withCode) fputs(": ", file);
    }
    if (withCode) fputs(strerror(code), file);
    putc('\n', file);
}

#define WARN_HOOK(hookName, withCode, codeExpression)                          \
    static void hookName(const char *format, ...) {                            \
        int code_ = (codeExpression);                                          \
        va_list args;                                                          \
        va_start(args, format);                                                \
        guest_vwarn(CALLER, withCode, code_, format, args);                    \
        va_end(args);                                                          \
    }

WARN_HOOK(hook_warn, YES, errno)
WARN_HOOK(hook_warnx, NO, 0)

static void hook_vwarn(const char *format, va_list args) {
    guest_vwarn(CALLER, YES, errno, format, args);
}

static void hook_vwarnx(const char *format, va_list args) {
    guest_vwarn(CALLER, NO, 0, format, args);
}

static void hook_warnc(int code, const char *format, ...) {
    va_list args;
    va_start(args, format);
    guest_vwarn(CALLER, YES, code, format, args);
    va_end(args);
}

static void hook_vwarnc(int code, const char *format, va_list args) {
    guest_vwarn(CALLER, YES, code, format, args);
}

__attribute__((noreturn)) static void hook_err(int status, const char *format, ...) {
    uintptr_t caller = CALLER;
    va_list args;
    va_start(args, format);
    guest_vwarn(caller, YES, errno, format, args);
    va_end(args);
    guest_exit_with(caller, status);
}

__attribute__((noreturn)) static void hook_errx(int status, const char *format, ...) {
    uintptr_t caller = CALLER;
    va_list args;
    va_start(args, format);
    guest_vwarn(caller, NO, 0, format, args);
    va_end(args);
    guest_exit_with(caller, status);
}

__attribute__((noreturn)) static void hook_errc(int status, int code, const char *format, ...) {
    uintptr_t caller = CALLER;
    va_list args;
    va_start(args, format);
    guest_vwarn(caller, YES, code, format, args);
    va_end(args);
    guest_exit_with(caller, status);
}

__attribute__((noreturn)) static void hook_verr(int status, const char *format, va_list args) {
    uintptr_t caller = CALLER;
    guest_vwarn(caller, YES, errno, format, args);
    guest_exit_with(caller, status);
}

__attribute__((noreturn)) static void hook_verrx(int status, const char *format, va_list args) {
    uintptr_t caller = CALLER;
    guest_vwarn(caller, NO, 0, format, args);
    guest_exit_with(caller, status);
}

__attribute__((noreturn)) static void hook_verrc(int status, int code, const char *format, va_list args) {
    uintptr_t caller = CALLER;
    guest_vwarn(caller, YES, code, format, args);
    guest_exit_with(caller, status);
}

#pragma mark - Paths

// Absolute paths under /bin, /usr and /etc go through the guest root.
#define MAP_PATH(path) char path##_buffer[PATH_MAX]; path = guest_root_map(path, path##_buffer)

/// N for "/dev/fd/N", else -1. A device's sandbox hides /dev/fd, which
/// bash's process substitution (`<(...)`) hands to commands.
static int dev_fd_number(const char *path) {
    if (!path || strncmp(path, "/dev/fd/", 8) != 0) return -1;
    char *end;
    long number = strtol(path + 8, &end, 10);
    return end == path + 8 || *end || number < 0 || number > INT_MAX ? -1 : (int)number;
}

/// Opening /dev/fd/N duplicates descriptor N, as on macOS.
static int open_dev_fd(int number, int flags, uintptr_t caller) {
    int fd = fcntl(map_fd(number, caller), (flags & O_CLOEXEC) ? F_DUPFD_CLOEXEC : F_DUPFD, 0);
    vfork_ctx *c = child_ctx();
    return c ? child_adopt(c, fd, (flags & O_CLOEXEC) != 0) : fd;
}

static int hook_open(const char *path, int flags, ...) {
    uintptr_t caller = CALLER;
    int number = dev_fd_number(path);
    if (number >= 0) return open_dev_fd(number, flags, caller);
    int mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, int);
        va_end(args);
    }
    MAP_PATH(path);
    int fd = open(path, flags, mode);
    vfork_ctx *c = child_ctx();
    return c ? child_adopt(c, fd, (flags & O_CLOEXEC) != 0) : fd;
}

static int hook_openat(int fd, const char *path, int flags, ...) {
    uintptr_t caller = CALLER;
    int number = dev_fd_number(path);
    if (number >= 0) return open_dev_fd(number, flags, caller);
    int mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, int);
        va_end(args);
    }
    MAP_PATH(path);
    vfork_ctx *c = child_ctx();
    if (c && fd >= 0) fd = map_fd(fd, 0);
    int result = openat(fd, path, flags, mode);
    return c ? child_adopt(c, result, (flags & O_CLOEXEC) != 0) : result;
}

static int hook_pipe(int fds[2]) {
    vfork_ctx *c = child_ctx();
    if (!c) return pipe(fds);
    int real[2];
    if (pipe(real) != 0) return -1;
    fds[0] = child_adopt(c, real[0], NO);
    fds[1] = child_adopt(c, real[1], NO);
    if (fds[0] < 0 || fds[1] < 0) {
        if (fds[0] >= 0) hook_close(fds[0]);
        if (fds[1] >= 0) hook_close(fds[1]);
        errno = EMFILE;
        return -1;
    }
    return 0;
}

static int hook_socket(int domain, int type, int protocol) {
    int fd = socket(domain, type, protocol);
    vfork_ctx *c = child_ctx();
    return c ? child_adopt(c, fd, NO) : fd;
}

static int hook_socketpair(int domain, int type, int protocol, int fds[2]) {
    vfork_ctx *c = child_ctx();
    if (!c) return socketpair(domain, type, protocol, fds);
    int real[2];
    if (socketpair(domain, type, protocol, real) != 0) return -1;
    fds[0] = child_adopt(c, real[0], NO);
    fds[1] = child_adopt(c, real[1], NO);
    return (fds[0] < 0 || fds[1] < 0) ? -1 : 0;
}

static int hook_mkstemp(char *template) {
    int fd = mkstemp(template);
    vfork_ctx *c = child_ctx();
    return c ? child_adopt(c, fd, NO) : fd;
}

static int hook_mkstemps(char *template, int suffixLength) {
    int fd = mkstemps(template, suffixLength);
    vfork_ctx *c = child_ctx();
    return c ? child_adopt(c, fd, NO) : fd;
}

static int hook_mkostemp(char *template, int flags) {
    int fd = mkostemp(template, flags);
    vfork_ctx *c = child_ctx();
    return c ? child_adopt(c, fd, (flags & O_CLOEXEC) != 0) : fd;
}

static FILE *hook_fopen(const char *path, const char *mode) {
    MAP_PATH(path);
    return fopen(path, mode);
}

static int hook_stat(const char *path, struct stat *st) {
    uintptr_t caller = CALLER;
    int number = dev_fd_number(path);
    if (number >= 0) return fstat(map_fd(number, caller), st);
    MAP_PATH(path);
    return stat(path, st);
}

static int hook_lstat(const char *path, struct stat *st) {
    MAP_PATH(path);
    return lstat(path, st);
}

static int hook_fstatat(int fd, const char *path, struct stat *st, int flag) {
    MAP_PATH(path);
    return fstatat(fd, path, st, flag);
}

static int hook_access(const char *path, int mode) {
    MAP_PATH(path);
    return guest_faccessat(AT_FDCWD, path, mode, 0);
}

static int hook_faccessat(int fd, const char *path, int mode, int flag) {
    MAP_PATH(path);
    return guest_faccessat(fd, path, mode, flag);
}

static DIR *hook_opendir(const char *path) {
    MAP_PATH(path);
    return opendir(path);
}

// The other calls that take paths, so a mapped directory (the temporary
// ones, see GuestRoot.m) can be written to like any other.
static int hook_mkdir(const char *path, mode_t mode) { MAP_PATH(path); return mkdir(path, mode); }
static int hook_mkdirat(int fd, const char *path, mode_t mode) { MAP_PATH(path); return mkdirat(fd, path, mode); }
static int hook_rmdir(const char *path) { MAP_PATH(path); return rmdir(path); }
static int hook_unlink(const char *path) { MAP_PATH(path); return unlink(path); }
static int hook_unlinkat(int fd, const char *path, int flag) { MAP_PATH(path); return unlinkat(fd, path, flag); }
static int hook_rename(const char *from, const char *to) { MAP_PATH(from); MAP_PATH(to); return rename(from, to); }
static int hook_renameat(int fromfd, const char *from, int tofd, const char *to) { MAP_PATH(from); MAP_PATH(to); return renameat(fromfd, from, tofd, to); }
static int hook_symlink(const char *target, const char *path) { MAP_PATH(path); return symlink(target, path); }
static int hook_symlinkat(const char *target, int fd, const char *path) { MAP_PATH(path); return symlinkat(target, fd, path); }
static int hook_link(const char *from, const char *to) { MAP_PATH(from); MAP_PATH(to); return link(from, to); }
static int hook_linkat(int fromfd, const char *from, int tofd, const char *to, int flag) { MAP_PATH(from); MAP_PATH(to); return linkat(fromfd, from, tofd, to, flag); }
static int hook_chmod(const char *path, mode_t mode) { MAP_PATH(path); return chmod(path, mode); }
static int hook_fchmodat(int fd, const char *path, mode_t mode, int flag) { MAP_PATH(path); return fchmodat(fd, path, mode, flag); }
static int hook_chown(const char *path, uid_t uid, gid_t gid) { MAP_PATH(path); return chown(path, uid, gid); }
static int hook_lchown(const char *path, uid_t uid, gid_t gid) { MAP_PATH(path); return lchown(path, uid, gid); }
static int hook_truncate(const char *path, off_t length) { MAP_PATH(path); return truncate(path, length); }
static int hook_utimes(const char *path, const struct timeval times[2]) { MAP_PATH(path); return utimes(path, times); }
static int hook_lutimes(const char *path, const struct timeval times[2]) { MAP_PATH(path); return lutimes(path, times); }
static int hook_utimensat(int fd, const char *path, const struct timespec times[2], int flag) { MAP_PATH(path); return utimensat(fd, path, times, flag); }
static int hook_mkfifo(const char *path, mode_t mode) { MAP_PATH(path); return mkfifo(path, mode); }
static int hook_statfs(const char *path, struct statfs *buffer) { MAP_PATH(path); return statfs(path, buffer); }

static ssize_t hook_readlink(const char *path, char *buffer, size_t size) {
    MAP_PATH(path);
    return readlink(path, buffer, size);
}

static char *hook_realpath(const char *path, char *resolved) {
    MAP_PATH(path);
    return realpath(path, resolved);
}

#pragma mark - Memory

// A forked child shares the parent's memory. Programs with their own heap
// get it back as it was when the child ends. Other memory the child frees
// may still be the parent's, so it is left alone.

static inline guest_heap *current_heap(void) {
    guest_process *g = pthread_getspecific(guest_thread_key);
    return g ? g->heap : NULL;
}

static void *hook_malloc(size_t size) {
    guest_heap *heap = current_heap();
    return heap ? guest_heap_malloc(heap, size) : malloc(size);
}

static void *hook_calloc(size_t count, size_t size) {
    guest_heap *heap = current_heap();
    if (!heap) return calloc(count, size);
    size_t total;
    if (__builtin_mul_overflow(count, size, &total)) return NULL;
    void *result = guest_heap_malloc(heap, total);
    if (result) memset(result, 0, total);
    return result;
}

static void hook_free(void *pointer) {
    if (!pointer) return;
    guest_heap *heap = current_heap();
    if (heap && guest_heap_contains(heap, pointer)) {
        guest_heap_free(heap, pointer);
        return;
    }
    if (child_ctx()) return;
    free(pointer);
}

static void *hook_realloc(void *pointer, size_t size) {
    if (!pointer) return hook_malloc(size);
    guest_heap *heap = current_heap();
    BOOL own = heap && guest_heap_contains(heap, pointer);
    if (!own && !child_ctx()) return realloc(pointer, size);
    size_t old = own ? guest_heap_size(heap, pointer) : malloc_size(pointer);
    if (own && size <= old) return pointer;
    void *copy = heap ? guest_heap_malloc(heap, size) : malloc(size ? size : 1);
    if (!copy) return NULL;
    memcpy(copy, pointer, old < size ? old : size);
    if (own) guest_heap_free(heap, pointer);
    return copy;
}

static void *hook_reallocf(void *pointer, size_t size) {
    void *result = hook_realloc(pointer, size);
    if (!result && pointer && size) hook_free(pointer);
    return result;
}

static size_t hook_malloc_size(const void *pointer) {
    guest_heap *heap = current_heap();
    if (heap && guest_heap_contains(heap, pointer)) return guest_heap_size(heap, pointer);
    return malloc_size(pointer);
}

static int hook_posix_memalign(void **result, size_t alignment, size_t size) {
    guest_heap *heap = current_heap();
    if (!heap) return posix_memalign(result, alignment, size);
    if (alignment < sizeof(void *) || (alignment & (alignment - 1))) return EINVAL;
    void *memory = guest_heap_aligned(heap, alignment, size);
    if (!memory) return ENOMEM;
    *result = memory;
    return 0;
}

static void *hook_aligned_alloc(size_t alignment, size_t size) {
    guest_heap *heap = current_heap();
    return heap ? guest_heap_aligned(heap, alignment, size) : aligned_alloc(alignment, size);
}

static void *hook_valloc(size_t size) {
    guest_heap *heap = current_heap();
    return heap ? guest_heap_aligned(heap, PAGE_SIZE, size) : valloc(size);
}

/// Whether the image imports any of `names`.
static BOOL image_imports(const struct mach_header_64 *header, intptr_t slide, const char *const names[], int count) {
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)lc;
        if (lc->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)lc;
        if (lc->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT) == 0) {
            linkedit = (const struct segment_command_64 *)lc;
        }
        cursor += lc->cmdsize;
    }
    if (!symtab || !dysymtab || !linkedit) return NO;
    uintptr_t base = (uintptr_t)(linkedit->vmaddr + slide - linkedit->fileoff);
    const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    for (uint32_t i = dysymtab->iundefsym; i < dysymtab->iundefsym + dysymtab->nundefsym; i++) {
        const char *name = strings + symbols[i].n_un.n_strx;
        if (name[0] != '_') continue;
        for (int j = 0; j < count; j++) {
            if (strcmp(name + 1, names[j]) == 0) return YES;
        }
    }
    return NO;
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

#define GUEST_COUNT(array) (sizeof(array) / sizeof((array)[0]))

/// What a program's calls go to, in its own image and in the libraries it uses.
static struct rebinding guest_function_hooks[] = {
    { "fork", (void *)guest_fork_hook, NULL },
    { "vfork", (void *)guest_fork_hook, NULL },
    { "execve", (void *)hook_execve, NULL },
    { "execv", (void *)hook_execv, NULL },
    { "execvp", (void *)hook_execvp, NULL },
    { "execvP", (void *)hook_execvP, NULL },
    { "execl", (void *)hook_execl, NULL },
    { "execle", (void *)hook_execle, NULL },
    { "execlp", (void *)hook_execlp, NULL },
    { "exit", (void *)hook_exit, NULL },
    { "_exit", (void *)hook_exit, NULL },
    { "abort", (void *)hook_abort, NULL },
    { "wait4", (void *)hook_wait4, NULL },
    { "waitpid", (void *)hook_waitpid, NULL },
    { "kill", (void *)hook_kill, NULL },
    { "raise", (void *)hook_raise, NULL },
    { "sigaction", (void *)hook_sigaction, NULL },
    { "signal", (void *)hook_signal, NULL },
    { "getpid", (void *)hook_getpid, NULL },
    { "getppid", (void *)hook_getppid, NULL },
    { "setsid", (void *)hook_setsid, NULL },
    { "setpgid", (void *)hook_setpgid, NULL },
    { "setrlimit", (void *)hook_setrlimit, NULL },
    { "setgid", (void *)hook_setgid, NULL },
    { "setuid", (void *)hook_setuid, NULL },
    { "setgroups", (void *)hook_setgroups, NULL },
    { "chroot", (void *)hook_chroot, NULL },
    { "chdir", (void *)hook_chdir, NULL },
    { "fchdir", (void *)hook_fchdir, NULL },
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
    { "_NSGetArgc", (void *)hook_NSGetArgc, NULL },
    { "_NSGetArgv", (void *)hook_NSGetArgv, NULL },
    { "_NSGetExecutablePath", (void *)hook_NSGetExecutablePath, NULL },
    { "_NSGetEnviron", (void *)hook_NSGetEnviron, NULL },
    { "getprogname", (void *)hook_getprogname, NULL },
    { "dladdr", (void *)hook_dladdr, NULL },
    { "dlopen", (void *)hook_dlopen, NULL },
    { "dlclose", (void *)hook_dlclose, NULL },
    { "getpwuid", (void *)hook_getpwuid, NULL },
    { "getpwnam", (void *)hook_getpwnam, NULL },
    { "getpwuid_r", (void *)hook_getpwuid_r, NULL },
    { "getpwnam_r", (void *)hook_getpwnam_r, NULL },
    { "getgrgid", (void *)hook_getgrgid, NULL },
    { "getgrnam", (void *)hook_getgrnam, NULL },
    { "getgrgid_r", (void *)hook_getgrgid_r, NULL },
    { "getgrnam_r", (void *)hook_getgrnam_r, NULL },
    { "getenv", (void *)hook_getenv, NULL },
    { "setenv", (void *)hook_setenv, NULL },
    { "putenv", (void *)hook_putenv, NULL },
    { "unsetenv", (void *)hook_unsetenv, NULL },
    { "fclose", (void *)hook_fclose, NULL },
    { "printf", (void *)hook_printf, NULL },
    { "vprintf", (void *)hook_vprintf, NULL },
    { "puts", (void *)hook_puts, NULL },
    { "putchar", (void *)hook_putchar, NULL },
    { "putchar_unlocked", (void *)hook_putchar_unlocked, NULL },
    { "getchar", (void *)hook_getchar, NULL },
    { "getchar_unlocked", (void *)hook_getchar_unlocked, NULL },
    { "scanf", (void *)hook_scanf, NULL },
    { "vscanf", (void *)hook_vscanf, NULL },
    { "perror", (void *)hook_perror, NULL },
    { "warn", (void *)hook_warn, NULL },
    { "warnx", (void *)hook_warnx, NULL },
    { "warnc", (void *)hook_warnc, NULL },
    { "vwarn", (void *)hook_vwarn, NULL },
    { "vwarnx", (void *)hook_vwarnx, NULL },
    { "vwarnc", (void *)hook_vwarnc, NULL },
    { "err", (void *)hook_err, NULL },
    { "errx", (void *)hook_errx, NULL },
    { "errc", (void *)hook_errc, NULL },
    { "verr", (void *)hook_verr, NULL },
    { "verrx", (void *)hook_verrx, NULL },
    { "verrc", (void *)hook_verrc, NULL },
    { "open", (void *)hook_open, NULL },
    { "openat", (void *)hook_openat, NULL },
    { "pipe", (void *)hook_pipe, NULL },
    { "socket", (void *)hook_socket, NULL },
    { "socketpair", (void *)hook_socketpair, NULL },
    { "mkstemp", (void *)hook_mkstemp, NULL },
    { "mkstemps", (void *)hook_mkstemps, NULL },
    { "mkostemp", (void *)hook_mkostemp, NULL },
    { "fopen", (void *)hook_fopen, NULL },
    // What code built with _DARWIN_C_SOURCE (libjq, say) calls.
    { "fopen$DARWIN_EXTSN", (void *)hook_fopen, NULL },
    { "stat", (void *)hook_stat, NULL },
    { "lstat", (void *)hook_lstat, NULL },
    { "fstatat", (void *)hook_fstatat, NULL },
    { "access", (void *)hook_access, NULL },
    { "faccessat", (void *)hook_faccessat, NULL },
    { "opendir", (void *)hook_opendir, NULL },
    { "readlink", (void *)hook_readlink, NULL },
    { "mkdir", (void *)hook_mkdir, NULL },
    { "mkdirat", (void *)hook_mkdirat, NULL },
    { "rmdir", (void *)hook_rmdir, NULL },
    { "unlink", (void *)hook_unlink, NULL },
    { "unlinkat", (void *)hook_unlinkat, NULL },
    { "rename", (void *)hook_rename, NULL },
    { "renameat", (void *)hook_renameat, NULL },
    { "symlink", (void *)hook_symlink, NULL },
    { "symlinkat", (void *)hook_symlinkat, NULL },
    { "link", (void *)hook_link, NULL },
    { "linkat", (void *)hook_linkat, NULL },
    { "chmod", (void *)hook_chmod, NULL },
    { "fchmodat", (void *)hook_fchmodat, NULL },
    { "chown", (void *)hook_chown, NULL },
    { "lchown", (void *)hook_lchown, NULL },
    { "truncate", (void *)hook_truncate, NULL },
    { "utimes", (void *)hook_utimes, NULL },
    { "lutimes", (void *)hook_lutimes, NULL },
    { "utimensat", (void *)hook_utimensat, NULL },
    { "mkfifo", (void *)hook_mkfifo, NULL },
    { "statfs", (void *)hook_statfs, NULL },
    { "realpath$DARWIN_EXTSN", (void *)hook_realpath, NULL },
};

/// Allocation goes to the program's private heap, if it has one (see
/// GuestHeap.h). Only its own image's: libraries are shared by programs and
/// keep what they allocate past any one program's heap.
static struct rebinding guest_heap_hooks[] = {
    { "malloc", (void *)hook_malloc, NULL },
    { "calloc", (void *)hook_calloc, NULL },
    { "free", (void *)hook_free, NULL },
    { "malloc_size", (void *)hook_malloc_size, NULL },
    { "posix_memalign", (void *)hook_posix_memalign, NULL },
    { "aligned_alloc", (void *)hook_aligned_alloc, NULL },
    { "valloc", (void *)hook_valloc, NULL },
    { "realloc", (void *)hook_realloc, NULL },
    { "reallocf", (void *)hook_reallocf, NULL },
};

#pragma mark - Libraries

// A library's references to stdin, stdout and stderr are libc's own, which
// use the app's descriptors; its calls are given the program's FILEs instead.
static FILE *guest_file(uintptr_t caller, FILE *file) {
    int fd = file == stdin ? 0 : file == stdout ? 1 : file == stderr ? 2 : -1;
    return fd < 0 ? file : guest_stdio(caller, fd);
}

static char *hook_fgets(char *buffer, int size, FILE *file) { return fgets(buffer, size, guest_file(CALLER, file)); }
static int hook_fgetc(FILE *file) { return fgetc(guest_file(CALLER, file)); }
static int hook_getc(FILE *file) { return getc(guest_file(CALLER, file)); }
static int hook_ungetc(int c, FILE *file) { return ungetc(c, guest_file(CALLER, file)); }
static size_t hook_fread(void *buffer, size_t size, size_t count, FILE *file) { return fread(buffer, size, count, guest_file(CALLER, file)); }
static size_t hook_fwrite(const void *buffer, size_t size, size_t count, FILE *file) { return fwrite(buffer, size, count, guest_file(CALLER, file)); }
static int hook_fputs(const char *string, FILE *file) { return fputs(string, guest_file(CALLER, file)); }
static int hook_fputc(int c, FILE *file) { return fputc(c, guest_file(CALLER, file)); }
static int hook_putc(int c, FILE *file) { return putc(c, guest_file(CALLER, file)); }
static int hook_vfprintf(FILE *file, const char *format, va_list args) { return vfprintf(guest_file(CALLER, file), format, args); }
static int hook_vfscanf(FILE *file, const char *format, va_list args) { return vfscanf(guest_file(CALLER, file), format, args); }
static int hook_fflush(FILE *file) { return fflush(file ? guest_file(CALLER, file) : NULL); }
static ssize_t hook_getline(char **line, size_t *capacity, FILE *file) { return getline(line, capacity, guest_file(CALLER, file)); }
static ssize_t hook_getdelim(char **line, size_t *capacity, int delimiter, FILE *file) { return getdelim(line, capacity, delimiter, guest_file(CALLER, file)); }
static int hook_feof(FILE *file) { return feof(guest_file(CALLER, file)); }
static int hook_ferror(FILE *file) { return ferror(guest_file(CALLER, file)); }
static void hook_clearerr(FILE *file) { clearerr(guest_file(CALLER, file)); }
static int hook_setvbuf(FILE *file, char *buffer, int mode, size_t size) { return setvbuf(guest_file(CALLER, file), buffer, mode, size); }

static int hook_fprintf(FILE *file, const char *format, ...) {
    FILE *own = guest_file(CALLER, file);
    va_list args;
    va_start(args, format);
    int result = vfprintf(own, format, args);
    va_end(args);
    return result;
}

static int hook_fscanf(FILE *file, const char *format, ...) {
    FILE *own = guest_file(CALLER, file);
    va_list args;
    va_start(args, format);
    int result = vfscanf(own, format, args);
    va_end(args);
    return result;
}

static struct rebinding guest_library_hooks[] = {
    { "fgets", (void *)hook_fgets, NULL },
    { "fgetc", (void *)hook_fgetc, NULL },
    { "getc", (void *)hook_getc, NULL },
    { "ungetc", (void *)hook_ungetc, NULL },
    { "fread", (void *)hook_fread, NULL },
    { "fwrite", (void *)hook_fwrite, NULL },
    { "fputs", (void *)hook_fputs, NULL },
    { "fputc", (void *)hook_fputc, NULL },
    { "putc", (void *)hook_putc, NULL },
    { "fprintf", (void *)hook_fprintf, NULL },
    { "vfprintf", (void *)hook_vfprintf, NULL },
    { "fscanf", (void *)hook_fscanf, NULL },
    { "vfscanf", (void *)hook_vfscanf, NULL },
    { "fflush", (void *)hook_fflush, NULL },
    { "getline", (void *)hook_getline, NULL },
    { "getdelim", (void *)hook_getdelim, NULL },
    { "feof", (void *)hook_feof, NULL },
    { "ferror", (void *)hook_ferror, NULL },
    { "clearerr", (void *)hook_clearerr, NULL },
    { "setvbuf", (void *)hook_setvbuf, NULL },
};

/// Points an image of the program's own (its copy, and libraries cloned for
/// it) at its allocator and its environ, stdin, stdout and stderr.
static BOOL guest_hook_own_variables(guest_process *g, const struct mach_header_64 *header, intptr_t slide) {
    struct rebinding variables[] = {
        { "environ", (void *)&g->environ, NULL },
        { "__stdinp", (void *)&g->stdio[0], NULL },
        { "__stdoutp", (void *)&g->stdio[1], NULL },
        { "__stderrp", (void *)&g->stdio[2], NULL },
    };
    return rebind_symbols_image((void *)header, slide, guest_heap_hooks, GUEST_COUNT(guest_heap_hooks)) == 0 &&
           rebind_symbols_image((void *)header, slide, variables, GUEST_COUNT(variables)) == 0;
}

/// The directory holding a program's copy and the libraries cloned for it,
/// with a trailing slash, if `path` is in one (see Execute.instantiate).
static BOOL instance_directory(const char *path, char directory[PATH_MAX]) {
    static const char container[] = "/GuestInstances/";
    const char *found = strstr(path, container);
    if (!found) return NO;
    const char *slash = strchr(found + sizeof(container) - 1, '/');
    if (!slash) return NO;
    size_t length = (size_t)(slash - path) + 1;
    if (length >= PATH_MAX) return NO;
    memcpy(directory, path, length);
    directory[length] = '\0';
    return YES;
}

/// `path` without a leading "/private": on a device the container is
/// /var/mobile/..., which dyld reports as /private/var/mobile/...
static const char *without_private(const char *path) {
    return strncmp(path, "/private/", 9) == 0 ? path + 8 : path;
}

/// Installs the hooks into the patched libraries programs have loaded (they
/// live in the app's container, unlike the system's), each once. The ones
/// cloned for `owner` are its own and are hooked as its image is; others are
/// shared, and their calls act for the program whose thread makes them.
static void guest_hook_libraries(guest_process *owner) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static char **hooked;
    static int hookedCount, hookedCapacity;
    static char home[PATH_MAX];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        strlcpy(home, without_private(NSHomeDirectory().fileSystemRepresentation), sizeof(home));
        strlcat(home, "/", sizeof(home));
    });
    size_t homeLength = strlen(home);

    char ownDirectory[PATH_MAX] = "";
    os_unfair_lock_lock(&guest_lock);
    if (owner && owner->used) instance_directory(without_private(owner->instancePath), ownDirectory);
    os_unfair_lock_unlock(&guest_lock);
    size_t ownLength = strlen(ownDirectory);

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *fullName = _dyld_get_image_name(i);
        if (!fullName) continue;
        const char *name = without_private(fullName);
        if (strncmp(name, home, homeLength) != 0) continue;
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        BOOL program = NO;
        os_unfair_lock_lock(&guest_lock);
        for (int j = 0; j < GUEST_MAX && !program; j++) {
            program = guests[j].used && guests[j].header == header;
        }
        os_unfair_lock_unlock(&guest_lock);
        if (program) continue;
        BOOL own = ownLength && strncmp(name, ownDirectory, ownLength) == 0;
        char directory[PATH_MAX];
        // Another program's own libraries; it hooks them.
        if (!own && instance_directory(name, directory)) continue;

        os_unfair_lock_lock(&lock);
        BOOL done = NO;
        for (int j = 0; j < hookedCount && !done; j++) done = strcmp(hooked[j], name) == 0;
        if (!done && grow((void **)&hooked, &hookedCapacity, hookedCount, sizeof(char *))) {
            hooked[hookedCount++] = strdup(name);
        }
        os_unfair_lock_unlock(&lock);
        if (done) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        rebind_symbols_image((void *)header, slide, guest_function_hooks, GUEST_COUNT(guest_function_hooks));
        if (own) {
            guest_hook_own_variables(owner, header, slide);
        } else {
            rebind_symbols_image((void *)header, slide, guest_library_hooks, GUEST_COUNT(guest_library_hooks));
        }
    }
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
            g->header = header;
            g->slide = slide;
            g->handle = handle;
            if (instancePath) strlcpy(g->instancePath, instancePath, sizeof(g->instancePath));
            guest_open_stdio_locked(g);
        }
        os_unfair_lock_unlock(&guest_lock);
        if (!g) return NO;

        // A program that forks but never starts a thread, like a shell, may
        // run its own code in the child, which must not change the parent's
        // memory.
        static const char *const forks[] = { "fork", "vfork" };
        static const char *const threads[] = { "pthread_create" };
        if (image_imports(header, slide, forks, 2) && !image_imports(header, slide, threads, 1)) {
            guest_heap *heap = guest_heap_create();
            os_unfair_lock_lock(&guest_lock);
            if (!g->heap) {
                g->heap = heap;
                heap = NULL;
            }
            os_unfair_lock_unlock(&guest_lock);
            if (heap) guest_heap_destroy(heap);
        }

        BOOL hooked = rebind_symbols_image((void *)header, slide, guest_function_hooks, GUEST_COUNT(guest_function_hooks)) == 0 &&
                      guest_hook_own_variables(g, header, slide);
        guest_hook_libraries(g);
        return hooked;
    }
    return NO;
}
