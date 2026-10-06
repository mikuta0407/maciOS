// Minimal lockf(1): `lockf [-knsw] [-t seconds] file|fd [command ...]`.
// With a file descriptor number and no command, locks that descriptor and
// exits, leaving the lock with whoever shares it (as Homebrew uses it).
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>

#define EX_USAGE 64
#define EX_CANTCREAT 73
#define EX_OSERR 71
#define EX_TEMPFAIL 75

static int acquire(int fd, int mode, long timeout) {
    if (timeout < 0) return flock(fd, mode);
    for (long waited = 0;; waited++) {
        if (flock(fd, mode | LOCK_NB) == 0) return 0;
        if (errno != EWOULDBLOCK || waited >= timeout) return -1;
        sleep(1);
    }
}

int main(int argc, char **argv) {
    int keep = 0, create = 1, mode = LOCK_EX, ch;
    long timeout = -1;
    while ((ch = getopt(argc, argv, "+knswt:")) != -1) {
        switch (ch) {
        case 'k': keep = 1; break;
        case 'n': create = 0; break;
        case 's': mode = LOCK_SH; break;
        case 'w': break;
        case 't': timeout = strtol(optarg, NULL, 10); break;
        default: return EX_USAGE;
        }
    }
    argc -= optind; argv += optind;
    if (argc < 1) {
        fprintf(stderr, "usage: lockf [-knsw] [-t seconds] file|fd [command ...]\n");
        return EX_USAGE;
    }

    char *end;
    long number = strtol(argv[0], &end, 10);
    if (argc == 1 && *end == '\0') {
        if (acquire((int)number, mode, timeout) == 0) return 0;
        if (errno == EWOULDBLOCK) return EX_TEMPFAIL;
        perror("lockf");
        return EX_OSERR;
    }

    int fd = open(argv[0], O_RDONLY | (create ? O_CREAT : 0), 0666);
    if (fd < 0) { perror(argv[0]); return EX_CANTCREAT; }
    if (acquire(fd, mode, timeout) != 0) {
        if (errno == EWOULDBLOCK) { fprintf(stderr, "lockf: %s: already locked\n", argv[0]); return EX_TEMPFAIL; }
        perror("lockf");
        return EX_OSERR;
    }
    if (argc == 1) return 0;

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return EX_OSERR; }
    if (pid == 0) {
        close(fd);
        execvp(argv[1], argv + 1);
        perror(argv[1]);
        _exit(127);
    }
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (!keep) unlink(argv[0]);
    close(fd);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
