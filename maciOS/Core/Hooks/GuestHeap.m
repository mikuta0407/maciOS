//
//  GuestHeap.m
//  maciOS
//
//  Blocks are carved from chunks of mapped memory and never returned to the
//  system until the heap goes away, so a snapshot only has to copy the used
//  part of each chunk. Small blocks are kept on per-size free lists, larger
//  ones on a single first-fit list.
//

#import "GuestHeap.h"

#include <os/lock.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define HEAP_ALIGNMENT 16
#define HEAP_SMALL_MAX 1024
#define HEAP_CLASSES (HEAP_SMALL_MAX / HEAP_ALIGNMENT)
#define HEAP_CHUNK_SIZE ((size_t)1 << 20)

typedef struct {
    size_t size;    // usable bytes
    size_t offset;  // from the start of the block this one was aligned within
} block_header;

_Static_assert(sizeof(block_header) == HEAP_ALIGNMENT, "headers keep blocks aligned");

typedef struct free_block {
    struct free_block *next;
} free_block;

typedef struct {
    uintptr_t base;
    size_t size;
    size_t used;
} heap_chunk;

struct guest_heap {
    os_unfair_lock lock;
    free_block *small[HEAP_CLASSES + 1];
    free_block *large;
    heap_chunk *chunks;
    int chunkCount, chunkCapacity;
    int current;    // the chunk new blocks are cut from
};

struct guest_heap_snapshot {
    struct guest_heap heap;
    heap_chunk *chunks;
    void **contents;
};

static inline size_t round_size(size_t size) {
    if (size == 0) size = 1;
    return (size + HEAP_ALIGNMENT - 1) & ~(size_t)(HEAP_ALIGNMENT - 1);
}

static inline block_header *header_of(const void *pointer) {
    return (block_header *)((uintptr_t)pointer - sizeof(block_header));
}

guest_heap *guest_heap_create(void) {
    guest_heap *heap = calloc(1, sizeof(*heap));
    if (!heap) return NULL;
    heap->lock = OS_UNFAIR_LOCK_INIT;
    heap->current = -1;
    return heap;
}

void guest_heap_destroy(guest_heap *heap) {
    for (int i = 0; i < heap->chunkCount; i++) {
        munmap((void *)heap->chunks[i].base, heap->chunks[i].size);
    }
    free(heap->chunks);
    free(heap);
}

static BOOL contains_locked(guest_heap *heap, uintptr_t address) {
    for (int i = 0; i < heap->chunkCount; i++) {
        heap_chunk *chunk = &heap->chunks[i];
        if (address >= chunk->base && address < chunk->base + chunk->used) return YES;
    }
    return NO;
}

BOOL guest_heap_contains(guest_heap *heap, const void *pointer) {
    if (!pointer) return NO;
    os_unfair_lock_lock(&heap->lock);
    BOOL result = contains_locked(heap, (uintptr_t)pointer);
    os_unfair_lock_unlock(&heap->lock);
    return result;
}

static heap_chunk *add_chunk_locked(guest_heap *heap, size_t size) {
    if (heap->chunkCount == heap->chunkCapacity) {
        int capacity = heap->chunkCapacity ? heap->chunkCapacity * 2 : 16;
        heap_chunk *chunks = realloc(heap->chunks, sizeof(*chunks) * (size_t)capacity);
        if (!chunks) return NULL;
        heap->chunks = chunks;
        heap->chunkCapacity = capacity;
    }
    void *memory = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (memory == MAP_FAILED) return NULL;
    heap_chunk *chunk = &heap->chunks[heap->chunkCount++];
    *chunk = (heap_chunk){ (uintptr_t)memory, size, 0 };
    return chunk;
}

/// Cuts a new block of `size` usable bytes from the end of the used memory.
static void *carve_locked(guest_heap *heap, size_t size) {
    size_t needed = size + sizeof(block_header);
    heap_chunk *chunk = heap->current >= 0 ? &heap->chunks[heap->current] : NULL;
    if (!chunk || chunk->size - chunk->used < needed) {
        if (needed > HEAP_CHUNK_SIZE / 2) {
            // A big block gets a chunk of its own, so the current one keeps
            // its free space.
            size_t length = (needed + PAGE_MAX_SIZE - 1) & ~(size_t)(PAGE_MAX_SIZE - 1);
            heap_chunk *own = add_chunk_locked(heap, length);
            if (!own) return NULL;
            own->used = needed;
            block_header *header = (block_header *)own->base;
            *header = (block_header){ size, 0 };
            return header + 1;
        }
        chunk = add_chunk_locked(heap, HEAP_CHUNK_SIZE);
        if (!chunk) return NULL;
        heap->current = heap->chunkCount - 1;
    }
    block_header *header = (block_header *)(chunk->base + chunk->used);
    chunk->used += needed;
    *header = (block_header){ size, 0 };
    return header + 1;
}

static void *malloc_locked(guest_heap *heap, size_t size) {
    size = round_size(size);
    if (size <= HEAP_SMALL_MAX) {
        free_block **list = &heap->small[size / HEAP_ALIGNMENT];
        if (*list) {
            free_block *block = *list;
            *list = block->next;
            return block;
        }
        return carve_locked(heap, size);
    }
    // First fit, but not in a block more than twice as big as asked for.
    for (free_block **link = &heap->large; *link; link = &(*link)->next) {
        size_t available = header_of(*link)->size;
        if (available >= size && available / 2 <= size) {
            free_block *block = *link;
            *link = block->next;
            return block;
        }
    }
    return carve_locked(heap, size);
}

void *guest_heap_malloc(guest_heap *heap, size_t size) {
    if (size > SIZE_MAX / 2) return NULL;
    os_unfair_lock_lock(&heap->lock);
    void *result = malloc_locked(heap, size);
    os_unfair_lock_unlock(&heap->lock);
    return result;
}

void *guest_heap_aligned(guest_heap *heap, size_t alignment, size_t size) {
    if (alignment <= HEAP_ALIGNMENT) return guest_heap_malloc(heap, size);
    if (size > SIZE_MAX / 2 || alignment > SIZE_MAX / 4) return NULL;
    os_unfair_lock_lock(&heap->lock);
    void *outer = malloc_locked(heap, size + alignment + sizeof(block_header));
    void *result = NULL;
    if (outer) {
        uintptr_t start = ((uintptr_t)outer + sizeof(block_header) + alignment - 1) & ~(uintptr_t)(alignment - 1);
        block_header *header = header_of((void *)start);
        *header = (block_header){ size, start - (uintptr_t)outer };
        result = (void *)start;
    }
    os_unfair_lock_unlock(&heap->lock);
    return result;
}

void guest_heap_free(guest_heap *heap, void *pointer) {
    os_unfair_lock_lock(&heap->lock);
    block_header *header = header_of(pointer);
    if (header->offset) {
        pointer = (void *)((uintptr_t)pointer - header->offset);
        header = header_of(pointer);
    }
    free_block *block = pointer;
    if (header->size <= HEAP_SMALL_MAX) {
        block->next = heap->small[header->size / HEAP_ALIGNMENT];
        heap->small[header->size / HEAP_ALIGNMENT] = block;
    } else {
        block->next = heap->large;
        heap->large = block;
    }
    os_unfair_lock_unlock(&heap->lock);
}

size_t guest_heap_size(guest_heap *heap, const void *pointer) {
    return header_of(pointer)->size;
}

guest_heap_snapshot *guest_heap_save(guest_heap *heap) {
    guest_heap_snapshot *snapshot = calloc(1, sizeof(*snapshot));
    if (!snapshot) return NULL;
    os_unfair_lock_lock(&heap->lock);
    snapshot->heap = *heap;
    snapshot->heap.lock = OS_UNFAIR_LOCK_INIT;
    int count = heap->chunkCount;
    snapshot->chunks = malloc(sizeof(heap_chunk) * (size_t)(count ? count : 1));
    snapshot->contents = calloc((size_t)(count ? count : 1), sizeof(void *));
    BOOL ok = snapshot->chunks && snapshot->contents;
    for (int i = 0; ok && i < count; i++) {
        heap_chunk *chunk = &heap->chunks[i];
        snapshot->chunks[i] = *chunk;
        snapshot->contents[i] = malloc(chunk->used ? chunk->used : 1);
        if (!snapshot->contents[i]) {
            ok = NO;
            break;
        }
        memcpy(snapshot->contents[i], (void *)chunk->base, chunk->used);
    }
    os_unfair_lock_unlock(&heap->lock);
    if (!ok) {
        guest_heap_discard(snapshot);
        return NULL;
    }
    return snapshot;
}

void guest_heap_restore(guest_heap *heap, guest_heap_snapshot *snapshot) {
    os_unfair_lock_lock(&heap->lock);
    int count = snapshot->heap.chunkCount;
    // Chunks added since the snapshot hold nothing the program had then.
    for (int i = count; i < heap->chunkCount; i++) {
        munmap((void *)heap->chunks[i].base, heap->chunks[i].size);
    }
    for (int i = 0; i < count; i++) {
        memcpy((void *)snapshot->chunks[i].base, snapshot->contents[i], snapshot->chunks[i].used);
        heap->chunks[i] = snapshot->chunks[i];
    }
    heap_chunk *chunks = heap->chunks;
    int capacity = heap->chunkCapacity;
    os_unfair_lock held = heap->lock;
    *heap = snapshot->heap;
    heap->lock = held;
    heap->chunks = chunks;
    heap->chunkCapacity = capacity;
    heap->chunkCount = count;
    os_unfair_lock_unlock(&heap->lock);
    guest_heap_discard(snapshot);
}

void guest_heap_discard(guest_heap_snapshot *snapshot) {
    if (snapshot->contents) {
        for (int i = 0; i < snapshot->heap.chunkCount; i++) free(snapshot->contents[i]);
    }
    free(snapshot->contents);
    free(snapshot->chunks);
    free(snapshot);
}
