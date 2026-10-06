//
//  VirtualTTY.m
//  maciOS
//

#import "VirtualTTY.h"
#include <stdatomic.h>
#import "../JIT/ellekit/fishhook/fishhook.h"

#include <fcntl.h>
#include <os/lock.h>
#include <signal.h>
#include <stdarg.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

#define VTTY_MAX_FDS 8
#define VTTY_LINE_MAX 4096

typedef struct {
    dev_t dev;
    ino_t ino;
} vtty_identity;

static os_unfair_lock vtty_lock = OS_UNFAIR_LOCK_INIT;
static struct termios vtty_termios;
static struct winsize vtty_winsize = { .ws_row = 24, .ws_col = 80 };
static vtty_identity vtty_identities[VTTY_MAX_FDS];
static int vtty_identity_count = 0;
static int vtty_input_fd = -1;
static uint8_t vtty_line[VTTY_LINE_MAX];
static size_t vtty_line_length = 0;
static VTTYOutputHandler vtty_echo_handler = nil;

static int (*orig_isatty)(int);
static int (*orig_tcgetattr)(int, struct termios *);
static int (*orig_tcsetattr)(int, int, const struct termios *);
static pid_t (*orig_tcgetpgrp)(int);
static int (*orig_tcsetpgrp)(int, pid_t);
static int (*orig_ioctl)(int, unsigned long, ...);
static int (*orig_open)(const char *, int, ...);
static char *(*orig_ttyname)(int);

#pragma mark - State

static void vtty_reset_termios(struct termios *t) {
    memset(t, 0, sizeof(*t));
    t->c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT | IUTF8;
    t->c_oflag = OPOST | ONLCR;
    t->c_cflag = CREAD | CS8 | HUPCL;
    t->c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL;
    for (int i = 0; i < NCCS; i++) t->c_cc[i] = _POSIX_VDISABLE;
    t->c_cc[VEOF] = 0x04;      // ^D
    t->c_cc[VERASE] = 0x7f;    // DEL
    t->c_cc[VWERASE] = 0x17;   // ^W
    t->c_cc[VKILL] = 0x15;     // ^U
    t->c_cc[VREPRINT] = 0x12;  // ^R
    t->c_cc[VINTR] = 0x03;     // ^C
    t->c_cc[VQUIT] = 0x1c;     // ^\ (backslash)
    t->c_cc[VSUSP] = 0x1a;     // ^Z
    t->c_cc[VDSUSP] = 0x19;    // ^Y
    t->c_cc[VSTART] = 0x11;    // ^Q
    t->c_cc[VSTOP] = 0x13;     // ^S
    t->c_cc[VLNEXT] = 0x16;    // ^V
    t->c_cc[VDISCARD] = 0x0f;  // ^O
    t->c_cc[VSTATUS] = 0x14;   // ^T
    t->c_cc[VMIN] = 1;
    t->c_cc[VTIME] = 0;
    cfsetispeed(t, B38400);
    cfsetospeed(t, B38400);
}

__attribute__((constructor))
static void vtty_init(void) {
    vtty_reset_termios(&vtty_termios);
}

static void vtty_add_identity(int fd) {
    struct stat st;
    if (fstat(fd, &st) != 0) return;
    os_unfair_lock_lock(&vtty_lock);
    for (int i = 0; i < vtty_identity_count; i++) {
        if (vtty_identities[i].dev == st.st_dev && vtty_identities[i].ino == st.st_ino) {
            os_unfair_lock_unlock(&vtty_lock);
            return;
        }
    }
    if (vtty_identity_count < VTTY_MAX_FDS) {
        vtty_identities[vtty_identity_count++] = (vtty_identity){ st.st_dev, st.st_ino };
    }
    os_unfair_lock_unlock(&vtty_lock);
}

static void vtty_replace_identity(dev_t oldDev, ino_t oldIno, int fd) {
    struct stat st;
    if (fstat(fd, &st) != 0) return;
    os_unfair_lock_lock(&vtty_lock);
    for (int i = 0; i < vtty_identity_count; i++) {
        if (vtty_identities[i].dev == oldDev && vtty_identities[i].ino == oldIno) {
            vtty_identities[i] = (vtty_identity){ st.st_dev, st.st_ino };
            break;
        }
    }
    os_unfair_lock_unlock(&vtty_lock);
}

static BOOL vtty_is_tty_fd(int fd) {
    if (fd < 0) return NO;
    struct stat st;
    if (fstat(fd, &st) != 0) return NO;
    BOOL found = NO;
    os_unfair_lock_lock(&vtty_lock);
    for (int i = 0; i < vtty_identity_count; i++) {
        if (vtty_identities[i].dev == st.st_dev && vtty_identities[i].ino == st.st_ino) {
            found = YES;
            break;
        }
    }
    os_unfair_lock_unlock(&vtty_lock);
    return found;
}

void vtty_attach_stdin(void) {
    int fds[2];
    if (pipe(fds) != 0) return;
    dup2(fds[0], STDIN_FILENO);
    close(fds[0]);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    vtty_input_fd = fds[1];
    vtty_add_identity(STDIN_FILENO);
}

void vtty_register_output_fd(int fd) {
    vtty_add_identity(fd);
}

void vtty_set_echo_handler(VTTYOutputHandler handler) {
    vtty_echo_handler = [handler copy];
}

void vtty_set_window_size(unsigned short rows, unsigned short cols) {
    os_unfair_lock_lock(&vtty_lock);
    BOOL changed = vtty_winsize.ws_row != rows || vtty_winsize.ws_col != cols;
    vtty_winsize.ws_row = rows;
    vtty_winsize.ws_col = cols;
    os_unfair_lock_unlock(&vtty_lock);
    if (changed) {
        // SIGWINCH is ignored by default, so this only reaches guests that asked for it.
        kill(getpid(), SIGWINCH);
    }
}

#pragma mark - Output processing

static NSData *vtty_post_process(const uint8_t *bytes, size_t length, struct termios *t) {
    if (!(t->c_oflag & OPOST) || !(t->c_oflag & ONLCR)) {
        return [NSData dataWithBytes:bytes length:length];
    }
    NSMutableData *out = [NSMutableData dataWithCapacity:length + 16];
    size_t start = 0;
    for (size_t i = 0; i < length; i++) {
        if (bytes[i] == '\n') {
            [out appendBytes:bytes + start length:i - start];
            [out appendBytes:"\r\n" length:2];
            start = i + 1;
        }
    }
    [out appendBytes:bytes + start length:length - start];
    return out;
}

NSData *vtty_process_output(NSData *data) {
    os_unfair_lock_lock(&vtty_lock);
    struct termios t = vtty_termios;
    os_unfair_lock_unlock(&vtty_lock);
    return vtty_post_process(data.bytes, data.length, &t);
}

#pragma mark - Line discipline

static void vtty_echo(const void *bytes, size_t length, struct termios *t) {
    if (!vtty_echo_handler || length == 0) return;
    vtty_echo_handler(vtty_post_process(bytes, length, t));
}

static void vtty_echo_char(uint8_t c, struct termios *t) {
    if ((t->c_lflag & ECHOCTL) && c < 0x20 && c != '\n' && c != '\t') {
        uint8_t caret[2] = { '^', (uint8_t)(c + '@') };
        vtty_echo(caret, 2, t);
    } else if ((t->c_lflag & ECHOCTL) && c == 0x7f) {
        vtty_echo("^?", 2, t);
    } else {
        vtty_echo(&c, 1, t);
    }
}

static void vtty_deliver(const uint8_t *bytes, size_t length) {
    size_t written = 0;
    while (written < length && vtty_input_fd >= 0) {
        ssize_t n = write(vtty_input_fd, bytes + written, length - written);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        written += (size_t)n;
    }
}

// A tty read returns 0 on ^D at the start of a line. A pipe cannot do that
// without closing its write end, so stdin is swapped for a fresh pipe and the
// old write end is closed: a guest blocked in read() on the old pipe gets EOF,
// and later reads use the new one.
static void vtty_deliver_eof(void) {
    int fds[2];
    if (pipe(fds) != 0) return;
    struct stat oldStat;
    BOOL hadStdin = fstat(STDIN_FILENO, &oldStat) == 0;
    dup2(fds[0], STDIN_FILENO);
    close(fds[0]);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    int oldInput = vtty_input_fd;
    vtty_input_fd = fds[1];
    if (hadStdin) {
        vtty_replace_identity(oldStat.st_dev, oldStat.st_ino, STDIN_FILENO);
    } else {
        vtty_add_identity(STDIN_FILENO);
    }
    if (oldInput >= 0) close(oldInput);
}

static void vtty_raise(int sig) {
    struct sigaction current;
    if (sigaction(sig, NULL, &current) != 0) return;
    // Everything runs in one process, so a default action would take the
    // whole app down. Only deliver signals the guest installed a handler for.
    if (current.sa_handler == SIG_DFL || current.sa_handler == SIG_IGN) return;
    kill(getpid(), sig);
}

static void vtty_erase_last_char(struct termios *t) {
    if (vtty_line_length == 0) return;
    // Step back over UTF-8 continuation bytes so a multibyte character is erased as one.
    do {
        vtty_line_length--;
    } while (vtty_line_length > 0 && (vtty_line[vtty_line_length] & 0xC0) == 0x80);
    if ((t->c_lflag & ECHO) && (t->c_lflag & ECHOE)) {
        uint8_t removed = vtty_line[vtty_line_length];
        int columns = (removed < 0x20 && (t->c_lflag & ECHOCTL)) ? 2 : 1;
        for (int i = 0; i < columns; i++) vtty_echo("\b \b", 3, t);
    }
}

void vtty_receive_input(const uint8_t *bytes, size_t length) {
    os_unfair_lock_lock(&vtty_lock);
    struct termios t = vtty_termios;
    os_unfair_lock_unlock(&vtty_lock);

    BOOL canonical = (t.c_lflag & ICANON) != 0;
    NSMutableData *raw = canonical ? nil : [NSMutableData dataWithCapacity:length];

    for (size_t i = 0; i < length; i++) {
        uint8_t c = bytes[i];

        if (c == '\r') {
            if (t.c_iflag & IGNCR) continue;
            if (t.c_iflag & ICRNL) c = '\n';
        } else if (c == '\n' && (t.c_iflag & INLCR)) {
            c = '\r';
        }

        if (t.c_lflag & ISIG) {
            int sig = 0;
            if (c == t.c_cc[VINTR]) sig = SIGINT;
            else if (c == t.c_cc[VQUIT]) sig = SIGQUIT;
            else if (c == t.c_cc[VSUSP]) sig = SIGTSTP;
            if (sig != 0 && c != _POSIX_VDISABLE) {
                if (t.c_lflag & ECHO) vtty_echo_char(c, &t);
                if (!(t.c_lflag & NOFLSH)) vtty_line_length = 0;
                if (raw.length > 0) {
                    vtty_deliver(raw.bytes, raw.length);
                    raw.length = 0;
                }
                vtty_raise(sig);
                continue;
            }
        }

        if (!canonical) {
            [raw appendBytes:&c length:1];
            if (t.c_lflag & ECHO) vtty_echo_char(c, &t);
            continue;
        }

        if (c == t.c_cc[VERASE] || c == 0x08) {
            vtty_erase_last_char(&t);
        } else if (c == t.c_cc[VWERASE] && (t.c_lflag & IEXTEN)) {
            while (vtty_line_length > 0 && vtty_line[vtty_line_length - 1] == ' ') vtty_erase_last_char(&t);
            while (vtty_line_length > 0 && vtty_line[vtty_line_length - 1] != ' ') vtty_erase_last_char(&t);
        } else if (c == t.c_cc[VKILL]) {
            while (vtty_line_length > 0) vtty_erase_last_char(&t);
        } else if (c == t.c_cc[VEOF]) {
            if (vtty_line_length > 0) {
                vtty_deliver(vtty_line, vtty_line_length);
                vtty_line_length = 0;
            } else {
                vtty_deliver_eof();
            }
        } else {
            if (vtty_line_length < VTTY_LINE_MAX) vtty_line[vtty_line_length++] = c;
            if ((t.c_lflag & ECHO) || (c == '\n' && (t.c_lflag & ECHONL))) vtty_echo_char(c, &t);
            if (c == '\n' || (c == t.c_cc[VEOL] && c != _POSIX_VDISABLE) || (c == t.c_cc[VEOL2] && c != _POSIX_VDISABLE)) {
                vtty_deliver(vtty_line, vtty_line_length);
                vtty_line_length = 0;
            }
        }
    }

    if (raw.length > 0) {
        vtty_deliver(raw.bytes, raw.length);
    }
}

#pragma mark - Hooks

static int vtty_get_termios(struct termios *t) {
    if (!t) { errno = EFAULT; return -1; }
    os_unfair_lock_lock(&vtty_lock);
    *t = vtty_termios;
    os_unfair_lock_unlock(&vtty_lock);
    return 0;
}

static int vtty_set_termios(int action, const struct termios *t) {
    if (!t) { errno = EFAULT; return -1; }
    os_unfair_lock_lock(&vtty_lock);
    BOOL leavingCanonical = (vtty_termios.c_lflag & ICANON) && !(t->c_lflag & ICANON);
    vtty_termios = *t;
    os_unfair_lock_unlock(&vtty_lock);
    if (action == TCSAFLUSH) {
        vtty_line_length = 0;
    } else if (leavingCanonical && vtty_line_length > 0) {
        // Pending input stays readable once the guest switches to raw mode.
        vtty_deliver(vtty_line, vtty_line_length);
        vtty_line_length = 0;
    }
    return 0;
}

static int hook_isatty(int fd) {
    if (vtty_is_tty_fd(fd)) return 1;
    return orig_isatty(fd);
}

static int hook_tcgetattr(int fd, struct termios *t) {
    if (vtty_is_tty_fd(fd)) return vtty_get_termios(t);
    return orig_tcgetattr(fd, t);
}

static int hook_tcsetattr(int fd, int action, const struct termios *t) {
    if (vtty_is_tty_fd(fd)) return vtty_set_termios(action & ~TCSASOFT, t);
    return orig_tcsetattr(fd, action, t);
}

// The terminal's foreground process group, as a shell with job control set
// it. Guests have no real process groups, so it is only remembered.
static _Atomic pid_t vtty_foreground_pgrp;

static pid_t hook_tcgetpgrp(int fd) {
    if (vtty_is_tty_fd(fd)) {
        pid_t pgrp = vtty_foreground_pgrp;
        return pgrp ? pgrp : getpgrp();
    }
    return orig_tcgetpgrp(fd);
}

static int hook_tcsetpgrp(int fd, pid_t pgrp) {
    if (vtty_is_tty_fd(fd)) {
        vtty_foreground_pgrp = pgrp;
        return 0;
    }
    return orig_tcsetpgrp(fd, pgrp);
}

static int hook_ioctl(int fd, unsigned long request, ...) {
    va_list args;
    va_start(args, request);
    void *argp = va_arg(args, void *);
    va_end(args);

    if (vtty_is_tty_fd(fd)) {
        switch (request) {
            case TIOCGWINSZ:
                if (!argp) { errno = EFAULT; return -1; }
                os_unfair_lock_lock(&vtty_lock);
                memcpy(argp, &vtty_winsize, sizeof(vtty_winsize));
                os_unfair_lock_unlock(&vtty_lock);
                return 0;
            case TIOCSWINSZ:
                if (!argp) { errno = EFAULT; return -1; }
                os_unfair_lock_lock(&vtty_lock);
                memcpy(&vtty_winsize, argp, sizeof(vtty_winsize));
                os_unfair_lock_unlock(&vtty_lock);
                return 0;
            case TIOCGETA:
                return vtty_get_termios(argp);
            case TIOCSETA:
                return vtty_set_termios(TCSANOW, argp);
            case TIOCSETAW:
                return vtty_set_termios(TCSADRAIN, argp);
            case TIOCSETAF:
                return vtty_set_termios(TCSAFLUSH, argp);
            case TIOCGPGRP:
                if (!argp) { errno = EFAULT; return -1; }
                *(pid_t *)argp = getpgrp();
                return 0;
            case TIOCSPGRP:
            case TIOCSCTTY:
            case TIOCNOTTY:
            case TIOCEXCL:
            case TIOCNXCL:
            case TIOCFLUSH:
            case TIOCSTART:
            case TIOCSTOP:
                return 0;
            default:
                break; // FIONREAD, FIONBIO, FIOCLEX, ... work on the underlying pipe.
        }
    }
    return orig_ioctl(fd, request, argp);
}

static int hook_open(const char *path, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, int);
        va_end(args);
    }
    if (path && strcmp(path, "/dev/tty") == 0) {
        // Reads come from the terminal's input; write-only opens go to stdout.
        int source = ((flags & O_ACCMODE) == O_WRONLY) ? STDOUT_FILENO : STDIN_FILENO;
        int fd = (flags & O_CLOEXEC) ? fcntl(source, F_DUPFD_CLOEXEC, 0) : dup(source);
        if (fd >= 0) return fd;
    }
    return orig_open(path, flags, mode);
}

static char *hook_ttyname(int fd) {
    if (vtty_is_tty_fd(fd)) return "/dev/ttys000";
    return orig_ttyname(fd);
}

void vtty_install_hooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct rebinding rebindings[] = {
            { "isatty", (void *)hook_isatty, (void **)&orig_isatty },
            { "tcgetattr", (void *)hook_tcgetattr, (void **)&orig_tcgetattr },
            { "tcsetattr", (void *)hook_tcsetattr, (void **)&orig_tcsetattr },
            { "tcgetpgrp", (void *)hook_tcgetpgrp, (void **)&orig_tcgetpgrp },
            { "tcsetpgrp", (void *)hook_tcsetpgrp, (void **)&orig_tcsetpgrp },
            { "ioctl", (void *)hook_ioctl, (void **)&orig_ioctl },
            { "open", (void *)hook_open, (void **)&orig_open },
            { "ttyname", (void *)hook_ttyname, (void **)&orig_ttyname },
        };
        int result = rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
        NSLog(@"VirtualTTY hooks installed: %d", result);
    });
}
