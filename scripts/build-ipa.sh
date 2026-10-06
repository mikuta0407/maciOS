#!/bin/sh
# Builds an unsigned maciOS.ipa, with the guest root, for sideloading
# (AltStore, SideStore, LiveContainer, ...), which sign it on install.
#
#   scripts/build-ipa.sh [OUTPUT_DIR]   (default: build)
set -eu

cd "$(dirname "$0")/.."
OUT="${1:-build}"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

xcodebuild -project maciOS.xcodeproj -scheme maciOS -configuration Release \
    -sdk iphoneos -destination generic/platform=iOS \
    -derivedDataPath "$OUT/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

APP="$OUT/DerivedData/Build/Products/Release-iphoneos/maciOS.app"
if [ ! -f "$APP/GuestRoot.aar" ]; then
    echo "error: the app has no guest root; building it needs Homebrew (see GuestRoot/build-root.sh)" >&2
    exit 1
fi

rm -rf "$OUT/Payload" "$OUT/maciOS.ipa"
mkdir "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && zip -qry maciOS.ipa Payload)
rm -rf "$OUT/Payload"
echo "$OUT/maciOS.ipa"
