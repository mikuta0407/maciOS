//
//  VirtualTTY.h
//  maciOS
//
//  Emulates a terminal device on top of the pipes that guest programs use as
//  stdin/stdout/stderr: termios state, a line discipline, the window size and
//  the libc calls that query them.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^VTTYOutputHandler)(NSData *data);

/// Creates the stdin pipe, installs its read end as STDIN_FILENO and keeps the
/// write end for the line discipline.
void vtty_attach_stdin(void);

/// Marks the pipes behind stdout/stderr as part of the terminal so that
/// isatty()/ioctl() on them (or on dups of them) behave like a tty.
void vtty_register_output_fd(int fd);

/// Called with bytes that should appear on the terminal as a result of input (echo).
void vtty_set_echo_handler(VTTYOutputHandler handler);

/// Installs the libc hooks (isatty, tcgetattr, tcsetattr, ioctl, open, ...).
void vtty_install_hooks(void);

/// Feeds keyboard input from the terminal view through the line discipline.
void vtty_receive_input(const uint8_t *bytes, size_t length);

/// Applies output post-processing (OPOST/ONLCR) to bytes the guest wrote.
NSData *vtty_process_output(NSData *data);

/// Updates the window size reported by TIOCGWINSZ and raises SIGWINCH.
void vtty_set_window_size(unsigned short rows, unsigned short cols);

NS_ASSUME_NONNULL_END
