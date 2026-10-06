//
//  GuestProcess.m
//  maciOS
//

#import "GuestProcess.h"
#import "../JIT/ellekit/fishhook/fishhook.h"

#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>

// Guests run inside the app's process, so these describe the most recently
// started guest. Programs read them once at startup, which is enough for one
// foreground program at a time.
static int guest_argc;
static char **guest_argv;
static char guest_executable_path[PATH_MAX];

static int *hook_NSGetArgc(void) {
    return &guest_argc;
}

static char ***hook_NSGetArgv(void) {
    return &guest_argv;
}

static int hook_NSGetExecutablePath(char *buf, uint32_t *bufsize) {
    uint32_t needed = (uint32_t)strlen(guest_executable_path) + 1;
    if (*bufsize < needed) {
        *bufsize = needed;
        return -1;
    }
    memcpy(buf, guest_executable_path, needed);
    return 0;
}

BOOL guest_bind_process_info(const char *imagePath, int argc, char **argv, const char *executablePath) {
    guest_argc = argc;
    guest_argv = argv;
    strlcpy(guest_executable_path, executablePath, sizeof(guest_executable_path));

    char wanted[PATH_MAX];
    if (!realpath(imagePath, wanted)) strlcpy(wanted, imagePath, sizeof(wanted));

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        char resolved[PATH_MAX];
        if (!name) continue;
        if (!realpath(name, resolved)) strlcpy(resolved, name, sizeof(resolved));
        if (strcmp(resolved, wanted) != 0) continue;

        struct rebinding rebindings[] = {
            { "_NSGetArgc", (void *)hook_NSGetArgc, NULL },
            { "_NSGetArgv", (void *)hook_NSGetArgv, NULL },
            { "_NSGetExecutablePath", (void *)hook_NSGetExecutablePath, NULL },
        };
        int result = rebind_symbols_image((void *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i),
                                          rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
        return result == 0;
    }
    return NO;
}
