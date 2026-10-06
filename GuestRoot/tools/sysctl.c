// Minimal sysctl(8) for reading values: `sysctl [-n] name ...`.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

static int show(const char *name, int bare) {
    int mib[CTL_MAXNAME + 2];
    size_t length = CTL_MAXNAME;
    if (sysctlnametomib(name, mib + 2, &length) != 0) {
        fprintf(stderr, "sysctl: unknown oid '%s'\n", name);
        return 1;
    }
    // {0, 4, oid...} gives the kind and format of the oid.
    mib[0] = 0;
    mib[1] = 4;
    unsigned char info[BUFSIZ];
    size_t infoSize = sizeof(info);
    if (sysctl(mib, (u_int)length + 2, info, &infoSize, NULL, 0) != 0) {
        perror(name);
        return 1;
    }
    uint32_t kind;
    memcpy(&kind, info, sizeof(kind));
    const char *format = (const char *)info + sizeof(kind);
    if ((kind & CTLTYPE) == CTLTYPE_NODE) {
        fprintf(stderr, "sysctl: listing '%s' is not supported\n", name);
        return 1;
    }

    size_t size = 0;
    if (sysctl(mib + 2, (u_int)length, NULL, &size, NULL, 0) != 0) {
        perror(name);
        return 1;
    }
    char *value = calloc(1, size + 1);
    if (!value || sysctl(mib + 2, (u_int)length, value, &size, NULL, 0) != 0) {
        perror(name);
        free(value);
        return 1;
    }
    if (!bare) printf("%s: ", name);
    switch (kind & CTLTYPE) {
    case CTLTYPE_STRING:
        printf("%s", value);
        break;
    case CTLTYPE_INT:
        for (size_t i = 0; i + sizeof(int) <= size; i += sizeof(int)) {
            int v;
            memcpy(&v, value + i, sizeof(v));
            if (format[0] == 'I' && format[1] == 'U') printf(i ? " %u" : "%u", (unsigned)v);
            else printf(i ? " %d" : "%d", v);
        }
        break;
    case CTLTYPE_QUAD: {
        int64_t v = 0;
        memcpy(&v, value, size < sizeof(v) ? size : sizeof(v));
        if (format[0] == 'Q' && format[1] == 'U') printf("%llu", (unsigned long long)v);
        else printf("%lld", (long long)v);
        break;
    }
    default:
        if (!strcmp(format, "L") || !strcmp(format, "LU")) {
            long v = 0;
            memcpy(&v, value, size < sizeof(v) ? size : sizeof(v));
            printf("%ld", v);
        } else {
            fprintf(stderr, "sysctl: cannot show '%s' (format %s)\n", name, format);
            free(value);
            if (!bare) printf("\n");
            return 1;
        }
    }
    printf("\n");
    free(value);
    return 0;
}

int main(int argc, char **argv) {
    int bare = 0, status = 0;
    int i = 1;
    for (; i < argc && argv[i][0] == '-'; i++) {
        for (const char *flag = argv[i] + 1; *flag; flag++) {
            if (*flag == 'n') bare = 1;
            else if (*flag != 'h' && *flag != 'b') {
                fprintf(stderr, "usage: sysctl [-n] name ...\n");
                return 1;
            }
        }
    }
    if (i == argc) {
        fprintf(stderr, "usage: sysctl [-n] name ...\n");
        return 1;
    }
    for (; i < argc; i++) status |= show(argv[i], bare);
    return status;
}
