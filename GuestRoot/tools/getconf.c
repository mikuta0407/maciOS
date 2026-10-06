// Minimal getconf(1): `getconf name` for common sysconf and confstr names.
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const struct { const char *name; int key; } sysconf_names[] = {
    { "_NPROCESSORS_ONLN", _SC_NPROCESSORS_ONLN },
    { "NPROCESSORS_ONLN", _SC_NPROCESSORS_ONLN },
    { "_NPROCESSORS_CONF", _SC_NPROCESSORS_CONF },
    { "NPROCESSORS_CONF", _SC_NPROCESSORS_CONF },
    { "PAGESIZE", _SC_PAGESIZE },
    { "PAGE_SIZE", _SC_PAGESIZE },
    { "ARG_MAX", _SC_ARG_MAX },
    { "CHILD_MAX", _SC_CHILD_MAX },
    { "CLK_TCK", _SC_CLK_TCK },
    { "OPEN_MAX", _SC_OPEN_MAX },
    { "LINE_MAX", _SC_LINE_MAX },
    { "NGROUPS_MAX", _SC_NGROUPS_MAX },
    { "_PHYS_PAGES", _SC_PHYS_PAGES },
};

static const struct { const char *name; int key; } confstr_names[] = {
    { "PATH", _CS_PATH },
    { "DARWIN_USER_DIR", _CS_DARWIN_USER_DIR },
    { "DARWIN_USER_TEMP_DIR", _CS_DARWIN_USER_TEMP_DIR },
    { "DARWIN_USER_CACHE_DIR", _CS_DARWIN_USER_CACHE_DIR },
};

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: getconf name\n");
        return 1;
    }
    const char *name = argv[1];
    for (size_t i = 0; i < sizeof(sysconf_names) / sizeof(sysconf_names[0]); i++) {
        if (strcmp(name, sysconf_names[i].name) != 0) continue;
        errno = 0;
        long value = sysconf(sysconf_names[i].key);
        if (value == -1 && errno) {
            perror("getconf");
            return 1;
        }
        if (value == -1) puts("undefined");
        else printf("%ld\n", value);
        return 0;
    }
    for (size_t i = 0; i < sizeof(confstr_names) / sizeof(confstr_names[0]); i++) {
        if (strcmp(name, confstr_names[i].name) != 0) continue;
        char value[PATH_MAX];
        if (confstr(confstr_names[i].key, value, sizeof(value)) == 0) {
            perror("getconf");
            return 1;
        }
        puts(value);
        return 0;
    }
    fprintf(stderr, "getconf: no such configuration parameter `%s'\n", name);
    return 1;
}
