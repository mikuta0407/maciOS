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
# Bumped when the archive is made differently, to remake it.
ARCHIVE_FORMAT=2
STAMP="${PROJECT_TEMP_DIR}/GuestRoot/archive-stamp"
if ! cmp -s "${BUILT}/.maciOS-root-version" "${RESOURCES}/GuestRoot.version" ||
   [ "$(cat "${STAMP}" 2>/dev/null)" != "${ARCHIVE_FORMAT}" ]; then
    rm -f "${RESOURCES}/GuestRoot.aar"
    # Owners, flags and extended attributes are this Mac's; on a device the
    # app may not set them, which fails the whole extraction.
    aa archive -d "${BUILT}" -o "${RESOURCES}/GuestRoot.aar" -exclude-field uid,gid,flg,xat,acl,ctm,btm
    cp "${BUILT}/.maciOS-root-version" "${RESOURCES}/GuestRoot.version"
    echo "${ARCHIVE_FORMAT}" > "${STAMP}"
fi
