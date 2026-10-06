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

/// A path into an earlier location of the app's data container, which moves
/// when the app is reinstalled or updated (Homebrew writes absolute paths into
/// what it installs): the same path in the current container, or NULL.
static const char *current_container_path(const char *path, char buffer[PATH_MAX]) {
    static const char marker[] = "/Containers/Data/Application/";
    static char home[PATH_MAX];
    static size_t homeLength;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        strlcpy(home, NSHomeDirectory().fileSystemRepresentation, sizeof(home));
        homeLength = strlen(home);
    });
    const char *found = strstr(path, marker);
    if (!found || homeLength == 0) return NULL;
    const char *rest = strchr(found + sizeof(marker) - 1, '/');
    if (!rest) return NULL;
    size_t containerLength = (size_t)(rest - path);
    if (containerLength == homeLength && strncmp(path, home, homeLength) == 0) return NULL;
    if (snprintf(buffer, PATH_MAX, "%s%s", home, rest) >= PATH_MAX) return NULL;
    return buffer;
}

const char *guest_root_map(const char *path, char buffer[PATH_MAX]) {
    if (!path || path[0] != '/') return path;
    const char *moved = current_container_path(path, buffer);
    if (moved) return moved;
    if (guest_root_length == 0) return path;
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
