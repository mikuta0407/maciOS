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

/// Makes the library at `path`, which a guest program dlopen()s, loadable:
/// writes the path of a patched copy to `loadable` and returns YES, or returns
/// NO when `path` should be opened as it is. `programImage` is the loaded
/// copy of the program and `executablePath` its original file.
typedef BOOL (*guest_library_loader_t)(const char *path, const char *programImage, const char *executablePath, char loadable[_Nonnull PATH_MAX]);

void guest_set_library_loader(guest_library_loader_t loader);

/// Allocates a pid for a program started from the terminal; it uses the
/// app's own stdin/stdout/stderr.
pid_t guest_register_toplevel(void);

/// Called when a program started from the terminal exits, with its wait
/// status. It runs with the process table locked, so it must only hand the
/// news on (dispatch_async).
typedef void (*guest_exit_observer_t)(pid_t pid, int waitStatus);

void guest_set_toplevel_exit_observer(guest_exit_observer_t observer);

/// Installs the process hooks into the image loaded from `imagePath` and
/// associates it with `pid`. When the program exits, `handle` (from dlopen)
/// is closed and `instancePath`, if given, is deleted.
BOOL guest_attach_image(pid_t pid, const char *imagePath, void *handle, const char * _Nullable instancePath);

/// What the program `pid` sees as its arguments (_NSGetArgv), environment
/// (environ, getenv) and executable path. The arrays must stay valid while
/// it runs.
void guest_set_process_info(pid_t pid, int argc, char * _Nullable * _Nonnull argv, char * _Nullable * _Nonnull envp, const char *executablePath);

/// Counts the calling thread, which runs the program's entry point, as one
/// of the program's threads.
void guest_adopt_current_thread(pid_t pid);

/// Records that the program's entry point returned `status`.
void guest_entry_returned(pid_t pid, int status);

NS_ASSUME_NONNULL_END
