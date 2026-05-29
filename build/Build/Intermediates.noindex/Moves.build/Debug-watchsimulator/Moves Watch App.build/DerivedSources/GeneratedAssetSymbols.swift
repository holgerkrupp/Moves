import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

    /// The "AccentColor" asset catalog color resource.
    static let accent = DeveloperToolsSupport.ColorResource(name: "AccentColor", bundle: resourceBundle)

    /// The "MovesMove" asset catalog color resource.
    static let movesMove = DeveloperToolsSupport.ColorResource(name: "MovesMove", bundle: resourceBundle)

    /// The "MovesPlace" asset catalog color resource.
    static let movesPlace = DeveloperToolsSupport.ColorResource(name: "MovesPlace", bundle: resourceBundle)

    /// The "MovesRouteTracking" asset catalog color resource.
    static let movesRouteTracking = DeveloperToolsSupport.ColorResource(name: "MovesRouteTracking", bundle: resourceBundle)

    /// The "MovesStart" asset catalog color resource.
    static let movesStart = DeveloperToolsSupport.ColorResource(name: "MovesStart", bundle: resourceBundle)

    /// The "MovesTransportAutomotive" asset catalog color resource.
    static let movesTransportAutomotive = DeveloperToolsSupport.ColorResource(name: "MovesTransportAutomotive", bundle: resourceBundle)

    /// The "MovesTransportBoat" asset catalog color resource.
    static let movesTransportBoat = DeveloperToolsSupport.ColorResource(name: "MovesTransportBoat", bundle: resourceBundle)

    /// The "MovesTransportCycling" asset catalog color resource.
    static let movesTransportCycling = DeveloperToolsSupport.ColorResource(name: "MovesTransportCycling", bundle: resourceBundle)

    /// The "MovesTransportPlane" asset catalog color resource.
    static let movesTransportPlane = DeveloperToolsSupport.ColorResource(name: "MovesTransportPlane", bundle: resourceBundle)

    /// The "MovesTransportTrain" asset catalog color resource.
    static let movesTransportTrain = DeveloperToolsSupport.ColorResource(name: "MovesTransportTrain", bundle: resourceBundle)

    /// The "MovesTransportWalking" asset catalog color resource.
    static let movesTransportWalking = DeveloperToolsSupport.ColorResource(name: "MovesTransportWalking", bundle: resourceBundle)

    /// The "MovesWidgetBackgroundBottom" asset catalog color resource.
    static let movesWidgetBackgroundBottom = DeveloperToolsSupport.ColorResource(name: "MovesWidgetBackgroundBottom", bundle: resourceBundle)

    /// The "MovesWidgetBackgroundTop" asset catalog color resource.
    static let movesWidgetBackgroundTop = DeveloperToolsSupport.ColorResource(name: "MovesWidgetBackgroundTop", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "M" asset catalog image resource.
    static let M = DeveloperToolsSupport.ImageResource(name: "M", bundle: resourceBundle)

    /// The "extremelysuccessfullogo" asset catalog image resource.
    static let extremelysuccessfullogo = DeveloperToolsSupport.ImageResource(name: "extremelysuccessfullogo", bundle: resourceBundle)

    /// The "githublogo" asset catalog image resource.
    static let githublogo = DeveloperToolsSupport.ImageResource(name: "githublogo", bundle: resourceBundle)

}

// MARK: - Color Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

    /// The "AccentColor" asset catalog color.
    static var accent: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .accent)
#else
        .init()
#endif
    }

    /// The "MovesMove" asset catalog color.
    static var movesMove: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .movesMove)
#else
        .init()
#endif
    }

    /// The "MovesPlace" asset catalog color.
    static var movesPlace: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .movesPlace)
#else
        .init()
#endif
    }

    /// The "MovesRouteTracking" asset catalog color.
    static var movesRouteTracking: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .movesRouteTracking)
#else
        .init()
#endif
    }

    /// The "MovesStart" asset catalog color.
    static var movesStart: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .movesStart)
#else
        .init()
#endif
    }

    /// The "MovesTransportAutomotive" asset catalog color.
    static var movesTransportAutomotive: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .movesTransportAutomotive)
#else
        .init()
#endif
    }

    /// The "MovesTransportBoat" asset catalog color.
    static var movesTransportBoat: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .movesTransportBoat)
#else
        .init()
#endif
    }

    /// The "MovesTransportCycling" asset catalog color.
    static var movesTransportCycling: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .movesTransportCycling)
#else
        .init()
#endif
    }

    /// The "MovesTransportPlane" asset catalog color.
    static var movesTransportPlane: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .movesTransportPlane)
#else
        .init()
#endif
    }

    /// The "MovesTransportTrain" asset catalog color.
    static var movesTransportTrain: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .movesTransportTrain)
#else
        .init()
#endif
    }

    /// The "MovesTransportWalking" asset catalog color.
    static var movesTransportWalking: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .movesTransportWalking)
#else
        .init()
#endif
    }

    /// The "MovesWidgetBackgroundBottom" asset catalog color.
    static var movesWidgetBackgroundBottom: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .movesWidgetBackgroundBottom)
#else
        .init()
#endif
    }

    /// The "MovesWidgetBackgroundTop" asset catalog color.
    static var movesWidgetBackgroundTop: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .movesWidgetBackgroundTop)
#else
        .init()
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    /// The "AccentColor" asset catalog color.
    static var accent: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .accent)
#else
        .init()
#endif
    }

    /// The "MovesMove" asset catalog color.
    static var movesMove: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .movesMove)
#else
        .init()
#endif
    }

    /// The "MovesPlace" asset catalog color.
    static var movesPlace: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .movesPlace)
#else
        .init()
#endif
    }

    /// The "MovesRouteTracking" asset catalog color.
    static var movesRouteTracking: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .movesRouteTracking)
#else
        .init()
#endif
    }

    /// The "MovesStart" asset catalog color.
    static var movesStart: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .movesStart)
#else
        .init()
#endif
    }

    /// The "MovesTransportAutomotive" asset catalog color.
    static var movesTransportAutomotive: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .movesTransportAutomotive)
#else
        .init()
#endif
    }

    /// The "MovesTransportBoat" asset catalog color.
    static var movesTransportBoat: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .movesTransportBoat)
#else
        .init()
#endif
    }

    /// The "MovesTransportCycling" asset catalog color.
    static var movesTransportCycling: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .movesTransportCycling)
#else
        .init()
#endif
    }

    /// The "MovesTransportPlane" asset catalog color.
    static var movesTransportPlane: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .movesTransportPlane)
#else
        .init()
#endif
    }

    /// The "MovesTransportTrain" asset catalog color.
    static var movesTransportTrain: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .movesTransportTrain)
#else
        .init()
#endif
    }

    /// The "MovesTransportWalking" asset catalog color.
    static var movesTransportWalking: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .movesTransportWalking)
#else
        .init()
#endif
    }

    /// The "MovesWidgetBackgroundBottom" asset catalog color.
    static var movesWidgetBackgroundBottom: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .movesWidgetBackgroundBottom)
#else
        .init()
#endif
    }

    /// The "MovesWidgetBackgroundTop" asset catalog color.
    static var movesWidgetBackgroundTop: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .movesWidgetBackgroundTop)
#else
        .init()
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

    /// The "AccentColor" asset catalog color.
    static var accent: SwiftUI.Color { .init(.accent) }

    /// The "MovesMove" asset catalog color.
    static var movesMove: SwiftUI.Color { .init(.movesMove) }

    /// The "MovesPlace" asset catalog color.
    static var movesPlace: SwiftUI.Color { .init(.movesPlace) }

    /// The "MovesRouteTracking" asset catalog color.
    static var movesRouteTracking: SwiftUI.Color { .init(.movesRouteTracking) }

    /// The "MovesStart" asset catalog color.
    static var movesStart: SwiftUI.Color { .init(.movesStart) }

    /// The "MovesTransportAutomotive" asset catalog color.
    static var movesTransportAutomotive: SwiftUI.Color { .init(.movesTransportAutomotive) }

    /// The "MovesTransportBoat" asset catalog color.
    static var movesTransportBoat: SwiftUI.Color { .init(.movesTransportBoat) }

    /// The "MovesTransportCycling" asset catalog color.
    static var movesTransportCycling: SwiftUI.Color { .init(.movesTransportCycling) }

    /// The "MovesTransportPlane" asset catalog color.
    static var movesTransportPlane: SwiftUI.Color { .init(.movesTransportPlane) }

    /// The "MovesTransportTrain" asset catalog color.
    static var movesTransportTrain: SwiftUI.Color { .init(.movesTransportTrain) }

    /// The "MovesTransportWalking" asset catalog color.
    static var movesTransportWalking: SwiftUI.Color { .init(.movesTransportWalking) }

    /// The "MovesWidgetBackgroundBottom" asset catalog color.
    static var movesWidgetBackgroundBottom: SwiftUI.Color { .init(.movesWidgetBackgroundBottom) }

    /// The "MovesWidgetBackgroundTop" asset catalog color.
    static var movesWidgetBackgroundTop: SwiftUI.Color { .init(.movesWidgetBackgroundTop) }

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

    /// The "AccentColor" asset catalog color.
    static var accent: SwiftUI.Color { .init(.accent) }

    /// The "MovesMove" asset catalog color.
    static var movesMove: SwiftUI.Color { .init(.movesMove) }

    /// The "MovesPlace" asset catalog color.
    static var movesPlace: SwiftUI.Color { .init(.movesPlace) }

    /// The "MovesRouteTracking" asset catalog color.
    static var movesRouteTracking: SwiftUI.Color { .init(.movesRouteTracking) }

    /// The "MovesStart" asset catalog color.
    static var movesStart: SwiftUI.Color { .init(.movesStart) }

    /// The "MovesTransportAutomotive" asset catalog color.
    static var movesTransportAutomotive: SwiftUI.Color { .init(.movesTransportAutomotive) }

    /// The "MovesTransportBoat" asset catalog color.
    static var movesTransportBoat: SwiftUI.Color { .init(.movesTransportBoat) }

    /// The "MovesTransportCycling" asset catalog color.
    static var movesTransportCycling: SwiftUI.Color { .init(.movesTransportCycling) }

    /// The "MovesTransportPlane" asset catalog color.
    static var movesTransportPlane: SwiftUI.Color { .init(.movesTransportPlane) }

    /// The "MovesTransportTrain" asset catalog color.
    static var movesTransportTrain: SwiftUI.Color { .init(.movesTransportTrain) }

    /// The "MovesTransportWalking" asset catalog color.
    static var movesTransportWalking: SwiftUI.Color { .init(.movesTransportWalking) }

    /// The "MovesWidgetBackgroundBottom" asset catalog color.
    static var movesWidgetBackgroundBottom: SwiftUI.Color { .init(.movesWidgetBackgroundBottom) }

    /// The "MovesWidgetBackgroundTop" asset catalog color.
    static var movesWidgetBackgroundTop: SwiftUI.Color { .init(.movesWidgetBackgroundTop) }

}
#endif

// MARK: - Image Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    /// The "M" asset catalog image.
    static var M: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .M)
#else
        .init()
#endif
    }

    /// The "extremelysuccessfullogo" asset catalog image.
    static var extremelysuccessfullogo: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .extremelysuccessfullogo)
#else
        .init()
#endif
    }

    /// The "githublogo" asset catalog image.
    static var githublogo: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .githublogo)
#else
        .init()
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    /// The "M" asset catalog image.
    static var M: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .M)
#else
        .init()
#endif
    }

    /// The "extremelysuccessfullogo" asset catalog image.
    static var extremelysuccessfullogo: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .extremelysuccessfullogo)
#else
        .init()
#endif
    }

    /// The "githublogo" asset catalog image.
    static var githublogo: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .githublogo)
#else
        .init()
#endif
    }

}
#endif

// MARK: - Thinnable Asset Support -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ColorResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if AppKit.NSColor(named: NSColor.Name(thinnableName), bundle: bundle) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIColor(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
#if !targetEnvironment(macCatalyst)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}
#endif

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ImageResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if bundle.image(forResource: NSImage.Name(thinnableName)) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIImage(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !targetEnvironment(macCatalyst)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

