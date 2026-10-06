//
//  GuestProcess.h
//  maciOS
//
//  Per-program process state that libc normally takes from the process
//  itself (argv, executable path), redirected for a loaded guest image.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Makes the guest image at `imagePath` see `argv` from _NSGetArgc/_NSGetArgv
/// and `executablePath` from _NSGetExecutablePath. `argv` must stay alive
/// (and be NULL-terminated) for as long as the guest runs.
BOOL guest_bind_process_info(const char *imagePath, int argc, char * _Nullable * _Nonnull argv, const char *executablePath);

/// Records the app's signal dispositions before a guest starts. Runtimes such
/// as Go install process-wide handlers that must not outlive the program.
void guest_save_signal_handlers(void);

/// Restores the dispositions recorded by guest_save_signal_handlers().
void guest_restore_signal_handlers(void);

NS_ASSUME_NONNULL_END
