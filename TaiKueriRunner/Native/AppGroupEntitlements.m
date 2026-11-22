#import "AppGroupEntitlements.h"
#import <TargetConditionals.h>
#import <dlfcn.h>

NSArray<NSString *> *runner_app_group_identifiers(void) {
#if TARGET_OS_IOS
    // SecTask is not exposed in the public iOS headers. Resolve it at runtime
    // so an unavailable API fails closed rather than preventing app launch.
    typedef CFTypeRef (*CreateTask)(CFAllocatorRef);
    typedef CFTypeRef (*CopyEntitlement)(CFTypeRef, CFStringRef, CFErrorRef *);
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW | RTLD_LOCAL);
    if (!security) return @[];
    CreateTask createTask = (CreateTask)dlsym(security, "SecTaskCreateFromSelf");
    CopyEntitlement copyEntitlement = (CopyEntitlement)dlsym(security, "SecTaskCopyValueForEntitlement");
    CFTypeRef task = createTask && copyEntitlement ? createTask(kCFAllocatorDefault) : NULL;
    CFTypeRef value = task ? copyEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL) : NULL;
    if (task) CFRelease(task);
    id claimed = value ? CFBridgingRelease(value) : nil;
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    if ([claimed isKindOfClass:NSArray.class]) {
        for (id group in claimed) {
            if ([group isKindOfClass:NSString.class] && [group length] > 0 && ![groups containsObject:group]) {
                [groups addObject:group];
            }
        }
    }
    dlclose(security);
    return [groups copy];
#else
    // Host tests never use real app-group containers.
    return @[];
#endif
}
