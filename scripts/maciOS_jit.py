"""Gives maciOS JIT from this Mac, like stikdebug/maciOS.js does on the device.

    xcrun lldb --batch -o "command script import scripts/maciOS_jit.py" \
        -o "maciOS_jit <device-id> <pid> [<dump-request-file>]"

(Inside lldb itself: the device commands need the lldb binary.)

Attaches lldb to maciOS on a USB-connected device and stays attached: with
TXM (every device on iOS 27), each executable mapping maciOS makes for a
guest library has to be prepared by a debugger. maciOS asks with
`brk #0x69` (BreakMarkJITMapping, x0 = address, x1 = length); the debugger
writes a byte to each page of the region and steps over the brk. Every other
stop goes back to the app. Runs until maciOS exits.

Attach after maciOS has set up its dyld hooks (it waits for a debugger
before loading the shell): the debugger's exception port then replaces the
one of the hooks' breakpoint handler (ellekit), so lldb's own breakpoints
work, and this script redirects the hooks' hardware breakpoints itself, as
ellekit's handler would, from maciOS's `hooks` table.
"""

import os
import time

import lldb

BRK_MARK_JIT_MAPPING = 0x69
JIT_PAGE_SIZE = 16384

# Signals guests use as part of normal work: hand them over without stopping.
PASSED_SIGNALS = [
    "SIGHUP", "SIGINT", "SIGQUIT", "SIGPIPE", "SIGALRM", "SIGTERM", "SIGURG",
    "SIGTSTP", "SIGCONT", "SIGCHLD", "SIGTTIN", "SIGTTOU", "SIGIO", "SIGXCPU",
    "SIGXFSZ", "SIGVTALRM", "SIGPROF", "SIGWINCH", "SIGINFO", "SIGUSR1",
    "SIGUSR2", "SIGSEGV", "SIGBUS", "SIGILL", "SIGFPE", "SIGABRT", "SIGSYS",
]


def log(message):
    print(f"{time.strftime('%H:%M:%S')} {message}", flush=True)


def command(interpreter, line):
    result = lldb.SBCommandReturnObject()
    interpreter.HandleCommand(line, result)
    # The device commands report success with an empty result, not Succeeded().
    if not result.Succeeded() and result.GetError().strip():
        raise RuntimeError(f"{line}: {result.GetError().strip()}")
    return result.GetOutput()


def brk_immediate(process, pc):
    error = lldb.SBError()
    word = process.ReadUnsignedFromMemory(pc, 4, error)
    if error.Fail() or (word & 0xFFE0001F) != 0xD4200000:
        return None
    return (word >> 5) & 0xFFFF


def prepare_region(process, thread):
    frame = thread.GetFrameAtIndex(0)
    address = frame.FindRegister("x0").GetValueAsUnsigned()
    length = frame.FindRegister("x1").GetValueAsUnsigned()
    error = lldb.SBError()
    for offset in range(0, length, JIT_PAGE_SIZE):
        process.WriteMemory(address + offset, b"\x69", error)
        if error.Fail():
            log(f"could not prepare 0x{address + offset:x}: {error}")
            break
    frame.SetPC(frame.GetPC() + 4)
    log(f"prepared 0x{length:x} bytes at 0x{address:x}")


def address_of(target, name):
    symbols = target.FindSymbols(name)
    for context in symbols:
        address = context.GetSymbol().GetStartAddress().GetLoadAddress(target)
        if address != lldb.LLDB_INVALID_ADDRESS:
            return address
    raise RuntimeError(f"no symbol {name} in maciOS")


def ellekit_hooks(process):
    """maciOS's hardware-breakpoint hooks (ElleKitJITLessHook.m): target -> replacement."""
    target = process.GetTarget()
    error = lldb.SBError()
    count = process.ReadUnsignedFromMemory(address_of(target, "hookCount"), 4, error)
    table = address_of(target, "hooks")
    hooks = {}
    for index in range(min(count, 16)):
        hooks[process.ReadPointerFromMemory(table + index * 16, error)] = \
            process.ReadPointerFromMemory(table + index * 16 + 8, error)
    return hooks


def handle_stop(process):
    """Handles the threads that stopped; True if all were maciOS's requests."""
    handled = True
    hooks = None
    for thread in process:
        reason = thread.GetStopReason()
        if reason in (lldb.eStopReasonNone, lldb.eStopReasonInvalid):
            continue
        frame = thread.GetFrameAtIndex(0)
        pc = frame.GetPC()
        if hooks is None:
            hooks = ellekit_hooks(process)
        if pc in hooks:
            frame.SetPC(hooks[pc])
        elif brk_immediate(process, pc) == BRK_MARK_JIT_MAPPING:
            prepare_region(process, thread)
        else:
            handled = False
            log(f"thread {thread.GetThreadID():#x} stopped at 0x{pc:x}: {thread.GetStopDescription(256)}")
    return handled


def maciOS_jit(debugger, arguments, result, internal_dict):
    device, pid, *rest = arguments.split()
    try:
        run(debugger, device, int(pid), rest[0] if rest else None)
    except Exception as error:
        log(f"error: {error}")


def run(debugger, device, pid, dump_request):
    """Runs until maciOS exits. When the app stops while the file
    `dump_request` exists (device.sh stacks sends SIGSTOP), logs every
    thread's backtrace and removes the file."""
    debugger.SetAsync(False)
    interpreter = debugger.GetCommandInterpreter()
    # Devices are discovered in the background after start-up.
    for attempt in range(20):
        try:
            command(interpreter, f"device select {device}")
            break
        except RuntimeError:
            if attempt == 19:
                raise
            command(interpreter, "device list")
            time.sleep(0.5)
    command(interpreter, f"device process attach --pid {pid}")
    # The attach finishes in the background.
    process = None
    for _ in range(120):
        process = debugger.GetSelectedTarget().GetProcess()
        if process.IsValid() and process.GetState() == lldb.eStateStopped:
            break
        time.sleep(0.5)
    else:
        state = lldb.SBDebugger.StateAsCString(process.GetState()) if process and process.IsValid() else "no process"
        raise RuntimeError(f"could not attach to pid {pid} ({state})")
    for signal in PASSED_SIGNALS:
        command(interpreter, f"process handle {signal} --stop false --pass true --notify false")
    # lldb's own breakpoints (dyld's image notifier) are not needed here, and
    # on top of the hooks' hardware breakpoints they leave the app stuck.
    target = process.GetTarget()
    log(command(interpreter, "breakpoint list --internal").strip())
    for breakpoint_id in range(-1, -50, -1):
        breakpoint = target.FindBreakpointByID(breakpoint_id)
        if breakpoint.IsValid():
            breakpoint.SetEnabled(False)
            log(f"disabled lldb's breakpoint {breakpoint_id}: {breakpoint}")
    # device.sh stacks stops the app with SIGSTOP to have the threads logged.
    command(interpreter, "process handle SIGSTOP --stop true --pass false --notify false")
    # A brk that reaches the app as a signal is for us, not for the app.
    command(interpreter, "process handle SIGTRAP --stop true --pass false --notify true")
    log(f"attached to pid {pid}")

    while True:
        error = process.Continue()
        if error.Fail():
            log(f"continue failed: {error}")
        state = process.GetState()
        if state in (lldb.eStateExited, lldb.eStateDetached):
            log(f"maciOS exited ({process.GetExitStatus()})")
            return
        if state == lldb.eStateCrashed:
            handle_stop(process)
            dump_threads(process)
            log("maciOS crashed")
            return
        if state != lldb.eStateStopped:
            continue
        if not handle_stop(process) and trapped(process):
            return
        if dump_request and os.path.exists(dump_request):
            dump_threads(process)
            os.remove(dump_request)


def describe(frame):
    """A frame without its arguments, which lldb is slow to show for guests."""
    module = frame.GetModule().GetFileSpec().GetFilename() or "?"
    return f"#{frame.GetFrameID()} {frame.GetPC():#x} {module}`{frame.GetFunctionName() or '?'}"


def dump_threads(process):
    for thread in process:
        log(f"thread {thread.GetThreadID():#x} {thread.GetName() or ''} {thread.GetQueueName() or ''} "
            f"stop={thread.GetStopDescription(128)!r} pc={thread.GetFrameAtIndex(0).GetPC():#x}")
        for frame in list(thread)[:30]:
            log(f"  {describe(frame)}")
    log("end of threads")


def trapped(process):
    """A trap of the app's own would only stop here again: it crashed."""
    for thread in process:
        if thread.GetStopReason() not in (lldb.eStopReasonNone, lldb.eStopReasonInvalid) \
                and brk_immediate(process, thread.GetFrameAtIndex(0).GetPC()) is not None:
            log("maciOS trapped; killing it")
            for frame in thread:
                log(f"  {describe(frame)}")
            process.Kill()
            return True
    return False


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(f"command script add -f {__name__}.maciOS_jit maciOS_jit")
