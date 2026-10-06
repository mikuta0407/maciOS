//
//  CodeSignatureRehash.m
//  maciOS
//

#import "CodeSignatureRehash.h"

#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0
#define CSMAGIC_CODEDIRECTORY 0xfade0c02
#define CS_HASHTYPE_SHA1 1
#define CS_HASHTYPE_SHA256 2
#define CS_HASHTYPE_SHA256_TRUNCATED 3
#define CS_HASHTYPE_SHA384 4

typedef struct {
    uint32_t type;
    uint32_t offset;
} cs_blob_index;

typedef struct {
    uint32_t magic;
    uint32_t length;
    uint32_t count;
    cs_blob_index index[];
} cs_super_blob;

typedef struct {
    uint32_t magic;
    uint32_t length;
    uint32_t version;
    uint32_t flags;
    uint32_t hashOffset;
    uint32_t identOffset;
    uint32_t nSpecialSlots;
    uint32_t nCodeSlots;
    uint32_t codeLimit;
    uint8_t hashSize;
    uint8_t hashType;
    uint8_t platform;
    uint8_t pageSize;
    uint32_t spare2;
} cs_code_directory;

static void hash_page(uint8_t type, const uint8_t *data, size_t length, uint8_t *out, size_t outSize) {
    uint8_t digest[CC_SHA384_DIGEST_LENGTH];
    switch (type) {
        case CS_HASHTYPE_SHA1:
            CC_SHA1(data, (CC_LONG)length, digest);
            break;
        case CS_HASHTYPE_SHA384:
            CC_SHA384(data, (CC_LONG)length, digest);
            break;
        default:
            CC_SHA256(data, (CC_LONG)length, digest);
            break;
    }
    memcpy(out, digest, outSize);
}

static BOOL rehash_slice(uint8_t *slice, size_t sliceSize) {
    struct mach_header_64 *header = (struct mach_header_64 *)slice;
    if (sliceSize < sizeof(*header) || header->magic != MH_MAGIC_64) return NO;

    struct linkedit_data_command *signature = NULL;
    uint8_t *cursor = slice + sizeof(*header);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cursor;
        if (lc->cmd == LC_CODE_SIGNATURE) {
            signature = (struct linkedit_data_command *)lc;
            break;
        }
        cursor += lc->cmdsize;
    }
    if (!signature || (uint64_t)signature->dataoff + signature->datasize > sliceSize) return NO;

    cs_super_blob *superBlob = (cs_super_blob *)(slice + signature->dataoff);
    if (ntohl(superBlob->magic) != CSMAGIC_EMBEDDED_SIGNATURE) return NO;

    BOOL rehashed = NO;
    uint32_t count = ntohl(superBlob->count);
    for (uint32_t i = 0; i < count; i++) {
        uint32_t offset = ntohl(superBlob->index[i].offset);
        if (offset + sizeof(cs_code_directory) > signature->datasize) continue;
        cs_code_directory *cd = (cs_code_directory *)((uint8_t *)superBlob + offset);
        if (ntohl(cd->magic) != CSMAGIC_CODEDIRECTORY) continue;

        uint32_t nCodeSlots = ntohl(cd->nCodeSlots);
        uint32_t codeLimit = ntohl(cd->codeLimit);
        uint32_t hashOffset = ntohl(cd->hashOffset);
        size_t pageSize = cd->pageSize ? ((size_t)1 << cd->pageSize) : codeLimit;
        if (codeLimit > sliceSize) continue;
        if (offset + hashOffset + (uint64_t)nCodeSlots * cd->hashSize > signature->datasize) continue;

        uint8_t *hashes = (uint8_t *)cd + hashOffset;
        for (uint32_t slot = 0; slot < nCodeSlots; slot++) {
            size_t start = slot * pageSize;
            if (start >= codeLimit) break;
            size_t length = MIN(pageSize, codeLimit - start);
            hash_page(cd->hashType, slice + start, length, hashes + (size_t)slot * cd->hashSize, cd->hashSize);
        }
        rehashed = YES;
    }
    return rehashed;
}

BOOL macho_rehash_code_signature(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDWR);
    if (fd < 0) return NO;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(uint32_t)) {
        close(fd);
        return NO;
    }
    size_t size = (size_t)st.st_size;
    uint8_t *file = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (file == MAP_FAILED) return NO;

    BOOL result = NO;
    uint32_t magic = *(uint32_t *)file;
    if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
        struct fat_header *fat = (struct fat_header *)file;
        uint32_t archCount = OSSwapBigToHostInt32(fat->nfat_arch);
        struct fat_arch *archs = (struct fat_arch *)(fat + 1);
        for (uint32_t i = 0; i < archCount; i++) {
            uint32_t offset = OSSwapBigToHostInt32(archs[i].offset);
            uint32_t sliceSize = OSSwapBigToHostInt32(archs[i].size);
            if ((uint64_t)offset + sliceSize > size) continue;
            result = rehash_slice(file + offset, sliceSize) || result;
        }
    } else {
        result = rehash_slice(file, size);
    }

    msync(file, size, MS_SYNC);
    munmap(file, size);
    return result;
}
