#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"de.holgerkrupp.Moves";

/// The "AccentColor" asset catalog color resource.
static NSString * const ACColorNameAccentColor AC_SWIFT_PRIVATE = @"AccentColor";

/// The "extremelysuccessfullogo" asset catalog image resource.
static NSString * const ACImageNameExtremelysuccessfullogo AC_SWIFT_PRIVATE = @"extremelysuccessfullogo";

/// The "githublogo" asset catalog image resource.
static NSString * const ACImageNameGithublogo AC_SWIFT_PRIVATE = @"githublogo";

#undef AC_SWIFT_PRIVATE
