// StikDebug JIT script for maciOS.
//
// Without TXM, attaching once is enough: it marks the process CS_DEBUGGED
// and maciOS can map executable memory itself, so the script detaches.
//
// With TXM (iOS 26 on newer devices), maciOS asks for every executable
// mapping it makes: whenever dyld maps a guest library's code, maciOS calls
// BreakMarkJITMapping(addr, len) (maciOS/Core/JIT/dyld_bypass_validation.m),
// which runs `brk #0x69` with the region in x0/x1. Guest programs load
// libraries for as long as the app runs, so the script stays attached until
// the app exits, preparing each region and passing every other signal on.
//
// Use it from LiveContainer: maciOS's app settings > JIT launch script.

const BRK_MARK_JIT_MAPPING = 0x69;
const SIGTRAP = 0x05;
const SIGSTOP = 0x11;

// Logging every stop slows down guest programs; set to true when debugging.
const verbose = false;

function logVerbose(msg) {
    if (verbose) {
        log(msg);
    }
}

// Registers come as 8 little-endian bytes in hex.
function hexToNumber(hex) {
    let num = 0n;
    for (let i = hex.length - 2; i >= 0; i -= 2) {
        num = (num << 8n) | BigInt(parseInt(hex.substr(i, 2), 16));
    }
    return num;
}

function numberToHex(num) {
    let hex = '';
    for (let i = 0; i < 8; i++) {
        hex += Number(num & 0xffn).toString(16).padStart(2, '0');
        num >>= 8n;
    }
    return hex;
}

// A register field of a stop reply: register 0x20 is pc, 0x00 x0, ...
function register(reply, num) {
    const match = new RegExp(`;${num}:([0-9a-f]{16});`).exec(reply);
    return match ? hexToNumber(match[1]) : null;
}

// The immediate of the brk instruction at pc, or null for anything else.
function brkImmediate(pc) {
    const word = send_command(`m${pc.toString(16)},4`);
    if (!/^[0-9a-f]{8}$/.test(word)) {
        return null;
    }
    const insn = Number(hexToNumber(word));
    if (((insn & 0xffe0001f) >>> 0) !== 0xd4200000) {
        return null;
    }
    return (insn >>> 5) & 0xffff;
}

// Makes the region maciOS just mapped executable, then steps over the brk.
function markJITMapping(reply, tid, pc) {
    const addr = register(reply, '00');
    const len = register(reply, '01');
    if (addr === null || len === null) {
        log(`Failed to read x0/x1: ${reply}`);
        return;
    }
    logVerbose(`Preparing 0x${len.toString(16)} bytes at 0x${addr.toString(16)}`);
    const result = prepare_memory_region(addr, len);
    if (result !== 'OK') {
        log(`prepare_memory_region(0x${addr.toString(16)}, 0x${len.toString(16)}) = ${result}`);
    }
    send_command(`P20=${numberToHex(pc + 4n)};thread:${tid};`);
}

// Handles one stop and resumes the app; returns the next stop reply.
function resume(reply) {
    const stop = /^T([0-9a-f]{2})thread:([0-9a-f]+);/.exec(reply);
    if (!stop) {
        log(`Unexpected stop reply: ${reply}`);
        return send_command('c');
    }
    const signal = parseInt(stop[1], 16);
    const tid = stop[2];

    if (signal === SIGTRAP) {
        const pc = register(reply, '20');
        if (pc !== null && brkImmediate(pc) === BRK_MARK_JIT_MAPPING) {
            markJITMapping(reply, tid, pc);
            return send_command('c');
        }
    }
    // The stop from attaching (or an interrupt) is not the app's signal.
    if (signal === 0 || signal === SIGSTOP) {
        return send_command('c');
    }
    // Anything else (a guest's own signal, a crash) goes to the app as usual.
    logVerbose(`Passing on signal ${signal} (thread ${tid})`);
    return send_command(`vCont;C${stop[1]}:${tid};c`);
}

const pid = get_pid();
log(`Attaching to maciOS (pid ${pid})`);
let reply = send_command(`vAttach;${pid.toString(16)}`);
logVerbose(`vAttach: ${reply}`);

if (!hasTXM()) {
    send_command('D');
    log('No TXM: JIT is enabled, detached.');
} else {
    log('TXM: staying attached to prepare memory for guest programs. Keep StikDebug running in the background.');
    let failures = 0;
    for (;;) {
        if (/^[WX]/.test(reply)) {
            log(`maciOS exited (${reply}).`);
            break;
        }
        if (reply === '') {
            // The connection to debugserver is gone.
            if (++failures >= 3) {
                log('Lost the debugger connection.');
                break;
            }
            reply = send_command('c');
            continue;
        }
        failures = 0;
        reply = resume(reply);
    }
}
