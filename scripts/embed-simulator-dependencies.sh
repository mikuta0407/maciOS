#!/bin/sh
# The prebuilt dependencies in maciOS/Core/Dependencies are built for the iOS
# device platform, which the simulator's dyld refuses to load. For simulator
# builds they are excluded from linking/embedding (EXCLUDED_SOURCE_FILE_NAMES)
# and this script embeds copies retargeted to the iOS simulator platform.
set -eu

case "${PLATFORM_NAME}" in
    iphonesimulator) ;;
    *) exit 0 ;;
esac

SRC="${SRCROOT}/maciOS/Core/Dependencies"
DST="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "${DST}"

retarget() {
    bin="$1"
    if xcrun vtool -show-build "${bin}" 2>/dev/null | grep -q "platform IOS$"; then
        xcrun vtool -set-build-version iossim 15.0 "${SDK_VERSION}" -replace -output "${bin}" "${bin}"
    fi
    codesign --force --sign - --timestamp=none "${bin}"
}

for dylib in "${SRC}"/*.dylib; do
    name=$(basename "${dylib}")
    cp -f "${dylib}" "${DST}/${name}"
    retarget "${DST}/${name}"
done

for framework in "${SRC}"/*.framework; do
    name=$(basename "${framework}" .framework)
    rm -rf "${DST}/${name}.framework"
    cp -R "${framework}" "${DST}/"
    rm -rf "${DST}/${name}.framework/Headers" "${DST}/${name}.framework/Modules"
    retarget "${DST}/${name}.framework/${name}"
done
