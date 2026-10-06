#!/bin/sh
# Builds the guest root (GuestRoot/build-root.sh) and puts it in the app as
# the GuestRoot resource, which the app installs as Documents/root. Building
# it needs Homebrew on this Mac; without it the app is built without one.
set -eu

BUILT="${PROJECT_TEMP_DIR}/GuestRoot/root"
DST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/GuestRoot"

if ! "${SRCROOT}/GuestRoot/build-root.sh" "${BUILT}"; then
    echo "warning: Could not build the guest root; maciOS is built without one (see GuestRoot/build-root.sh)"
    rm -rf "${DST}"
    exit 0
fi
mkdir -p "${DST}"
rsync -a --delete "${BUILT}/" "${DST}/"
