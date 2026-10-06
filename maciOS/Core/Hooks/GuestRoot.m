//
//  GuestRoot.m
//  maciOS
//

#import "GuestRoot.h"

#include <string.h>
#include <sys/stat.h>

static char guest_root[PATH_MAX];
static size_t guest_root_length;

static const char *const mapped_prefixes[] = { "/bin", "/sbin", "/usr", "/etc", "/private/etc" };
// Directories of programs, which come only from the root: the system's own
// cannot be run as guests, and in the simulator they are the Mac's.
static const char *const opaque_prefixes[] = { "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/libexec" };

static BOOL has_prefix(const char *path, const char *prefix) {
    size_t length = strlen(prefix);
    return strncmp(path, prefix, length) == 0 && (path[length] == '\0' || path[length] == '/');
}

void guest_root_set(const char *path) {
    strlcpy(guest_root, path, sizeof(guest_root));
    guest_root_length = strlen(guest_root);
    while (guest_root_length > 1 && guest_root[guest_root_length - 1] == '/') {
        guest_root[--guest_root_length] = '\0';
    }
}

const char *guest_root_map(const char *path, char buffer[PATH_MAX]) {
    if (!path || path[0] != '/' || guest_root_length == 0) return path;
    if (strncmp(path, guest_root, guest_root_length) == 0) return path;

    BOOL eligible = NO, opaque = NO;
    for (size_t i = 0; i < sizeof(mapped_prefixes) / sizeof(mapped_prefixes[0]); i++) {
        if (has_prefix(path, mapped_prefixes[i])) eligible = YES;
    }
    for (size_t i = 0; i < sizeof(opaque_prefixes) / sizeof(opaque_prefixes[0]); i++) {
        if (has_prefix(path, opaque_prefixes[i])) opaque = YES;
    }
    if (!eligible) return path;

    if (snprintf(buffer, PATH_MAX, "%s%s", guest_root, path) >= PATH_MAX) return path;
    struct stat st;
    return opaque || lstat(buffer, &st) == 0 ? buffer : path;
}
