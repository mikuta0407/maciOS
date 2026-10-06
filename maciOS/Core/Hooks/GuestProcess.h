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

NS_ASSUME_NONNULL_END
