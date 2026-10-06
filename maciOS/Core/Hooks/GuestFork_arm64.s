//
//  GuestFork_arm64.s
//  maciOS
//
//  fork() for guest programs, emulated vfork-style on the calling thread.
//  The fork replacement records the caller's callee-saved registers and
//  returns 0, so the program carries on as the child. When the child execs
//  or exits, guest_vfork_resume() puts the stacks back as they were at the
//  fork and returns the child's pid from the original fork() call.
//
//  Context layout (see vfork_ctx in GuestSpawn.m):
//    0   x19..x28, x29, x30
//    96  sp
//    104 d8..d15
//    168 top of the stack guest_vfork_resume switches to
//

#if defined(__arm64__)

.text
.p2align 2

.globl _guest_fork_hook
_guest_fork_hook:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    bl      _guest_vfork_context
    ldp     x29, x30, [sp], #16
    cbz     x0, 1f
    stp     x19, x20, [x0, #0]
    stp     x21, x22, [x0, #16]
    stp     x23, x24, [x0, #32]
    stp     x25, x26, [x0, #48]
    stp     x27, x28, [x0, #64]
    stp     x29, x30, [x0, #80]
    mov     x9, sp
    str     x9, [x0, #96]
    stp     d8, d9, [x0, #104]
    stp     d10, d11, [x0, #120]
    stp     d12, d13, [x0, #136]
    stp     d14, d15, [x0, #152]
    b       _guest_vfork_begin
1:
    b       _guest_vfork_unavailable

// void guest_vfork_resume(vfork_ctx *ctx, pid_t pid) __attribute__((noreturn))
.globl _guest_vfork_resume
_guest_vfork_resume:
    mov     x19, x0
    mov     x20, x1
    // The stacks being restored include the frames we are running on now.
    ldr     x9, [x19, #168]
    mov     sp, x9
    mov     x29, #0
    mov     x0, x19
    bl      _guest_vfork_restore_stacks
    mov     x16, x19
    sxtw    x17, w20
    ldp     x19, x20, [x16, #0]
    ldp     x21, x22, [x16, #16]
    ldp     x23, x24, [x16, #32]
    ldp     x25, x26, [x16, #48]
    ldp     x27, x28, [x16, #64]
    ldp     x29, x30, [x16, #80]
    ldr     x9, [x16, #96]
    mov     sp, x9
    ldp     d8, d9, [x16, #104]
    ldp     d10, d11, [x16, #120]
    ldp     d12, d13, [x16, #136]
    ldp     d14, d15, [x16, #152]
    mov     x0, x17
    ret

#endif
