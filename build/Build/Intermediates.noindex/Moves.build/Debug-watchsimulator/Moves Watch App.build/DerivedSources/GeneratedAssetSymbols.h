#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"de.holgerkrupp.Moves.watchkitapp";

/// The "AccentColor" asset catalog color resource.
static NSString * const ACColorNameAccentColor AC_SWIFT_PRIVATE = @"AccentColor";

/// The "MovesMove" asset catalog color resource.
static NSString * const ACColorNameMovesMove AC_SWIFT_PRIVATE = @"MovesMove";

/// The "MovesPlace" asset catalog color resource.
static NSString * const ACColorNameMovesPlace AC_SWIFT_PRIVATE = @"MovesPlace";

/// The "MovesRouteTracking" asset catalog color resource.
static NSString * const ACColorNameMovesRouteTracking AC_SWIFT_PRIVATE = @"MovesRouteTracking";

/// The "MovesStart" asset catalog color resource.
static NSString * const ACColorNameMovesStart AC_SWIFT_PRIVATE = @"MovesStart";

/// The "MovesTransportAutomotive" asset catalog color resource.
static NSString * const ACColorNameMovesTransportAutomotive AC_SWIFT_PRIVATE = @"MovesTransportAutomotive";

/// The "MovesTransportBoat" asset catalog color resource.
static NSString * const ACColorNameMovesTransportBoat AC_SWIFT_PRIVATE = @"MovesTransportBoat";

/// The "MovesTransportCycling" asset catalog color resource.
static NSString * const ACColorNameMovesTransportCycling AC_SWIFT_PRIVATE = @"MovesTransportCycling";

/// The "MovesTransportPlane" asset catalog color resource.
static NSString * const ACColorNameMovesTransportPlane AC_SWIFT_PRIVATE = @"MovesTransportPlane";

/// The "MovesTransportTrain" asset catalog color resource.
static NSString * const ACColorNameMovesTransportTrain AC_SWIFT_PRIVATE = @"MovesTransportTrain";

/// The "MovesTransportWalking" asset catalog color resource.
static NSString * const ACColorNameMovesTransportWalking AC_SWIFT_PRIVATE = @"MovesTransportWalking";

/// The "MovesWidgetBackgroundBottom" asset catalog color resource.
static NSString * const ACColorNameMovesWidgetBackgroundBottom AC_SWIFT_PRIVATE = @"MovesWidgetBackgroundBottom";

/// The "MovesWidgetBackgroundTop" asset catalog color resource.
static NSString * const ACColorNameMovesWidgetBackgroundTop AC_SWIFT_PRIVATE = @"MovesWidgetBackgroundTop";

/// The "M" asset catalog image resource.
static NSString * const ACImageNameM AC_SWIFT_PRIVATE = @"M";

/// The "extremelysuccessfullogo" asset catalog image resource.
static NSString * const ACImageNameExtremelysuccessfullogo AC_SWIFT_PRIVATE = @"extremelysuccessfullogo";

/// The "githublogo" asset catalog image resource.
static NSString * const ACImageNameGithublogo AC_SWIFT_PRIVATE = @"githublogo";

#undef AC_SWIFT_PRIVATE
