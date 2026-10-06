#!/bin/sh
# Develops maciOS on a USB-connected iPhone without touching it: builds a
# signed Debug app, installs and launches it, enables JIT by attaching a
# debugger from this Mac (devices without TXM), types into the terminal,
# and fetches logs and screenshots.
#
#   MACIOS_DEVICE=<name|udid> scripts/device.sh <command> [args]
#
#   devices          list connected devices (needs no MACIOS_DEVICE)
#   build            build and sign the Debug app (Xcode signs with the
#                    account signed in under Settings > Accounts)
#   install          install the built app
#   launch           (re)launch the app with JIT: lldb stays attached in the
#                    background (scripts/maciOS_jit.py, log in jit.log)
#   jit <pid>        attach the JIT helper to a running app
#   run              build, install and launch
#   stacks           log every thread's backtrace to jit.log (app keeps running)
#   type <text>      type text into the terminal (\n for Return)
#   pull             fetch Documents/maciOS-trace.log, maciOS.log and
#                    maciOS-terminal.log (all the terminal showed)
#   screen [lines]   print the end of the terminal, escape sequences removed
#   shot [file.png]  take a screenshot
#
# The device must be named explicitly: other devices may be connected that
# must not be touched. Output goes to build/device/.
#
#   MACIOS_TEAM       development team (default: 3R8LX96WPK)
#   MACIOS_BUNDLE_ID  bundle identifier (default: dev.mikuta0407.maciOS)
set -eu

cd "$(dirname "$0")/.."
TEAM="${MACIOS_TEAM:-3R8LX96WPK}"
BUNDLE_ID="${MACIOS_BUNDLE_ID:-dev.mikuta0407.maciOS}"
OUT="$PWD/build/device"
APP="$OUT/DerivedData/Build/Products/Debug-iphoneos/maciOS.app"
mkdir -p "$OUT"

die() {
    echo "error: $*" >&2
    exit 1
}

# Prints "<CoreDevice identifier> <UDID>" of MACIOS_DEVICE.
resolve_device() {
    [ -n "${MACIOS_DEVICE:-}" ] || die "set MACIOS_DEVICE to the device's name or UDID (see: scripts/device.sh devices)"
    xcrun devicectl list devices --quiet --json-output "$OUT/devices.json" >/dev/null
    /usr/bin/python3 -I - "$OUT/devices.json" "$MACIOS_DEVICE" <<'EOF'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
wanted = sys.argv[2]
matches = [d for d in devices
           if wanted in (d.get("identifier"),
                         d.get("hardwareProperties", {}).get("udid"),
                         d.get("deviceProperties", {}).get("name"))]
if len(matches) != 1:
    sys.exit(f"error: {len(matches)} devices match {wanted!r}")
d = matches[0]
print(d["identifier"], d["hardwareProperties"]["udid"])
EOF
}


build() {
    xcodebuild -project maciOS.xcodeproj -scheme maciOS -configuration Debug \
        -destination "id=$UDID" -derivedDataPath "$OUT/DerivedData" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
        DEVELOPMENT_TEAM="$TEAM" MACIOS_BUNDLE_ID="$BUNDLE_ID" \
        build >"$OUT/build.log" 2>&1 || {
        grep -E "error:" "$OUT/build.log" | sort -u >&2
        die "build failed (see $OUT/build.log)"
    }
    echo "$APP"
}

install_app() {
    [ -d "$APP" ] || die "no app at $APP; run build first"
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
}

launch() {
    # maciOS hooks dyld, then waits for the debugger before loading the shell.
    # devicectl sometimes cannot tell the pid of what it launched: retry.
    for attempt in 1 2 3; do
        xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing \
            --quiet --json-output "$OUT/launch.json" "$BUNDLE_ID" >/dev/null 2>"$OUT/launch.err" && break
        [ "$attempt" = 3 ] && { cat "$OUT/launch.err" >&2; die "could not launch maciOS"; }
        sleep 3
    done
    pid=$(/usr/bin/python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["result"]["process"]["processIdentifier"])' "$OUT/launch.json")
    echo "launched maciOS (pid $pid)"
    jit "$pid"
}

# With TXM (all devices on iOS 27) a debugger has to stay attached to
# prepare each executable mapping; see scripts/maciOS_jit.py. It resumes the
# app and runs in the background until the app exits.
jit() {
    pid="${1:-}"
    [ -n "$pid" ] || die "usage: jit <pid of maciOS>"
    pkill -f "maciOS_jit.py" 2>/dev/null || true
    rm -f "$OUT/stacks-request"
    nohup xcrun lldb --batch -o "command script import scripts/maciOS_jit.py" \
        -o "maciOS_jit $DEVICE_ID $pid $OUT/stacks-request" >"$OUT/jit.log" 2>&1 &
    for _ in $(seq 60); do
        grep -q "attached to pid" "$OUT/jit.log" && { echo "JIT helper attached to pid $pid (log: $OUT/jit.log)"; return; }
        kill -0 $! 2>/dev/null || break
        sleep 1
    done
    cat "$OUT/jit.log" >&2
    die "the JIT helper did not attach"
}

# The Debug app types whatever appears in Documents/.maciOS-input.
type_text() {
    printf '%b' "$1" >"$OUT/input"
    # The app takes the file as soon as it lands, which devicectl then
    # reports as a failure to find it: that is success.
    xcrun devicectl device copy to --device "$DEVICE_ID" --timeout 30 --quiet \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source "$OUT/input" --destination Documents/.maciOS-input >"$OUT/type.log" 2>&1 ||
        grep -q "Failed to retrieve the file node" "$OUT/type.log" || { cat "$OUT/type.log" >&2; return 1; }
}

stacks() {
    touch "$OUT/stacks-request"
    pid=$(sed -n 's/.*attached to pid \([0-9]*\).*/\1/p' "$OUT/jit.log" | tail -1)
    xcrun devicectl device process signal --device "$DEVICE_ID" --quiet --signal SIGSTOP --pid "$pid" >/dev/null
    for _ in $(seq 30); do
        [ -e "$OUT/stacks-request" ] || { sed -n '/thread 0x/,/end of threads/p' "$OUT/jit.log" | tail -n +1 >"$OUT/stacks.txt"; echo "$OUT/stacks.txt"; return; }
        sleep 1
    done
    rm -f "$OUT/stacks-request"
    die "the JIT helper did not answer (is it running?)"
}

pull() {
    for file in maciOS-trace.log maciOS.log maciOS-terminal.log; do
        xcrun devicectl device copy from --device "$DEVICE_ID" --timeout 30 --quiet \
            --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
            --source "Documents/$file" --destination "$OUT/$file" &&
            echo "$OUT/$file"
    done
}

screen() {
    xcrun devicectl device copy from --device "$DEVICE_ID" --timeout 30 --quiet \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source Documents/maciOS-terminal.log --destination "$OUT/maciOS-terminal.log" >/dev/null
    # Drop escape sequences and carriage returns, keep the text.
    /usr/bin/perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\e\][^\a]*(\a|\e\\)//g; s/\e[()][0-9A-Za-z]//g; s/\r(?!\n)/\n/g; s/\r//g' \
        "$OUT/maciOS-terminal.log" | tail -n "${1:-40}"
}

shot() {
    file="${1:-$OUT/screenshot.png}"
    xcrun devicectl device capture screenshot --device "$DEVICE_ID" --timeout 30 --quiet --destination "$file"
    echo "$file"
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
build | install | launch | jit | run | type | pull | screen | shot | stacks)
    # Here, not in a command substitution, so a failure stops the script.
    DEVICE=$(resolve_device)
    DEVICE_ID=${DEVICE% *}
    UDID=${DEVICE#* }
    ;;
esac
case "$command" in
devices) xcrun devicectl list devices ;;
build) build ;;
install) install_app ;;
launch) launch ;;
jit) jit "$@" ;;
run) build && install_app && launch ;;
type) type_text "$1" ;;
pull) pull ;;
screen) screen "$@" ;;
stacks) stacks ;;
shot) shot "$@" ;;
*) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
