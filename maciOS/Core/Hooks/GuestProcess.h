//
//  GuestProcess.h
//  maciOS
//
//  Per-program process state that libc normally takes from the process
//  itself (argv, executable path), redirected for a loaded guest image.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Records the app's signal dispositions before a guest starts. Runtimes such
/// as Go install process-wide handlers that must not outlive the program.
void guest_save_signal_handlers(void);

/// Restores the dispositions recorded by guest_save_signal_handlers().
void guest_restore_signal_handlers(void);

/// Ends the guest that runs the calling thread with `waitStatus`, for exit()
/// and abort() reached through the app's own hooks: from libraries that are
/// not hooked per guest, such as the system's ncurses. Returns when the
/// thread runs no guest.
void guest_end_calling_thread(int waitStatus);

NS_ASSUME_NONNULL_END
