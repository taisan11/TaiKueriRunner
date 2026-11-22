#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Device-only discovery. macOS implementations do not scan inodes.
uint64_t TKLaunchServicesUpperBound(void);
NSArray<NSString *> * _Nullable TKLaunchServicesStoreCandidates(uint64_t first, uint64_t last);
NS_ASSUME_NONNULL_END
