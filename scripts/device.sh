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
#   type <text>      type text into the terminal (\n for Return)
#   pull             fetch Documents/maciOS-trace.log and maciOS.log
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
    xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing \
        --quiet --json-output "$OUT/launch.json" "$BUNDLE_ID" >/dev/null
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
    nohup xcrun lldb --batch -o "command script import scripts/maciOS_jit.py" \
        -o "maciOS_jit $DEVICE_ID $pid" >"$OUT/jit.log" 2>&1 &
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
    xcrun devicectl device copy to --device "$DEVICE_ID" --quiet \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source "$OUT/input" --destination Documents/.maciOS-input
}

pull() {
    for file in maciOS-trace.log maciOS.log; do
        xcrun devicectl device copy from --device "$DEVICE_ID" --quiet \
            --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
            --source "Documents/$file" --destination "$OUT/$file" &&
            echo "$OUT/$file"
    done
}

shot() {
    file="${1:-$OUT/screenshot.png}"
    xcrun devicectl device capture screenshot --device "$DEVICE_ID" --quiet --destination "$file"
    echo "$file"
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
build | install | launch | jit | run | type | pull | shot)
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
shot) shot "$@" ;;
*) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
