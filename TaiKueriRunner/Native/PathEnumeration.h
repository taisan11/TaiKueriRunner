#import <Foundation/Foundation.h>
// Bounded chunks allow Swift to yield and check cancellation between calls.
NSArray<NSString *> * _Nullable TKEnumeratePaths(NSString * _Nonnull path, uint64_t first, uint64_t last);
