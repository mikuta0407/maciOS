#!/bin/sh
# Builds the guest root (GuestRoot/build-root.sh) and puts it in the app as
# GuestRoot.aar, which the app installs as Documents/root. One archive keeps
# its symlinks and file modes, which app installation and sideloading tools
# do not preserve. Building it needs Homebrew on this Mac; without it the app
# is built without one.
set -eu

BUILT="${PROJECT_TEMP_DIR}/GuestRoot/root"
RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

if ! "${SRCROOT}/GuestRoot/build-root.sh" "${BUILT}"; then
    echo "warning: Could not build the guest root; maciOS is built without one (see GuestRoot/build-root.sh)"
    rm -f "${RESOURCES}/GuestRoot.aar" "${RESOURCES}/GuestRoot.version"
    exit 0
fi
rm -rf "${RESOURCES}/GuestRoot"
if ! cmp -s "${BUILT}/.maciOS-root-version" "${RESOURCES}/GuestRoot.version"; then
    rm -f "${RESOURCES}/GuestRoot.aar"
    aa archive -d "${BUILT}" -o "${RESOURCES}/GuestRoot.aar"
    cp "${BUILT}/.maciOS-root-version" "${RESOURCES}/GuestRoot.version"
fi
