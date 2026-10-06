//
//  GuestProcess.m
//  maciOS
//

#import "GuestProcess.h"
#import "../JIT/ellekit/fishhook/fishhook.h"

#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>

static struct sigaction saved_signal_actions[NSIG];
static BOOL saved_signal_valid[NSIG];

void guest_save_signal_handlers(void) {
    for (int sig = 1; sig < NSIG; sig++) {
        saved_signal_valid[sig] = sigaction(sig, NULL, &saved_signal_actions[sig]) == 0;
    }
}

void guest_restore_signal_handlers(void) {
    for (int sig = 1; sig < NSIG; sig++) {
        if (sig == SIGKILL || sig == SIGSTOP || !saved_signal_valid[sig]) continue;
        sigaction(sig, &saved_signal_actions[sig], NULL);
    }
}
