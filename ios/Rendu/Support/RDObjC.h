#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the reason of any Objective-C exception it raised,
/// or nil. HealthKit reports some caller errors — share access to a read-only
/// type, a malformed unit string, an incompatible unit — only by raising,
/// which Swift cannot catch.
NSString *_Nullable RDCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
