#!/bin/bash
# Builds the guest root: the stand-in for /bin, /usr and /etc that guest
# programs see (see maciOS/Core/Hooks/GuestRoot.h). It holds command-line
# tools from Homebrew bottles, small tools from tools/ and the files in
# overlay/. Runs on a Mac with Homebrew installed.
#
#   build-root.sh OUTPUT [WORK]
#
# WORK (default: OUTPUT.work) keeps the extracted bottles between runs.
# OUTPUT/.maciOS-root-version identifies what was built; when it is already
# up to date, nothing is done. OUTPUT/.maciOS-root-executables lists the
# files to make executable.
set -euo pipefail

# Formulae whose programs make up the root. Their dependencies come along.
FORMULAE=(bash uutils-coreutils curl libarchive gnu-sed grep gzip findutils gnu-tar)

HERE=$(cd "$(dirname "$0")" && pwd)
OUT="${1:?usage: build-root.sh OUTPUT [WORK]}"
WORK="${2:-$OUT.work}"

BREW=$(command -v brew || true)
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -n "$BREW" ] || { [ -x "$candidate" ] && BREW="$candidate"; }
done
[ -n "$BREW" ] || { echo "build-root.sh: Homebrew is required" >&2; exit 1; }
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1

ALL=$( { printf '%s\n' "${FORMULAE[@]}"; "$BREW" deps --union "${FORMULAE[@]}"; } | sort -u)
# The root changes with the bottles' versions and with this directory.
VERSION=$( {
    "$BREW" info --json=v2 $ALL | /usr/bin/python3 -c 'import json, sys
for f in json.load(sys.stdin)["formulae"]: print(f["name"], f["versions"]["stable"], f["revision"])'
    cd "$HERE" && find . -type f ! -name '.*' | sort | xargs shasum
} | shasum | cut -d' ' -f1)
if [ "$(cat "$OUT/.maciOS-root-version" 2>/dev/null)" = "$VERSION" ]; then
    exit 0
fi

# Bottles, extracted to WORK/bottles/<formula>/<version>.
mkdir -p "$WORK/bottles"
"$BREW" fetch --force-bottle --quiet $ALL >/dev/null
B="$WORK/bottles"
rm -rf "$B"/*
for f in $ALL; do
    tar -xzf "$("$BREW" --cache --force-bottle "$f")" -C "$B"
done

ROOT="$WORK/root"
rm -rf "$ROOT"
mkdir -p "$ROOT"/{bin,sbin,usr/bin,usr/sbin,usr/local/bin,usr/local/lib,usr/local/libexec,etc}
for d in "$B"/*/*/; do
    [ -d "$d/lib" ] && find "$d/lib" -maxdepth 1 -name '*.dylib' -exec cp -a {} "$ROOT/usr/local/lib/" \;
    [ -d "$d/bin" ] && cp -a "$d"/bin/* "$ROOT/usr/local/bin/"
done
cp -a "$B"/uutils-coreutils/*/libexec/uu-coreutils "$ROOT/usr/local/libexec/"
chmod -R u+w "$ROOT"

# Point Homebrew's placeholders at the flattened layout.
fix() {
    local file="$1" relative="$2" dep id
    file "$file" | grep -q Mach-O || return 0
    for dep in $(otool -L "$file" | tail -n +2 | awk '{print $1}' | grep '@@HOMEBREW' || true); do
        install_name_tool -change "$dep" "@loader_path/$relative$(basename "$dep")" "$file" 2>/dev/null
    done
    id=$(otool -D "$file" | tail -n +2)
    case "$id" in @@HOMEBREW*) install_name_tool -id "@rpath/$(basename "$id")" "$file" 2>/dev/null ;; esac
    codesign -f -s - "$file" 2>/dev/null
}
for f in "$ROOT"/usr/local/lib/*.dylib; do [ -L "$f" ] || fix "$f" ""; done
for f in "$ROOT"/usr/local/bin/*; do [ -L "$f" ] || fix "$f" "../lib/"; done
for f in "$ROOT"/usr/local/libexec/uu-coreutils/*; do [ -L "$f" ] || fix "$f" ""; done

# The programs under their usual names.
for u in $(ls "$B"/uutils-coreutils/*/libexec/uubin); do
    ln -sf ../local/bin/uu-coreutils "$ROOT/usr/bin/$u"
    ln -sf ../usr/local/bin/uu-coreutils "$ROOT/bin/$u"
done
ln -sf ../usr/local/bin/bash "$ROOT/bin/bash"
ln -sf ../usr/local/bin/bash "$ROOT/bin/sh"
ln -sf ../usr/local/bin/gsed "$ROOT/bin/sed"
# GNU tar's child processes do long work after fork(), which guests cannot
# do yet, so tar is bsdtar.
for pair in gsed:sed ggrep:grep gegrep:egrep gfgrep:fgrep bsdtar:tar gtar:gtar bsdcat:bsdcat \
            bsdunzip:unzip gfind:find gxargs:xargs gzip:gzip gunzip:gunzip zcat:zcat curl:curl; do
    ln -sf "../local/bin/${pair%%:*}" "$ROOT/usr/bin/${pair##*:}"
done

# Tools macOS has and programs (Homebrew) expect.
cc() { clang -arch arm64 -mmacosx-version-min=14.0 -w "$@"; }
cc -Wl,-headerpad,0x1000 -o "$ROOT/usr/bin/lockf" "$HERE/tools/lockf.c"
cc -Wl,-headerpad,0x1000 -o "$ROOT/usr/sbin/sysctl" "$HERE/tools/sysctl.c"
cc -Wl,-headerpad,0x1000 -o "$ROOT/usr/bin/getconf" "$HERE/tools/getconf.c"
# Stand-ins for system libraries iOS lacks.
LDAP=System/Library/Frameworks/LDAP.framework/Versions/A
mkdir -p "$ROOT/$LDAP"
cc -dynamiclib -install_name "/$LDAP/LDAP" -o "$ROOT/$LDAP/LDAP" "$HERE/tools/ldap-stub.c"

cp -R "$HERE/overlay/" "$ROOT/"

# Installing the app drops the files' modes, so the executable ones are listed.
(cd "$ROOT" && find . -type f -perm -u+x | sed 's|^\./||' | sort) > "$ROOT/.maciOS-root-executables"
echo "$VERSION" > "$ROOT/.maciOS-root-version"
rm -rf "$OUT"
mv "$ROOT" "$OUT"
