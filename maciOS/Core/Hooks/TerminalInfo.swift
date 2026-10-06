//
//  TerminalInfo.swift
//  maciOS
//
//  Created by Stossy11 on 24/08/2025.
//

import Foundation

var original_exit: UnsafeMutableRawPointer?
var original_abort: UnsafeMutableRawPointer?

func install_pty_hooks() {
    vtty_install_hooks()
}

func updateTerminalSize(rows: UInt16, cols: UInt16) {
    vtty_set_window_size(rows, cols)
}

@_cdecl("my_exit")
func my_exit(_ status: Int32) {
    pthread_exit(nil)
}

@_cdecl("my_abort")
func my_abort() {
    // abort() must not return; end the guest's thread instead of the whole app.
    NSLog("abort was called — terminating the calling thread")
    pthread_exit(nil)
}

func install_exit_hook() {
    let exitReplacement = unsafeBitCast(my_exit as @convention(c) (Int32) -> Void, to: UnsafeMutableRawPointer.self)
    let abortReplacement = unsafeBitCast(my_abort as @convention(c) () -> Void, to: UnsafeMutableRawPointer.self)

    var exit_rebinding = rebinding(
        name: strdup("exit"),
        replacement: exitReplacement,
        replaced: &original_exit
    )
    
    var exit2_rebinding = rebinding(
        name: strdup("_exit"),
        replacement: exitReplacement,
        replaced: &original_exit
    )

    var abort_rebinding = rebinding(
        name: strdup("abort"),
        replacement: abortReplacement,
        replaced: &original_abort
    )
    
    install_pty_hooks()

    let result1 = rebind_symbols(&exit_rebinding, 1)
    let result2 = rebind_symbols(&exit2_rebinding, 1)
    let result3 = rebind_symbols(&abort_rebinding, 1)

    if result1 + result2 + result3 == 0 {
        NSLog("Successfully rebound exit() and abort()")
    } else {
        NSLog("Failed to rebind exit() or abort()")
    }
}
