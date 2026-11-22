#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Reads the running process, not the pre-signing Info.plist or profile.
NSArray<NSString *> *runner_app_group_identifiers(void);
NS_ASSUME_NONNULL_END
