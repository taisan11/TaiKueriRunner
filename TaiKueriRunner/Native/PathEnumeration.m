// Adapted from forcequitOS/worse_query/pathleak.m, GPL-3.0-or-later.
// Copyright (C) 2026 Taj C (forcequit). Changes: bounded, cancellable-by-chunk enumeration.
#import "PathEnumeration.h"
#include <sys/fsgetpath.h>
#include <sys/mount.h>
#include <limits.h>
#include <string.h>

NSArray<NSString *> *TKEnumeratePaths(NSString *path, uint64_t first, uint64_t last) {
    if (path.length == 0 || first < 1 || last < first) return nil;
    NSString *directory = path.stringByStandardizingPath;
    struct statfs volume;
    if (statfs(directory.fileSystemRepresentation, &volume) != 0) return nil;
    char prefix[PATH_MAX], buffer[PATH_MAX];
    if (![directory getFileSystemRepresentation:prefix maxLength:sizeof(prefix)]) return nil;
    size_t length = strlen(prefix);
    if (length == 1 && prefix[0] == '/') length = 0;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (uint64_t inode = first; inode <= last; inode++) {
        if (fsgetpath(buffer, sizeof(buffer), &volume.f_fsid, inode) <= 0) continue;
        if (strncmp(buffer, prefix, length) != 0 || buffer[length] != '/') continue;
        if (strchr(buffer + length + 1, '/')) continue;
        NSString *found = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
        if (found) [paths addObject:found];
    }
    return paths;
}
