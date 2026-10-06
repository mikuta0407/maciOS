//
//  GuestHeap.h
//  maciOS
//
//  A private heap for a guest program. A program that forks without exec'ing,
//  such as a shell running a subshell, has its child run on the same memory;
//  with all of the program's allocations in one place they can be saved at
//  the fork and put back when the child ends, as if it had had its own copy.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct guest_heap guest_heap;
typedef struct guest_heap_snapshot guest_heap_snapshot;

guest_heap * _Nullable guest_heap_create(void);
/// Unmaps all of the heap's memory.
void guest_heap_destroy(guest_heap *heap);

BOOL guest_heap_contains(guest_heap *heap, const void * _Nullable pointer);
void * _Nullable guest_heap_malloc(guest_heap *heap, size_t size);
void * _Nullable guest_heap_aligned(guest_heap *heap, size_t alignment, size_t size);
/// `pointer` must be from this heap.
void guest_heap_free(guest_heap *heap, void *pointer);
size_t guest_heap_size(guest_heap *heap, const void *pointer);

/// Copies the heap's contents and bookkeeping.
guest_heap_snapshot * _Nullable guest_heap_save(guest_heap *heap);
/// Puts the heap back as it was when `snapshot` was taken, and frees it.
void guest_heap_restore(guest_heap *heap, guest_heap_snapshot *snapshot);
void guest_heap_discard(guest_heap_snapshot *snapshot);

NS_ASSUME_NONNULL_END
