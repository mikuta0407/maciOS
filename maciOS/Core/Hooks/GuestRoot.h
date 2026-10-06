//
//  GuestRoot.h
//  maciOS
//
//  A directory that stands in for the system's /bin, /usr and /etc, so guest
//  programs find the tools they expect there (`#!/bin/bash`, /usr/bin/env).
//  A path is redirected when the entry exists under the root, and always
//  for the directories of programs (/bin, /usr/bin, ...), so guests see only
//  the root's; everything else still refers to the real file system.
//

#import <Foundation/Foundation.h>
#include <limits.h>

NS_ASSUME_NONNULL_BEGIN

void guest_root_set(const char *path);

/// `path` as a guest sees it: `buffer`, holding the path under the root, if
/// the root has that entry, otherwise `path` itself.
const char *guest_root_map(const char *path, char buffer[_Nonnull PATH_MAX]);

NS_ASSUME_NONNULL_END
