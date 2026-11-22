// Discovery approach adapted from kolbicz/WQFiles WQAccess.m, GPL-3.0-or-later.
// Search recent object IDs on our own data volume in short, bounded chunks.
#import "LaunchServicesDiscovery.h"
#include <TargetConditionals.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/fsgetpath.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <limits.h>

uint64_t TKLaunchServicesUpperBound(void) {
#if TARGET_OS_IOS
    NSString *probe = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"ls-probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    int fd = open(probe.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600);
    if (fd < 0) return 0;
    struct stat st;
    struct statfs volume, reference;
    BOOL valid = fstat(fd, &st) == 0 && fstatfs(fd, &volume) == 0 &&
        statfs(NSTemporaryDirectory().fileSystemRepresentation, &reference) == 0 &&
        memcmp(&volume.f_fsid, &reference.f_fsid, sizeof(fsid_t)) == 0;
    close(fd);
    unlink(probe.fileSystemRepresentation);
    return valid && st.st_ino > 0 && (uint64_t)st.st_ino <= UINT64_MAX - 100000 ? (uint64_t)st.st_ino + 100000 : 0;
#else
    return 0;
#endif
}

NSArray<NSString *> *TKLaunchServicesStoreCandidates(uint64_t first, uint64_t last) {
#if TARGET_OS_IOS
    if (first < 1 || last < first || last - first >= 4096) return nil;
    struct statfs volume;
    if (statfs(NSTemporaryDirectory().fileSystemRepresentation, &volume) != 0) return nil;
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    char buffer[PATH_MAX];
    for (uint64_t inode = last;; inode--) {
        if (fsgetpath(buffer, sizeof(buffer), &volume.f_fsid, inode) > 0) {
            const char *name = strrchr(buffer, '/');
            name = name ? name + 1 : buffer;
            size_t length = strlen(name);
            if (length > 33 && strncmp(name, "com.apple.LaunchServices-", 25) == 0 &&
                strcmp(name + length - 8, ".csstore") == 0 &&
                strstr(buffer, "/mobile/Containers/Data/InternalDaemon/") != NULL) {
                NSString *path = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
                if (path) [found addObject:path];
            }
        }
        if (inode == first) break;
    }
    return found;
#else
    return nil;
#endif
}
