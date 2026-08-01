#import "CGVirtualDisplayPrivate.h"

#include <sys/file.h>
#include <sys/stat.h>

static inline int ODLockFile(int descriptor) {
    return flock(descriptor, LOCK_EX);
}

static inline int ODUnlockFile(int descriptor) {
    return flock(descriptor, LOCK_UN);
}

static inline bool ODFileDescriptorPointsToPath(int descriptor, const char *path) {
    struct stat descriptorInfo;
    struct stat pathInfo;
    return fstat(descriptor, &descriptorInfo) == 0
        && stat(path, &pathInfo) == 0
        && descriptorInfo.st_dev == pathInfo.st_dev
        && descriptorInfo.st_ino == pathInfo.st_ino;
}
