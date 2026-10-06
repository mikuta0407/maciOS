//
//  GuestSpawn.h
//  maciOS
//
//  Child processes for guest programs. iOS cannot fork, so fork() is
//  emulated vfork-style on the calling thread, execve() starts the target
//  as another guest image in this process, and wait4()/kill() work on the
//  pids handed out here. Each guest can have its own stdin/stdout/stderr.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Loads and starts the program at `path` as the guest `pid`. Returns 0 once
/// its entry point is running, or an errno value. Called on a private queue.
typedef int (*guest_launcher_t)(const char *path, char * _Nullable const * _Nonnull argv, char * _Nullable const * _Nonnull envp, pid_t pid);

void guest_set_launcher(guest_launcher_t launcher);

/// Allocates a pid for a program started from the terminal; it uses the
/// app's own stdin/stdout/stderr.
pid_t guest_register_toplevel(void);

/// Installs the process hooks into the image loaded from `imagePath` and
/// associates it with `pid`. When the program exits, `handle` (from dlopen)
/// is closed and `instancePath`, if given, is deleted.
BOOL guest_attach_image(pid_t pid, const char *imagePath, void *handle, const char * _Nullable instancePath);

/// Counts the calling thread, which runs the program's entry point, as one
/// of the program's threads.
void guest_adopt_current_thread(pid_t pid);

/// Records that the program's entry point returned `status`.
void guest_entry_returned(pid_t pid, int status);

NS_ASSUME_NONNULL_END
