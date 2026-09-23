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

    /// The "LaunchLogo" asset catalog image resource.
    static let launchLogo = DeveloperToolsSupport.ImageResource(name: "LaunchLogo", bundle: resourceBundle)

    /// The "M" asset catalog image resource.
    static let M = DeveloperToolsSupport.ImageResource(name: "M", bundle: resourceBundle)

    /// The "extremelysuccessfullogo" asset catalog image resource.
    static let extremelysuccessfullogo = DeveloperToolsSupport.ImageResource(name: "extremelysuccessfullogo", bundle: resourceBundle)

    /// The "githublogo" asset catalog image resource.
    static let githublogo = DeveloperToolsSupport.ImageResource(name: "githublogo", bundle: resourceBundle)

    /// The "iconPreviews" asset catalog resource namespace.
    enum IconPreviews {

        /// The "iconPreviews/AppIcon" asset catalog image resource.
        static let appIcon = DeveloperToolsSupport.ImageResource(name: "iconPreviews/AppIcon", bundle: resourceBundle)

        /// The "iconPreviews/BMW" asset catalog image resource.
        static let BMW = DeveloperToolsSupport.ImageResource(name: "iconPreviews/BMW", bundle: resourceBundle)

        /// The "iconPreviews/DC" asset catalog image resource.
        static let DC = DeveloperToolsSupport.ImageResource(name: "iconPreviews/DC", bundle: resourceBundle)

        /// The "iconPreviews/IBM" asset catalog image resource.
        static let IBM = DeveloperToolsSupport.ImageResource(name: "iconPreviews/IBM", bundle: resourceBundle)

        /// The "iconPreviews/M-stadt" asset catalog image resource.
        static let mStadt = DeveloperToolsSupport.ImageResource(name: "iconPreviews/M-stadt", bundle: resourceBundle)

        /// The "iconPreviews/MUC" asset catalog image resource.
        static let MUC = DeveloperToolsSupport.ImageResource(name: "iconPreviews/MUC", bundle: resourceBundle)

        /// The "iconPreviews/Mac" asset catalog image resource.
        static let mac = DeveloperToolsSupport.ImageResource(name: "iconPreviews/Mac", bundle: resourceBundle)

        /// The "iconPreviews/Magicalt" asset catalog image resource.
        static let magicalt = DeveloperToolsSupport.ImageResource(name: "iconPreviews/Magicalt", bundle: resourceBundle)

        /// The "iconPreviews/Magicneu" asset catalog image resource.
        static let magicneu = DeveloperToolsSupport.ImageResource(name: "iconPreviews/Magicneu", bundle: resourceBundle)

        /// The "iconPreviews/Moritz" asset catalog image resource.
        static let moritz = DeveloperToolsSupport.ImageResource(name: "iconPreviews/Moritz", bundle: resourceBundle)

        /// The "iconPreviews/NYC" asset catalog image resource.
        static let NYC = DeveloperToolsSupport.ImageResource(name: "iconPreviews/NYC", bundle: resourceBundle)

        /// The "iconPreviews/OG" asset catalog image resource.
        static let OG = DeveloperToolsSupport.ImageResource(name: "iconPreviews/OG", bundle: resourceBundle)

        /// The "iconPreviews/Pride" asset catalog image resource.
        static let pride = DeveloperToolsSupport.ImageResource(name: "iconPreviews/Pride", bundle: resourceBundle)

        /// The "iconPreviews/TLS2016" asset catalog image resource.
        static let TLS_2016 = DeveloperToolsSupport.ImageResource(name: "iconPreviews/TLS2016", bundle: resourceBundle)

        /// The "iconPreviews/TLSold" asset catalog image resource.
        static let tlSold = DeveloperToolsSupport.ImageResource(name: "iconPreviews/TLSold", bundle: resourceBundle)

        /// The "iconPreviews/barcelona" asset catalog image resource.
        static let barcelona = DeveloperToolsSupport.ImageResource(name: "iconPreviews/barcelona", bundle: resourceBundle)

        /// The "iconPreviews/berg" asset catalog image resource.
        static let berg = DeveloperToolsSupport.ImageResource(name: "iconPreviews/berg", bundle: resourceBundle)

        /// The "iconPreviews/doom" asset catalog image resource.
        static let doom = DeveloperToolsSupport.ImageResource(name: "iconPreviews/doom", bundle: resourceBundle)

        /// The "iconPreviews/impossible" asset catalog image resource.
        static let impossible = DeveloperToolsSupport.ImageResource(name: "iconPreviews/impossible", bundle: resourceBundle)

        /// The "iconPreviews/ironMaiden" asset catalog image resource.
        static let ironMaiden = DeveloperToolsSupport.ImageResource(name: "iconPreviews/ironMaiden", bundle: resourceBundle)

        /// The "iconPreviews/ironMaiden2" asset catalog image resource.
        static let ironMaiden2 = DeveloperToolsSupport.ImageResource(name: "iconPreviews/ironMaiden2", bundle: resourceBundle)

        /// The "iconPreviews/ironman" asset catalog image resource.
        static let ironman = DeveloperToolsSupport.ImageResource(name: "iconPreviews/ironman", bundle: resourceBundle)

        /// The "iconPreviews/macro" asset catalog image resource.
        static let macro = DeveloperToolsSupport.ImageResource(name: "iconPreviews/macro", bundle: resourceBundle)

        /// The "iconPreviews/madsen" asset catalog image resource.
        static let madsen = DeveloperToolsSupport.ImageResource(name: "iconPreviews/madsen", bundle: resourceBundle)

        /// The "iconPreviews/magnum" asset catalog image resource.
        static let magnum = DeveloperToolsSupport.ImageResource(name: "iconPreviews/magnum", bundle: resourceBundle)

        /// The "iconPreviews/mario" asset catalog image resource.
        static let mario = DeveloperToolsSupport.ImageResource(name: "iconPreviews/mario", bundle: resourceBundle)

        /// The "iconPreviews/mars" asset catalog image resource.
        static let mars = DeveloperToolsSupport.ImageResource(name: "iconPreviews/mars", bundle: resourceBundle)

        /// The "iconPreviews/maserati" asset catalog image resource.
        static let maserati = DeveloperToolsSupport.ImageResource(name: "iconPreviews/maserati", bundle: resourceBundle)

        /// The "iconPreviews/massi" asset catalog image resource.
        static let massi = DeveloperToolsSupport.ImageResource(name: "iconPreviews/massi", bundle: resourceBundle)

        /// The "iconPreviews/mclaren" asset catalog image resource.
        static let mclaren = DeveloperToolsSupport.ImageResource(name: "iconPreviews/mclaren", bundle: resourceBundle)

        /// The "iconPreviews/megadrive" asset catalog image resource.
        static let megadrive = DeveloperToolsSupport.ImageResource(name: "iconPreviews/megadrive", bundle: resourceBundle)

        /// The "iconPreviews/megadrive2" asset catalog image resource.
        static let megadrive2 = DeveloperToolsSupport.ImageResource(name: "iconPreviews/megadrive2", bundle: resourceBundle)

        /// The "iconPreviews/megaman" asset catalog image resource.
        static let megaman = DeveloperToolsSupport.ImageResource(name: "iconPreviews/megaman", bundle: resourceBundle)

        /// The "iconPreviews/megamanPerspective" asset catalog image resource.
        static let megamanPerspective = DeveloperToolsSupport.ImageResource(name: "iconPreviews/megamanPerspective", bundle: resourceBundle)

        /// The "iconPreviews/metallica" asset catalog image resource.
        static let metallica = DeveloperToolsSupport.ImageResource(name: "iconPreviews/metallica", bundle: resourceBundle)

        /// The "iconPreviews/metroMelbourne" asset catalog image resource.
        static let metroMelbourne = DeveloperToolsSupport.ImageResource(name: "iconPreviews/metroMelbourne", bundle: resourceBundle)

        /// The "iconPreviews/metroid" asset catalog image resource.
        static let metroid = DeveloperToolsSupport.ImageResource(name: "iconPreviews/metroid", bundle: resourceBundle)

        /// The "iconPreviews/milka" asset catalog image resource.
        static let milka = DeveloperToolsSupport.ImageResource(name: "iconPreviews/milka", bundle: resourceBundle)

        /// The "iconPreviews/mms" asset catalog image resource.
        static let mms = DeveloperToolsSupport.ImageResource(name: "iconPreviews/mms", bundle: resourceBundle)

        /// The "iconPreviews/monsterEnergy" asset catalog image resource.
        static let monsterEnergy = DeveloperToolsSupport.ImageResource(name: "iconPreviews/monsterEnergy", bundle: resourceBundle)

        /// The "iconPreviews/monsters" asset catalog image resource.
        static let monsters = DeveloperToolsSupport.ImageResource(name: "iconPreviews/monsters", bundle: resourceBundle)

        /// The "iconPreviews/montblanc" asset catalog image resource.
        static let montblanc = DeveloperToolsSupport.ImageResource(name: "iconPreviews/montblanc", bundle: resourceBundle)

        /// The "iconPreviews/mortal" asset catalog image resource.
        static let mortal = DeveloperToolsSupport.ImageResource(name: "iconPreviews/mortal", bundle: resourceBundle)

        /// The "iconPreviews/moto" asset catalog image resource.
        static let moto = DeveloperToolsSupport.ImageResource(name: "iconPreviews/moto", bundle: resourceBundle)

        /// The "iconPreviews/paris" asset catalog image resource.
        static let paris = DeveloperToolsSupport.ImageResource(name: "iconPreviews/paris", bundle: resourceBundle)

        /// The "iconPreviews/star" asset catalog image resource.
        static let star = DeveloperToolsSupport.ImageResource(name: "iconPreviews/star", bundle: resourceBundle)

        /// The "iconPreviews/sunshine" asset catalog image resource.
        static let sunshine = DeveloperToolsSupport.ImageResource(name: "iconPreviews/sunshine", bundle: resourceBundle)

        /// The "iconPreviews/sydney" asset catalog image resource.
        static let sydney = DeveloperToolsSupport.ImageResource(name: "iconPreviews/sydney", bundle: resourceBundle)

    }

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

    /// The "LaunchLogo" asset catalog image.
    static var launchLogo: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .launchLogo)
#else
        .init()
#endif
    }

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

    /// The "iconPreviews" asset catalog resource namespace.
    enum IconPreviews {

        /// The "iconPreviews/AppIcon" asset catalog image.
        static var appIcon: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.appIcon)
#else
            .init()
#endif
        }

        /// The "iconPreviews/BMW" asset catalog image.
        static var BMW: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.BMW)
#else
            .init()
#endif
        }

        /// The "iconPreviews/DC" asset catalog image.
        static var DC: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.DC)
#else
            .init()
#endif
        }

        /// The "iconPreviews/IBM" asset catalog image.
        static var IBM: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.IBM)
#else
            .init()
#endif
        }

        /// The "iconPreviews/M-stadt" asset catalog image.
        static var mStadt: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.mStadt)
#else
            .init()
#endif
        }

        /// The "iconPreviews/MUC" asset catalog image.
        static var MUC: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.MUC)
#else
            .init()
#endif
        }

        /// The "iconPreviews/Mac" asset catalog image.
        static var mac: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.mac)
#else
            .init()
#endif
        }

        /// The "iconPreviews/Magicalt" asset catalog image.
        static var magicalt: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.magicalt)
#else
            .init()
#endif
        }

        /// The "iconPreviews/Magicneu" asset catalog image.
        static var magicneu: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.magicneu)
#else
            .init()
#endif
        }

        /// The "iconPreviews/Moritz" asset catalog image.
        static var moritz: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.moritz)
#else
            .init()
#endif
        }

        /// The "iconPreviews/NYC" asset catalog image.
        static var NYC: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.NYC)
#else
            .init()
#endif
        }

        /// The "iconPreviews/OG" asset catalog image.
        static var OG: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.OG)
#else
            .init()
#endif
        }

        /// The "iconPreviews/Pride" asset catalog image.
        static var pride: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.pride)
#else
            .init()
#endif
        }

        /// The "iconPreviews/TLS2016" asset catalog image.
        static var TLS_2016: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.TLS_2016)
#else
            .init()
#endif
        }

        /// The "iconPreviews/TLSold" asset catalog image.
        static var tlSold: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.tlSold)
#else
            .init()
#endif
        }

        /// The "iconPreviews/barcelona" asset catalog image.
        static var barcelona: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.barcelona)
#else
            .init()
#endif
        }

        /// The "iconPreviews/berg" asset catalog image.
        static var berg: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.berg)
#else
            .init()
#endif
        }

        /// The "iconPreviews/doom" asset catalog image.
        static var doom: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.doom)
#else
            .init()
#endif
        }

        /// The "iconPreviews/impossible" asset catalog image.
        static var impossible: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.impossible)
#else
            .init()
#endif
        }

        /// The "iconPreviews/ironMaiden" asset catalog image.
        static var ironMaiden: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.ironMaiden)
#else
            .init()
#endif
        }

        /// The "iconPreviews/ironMaiden2" asset catalog image.
        static var ironMaiden2: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.ironMaiden2)
#else
            .init()
#endif
        }

        /// The "iconPreviews/ironman" asset catalog image.
        static var ironman: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.ironman)
#else
            .init()
#endif
        }

        /// The "iconPreviews/macro" asset catalog image.
        static var macro: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.macro)
#else
            .init()
#endif
        }

        /// The "iconPreviews/madsen" asset catalog image.
        static var madsen: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.madsen)
#else
            .init()
#endif
        }

        /// The "iconPreviews/magnum" asset catalog image.
        static var magnum: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.magnum)
#else
            .init()
#endif
        }

        /// The "iconPreviews/mario" asset catalog image.
        static var mario: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.mario)
#else
            .init()
#endif
        }

        /// The "iconPreviews/mars" asset catalog image.
        static var mars: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.mars)
#else
            .init()
#endif
        }

        /// The "iconPreviews/maserati" asset catalog image.
        static var maserati: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.maserati)
#else
            .init()
#endif
        }

        /// The "iconPreviews/massi" asset catalog image.
        static var massi: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.massi)
#else
            .init()
#endif
        }

        /// The "iconPreviews/mclaren" asset catalog image.
        static var mclaren: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.mclaren)
#else
            .init()
#endif
        }

        /// The "iconPreviews/megadrive" asset catalog image.
        static var megadrive: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.megadrive)
#else
            .init()
#endif
        }

        /// The "iconPreviews/megadrive2" asset catalog image.
        static var megadrive2: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.megadrive2)
#else
            .init()
#endif
        }

        /// The "iconPreviews/megaman" asset catalog image.
        static var megaman: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.megaman)
#else
            .init()
#endif
        }

        /// The "iconPreviews/megamanPerspective" asset catalog image.
        static var megamanPerspective: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.megamanPerspective)
#else
            .init()
#endif
        }

        /// The "iconPreviews/metallica" asset catalog image.
        static var metallica: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.metallica)
#else
            .init()
#endif
        }

        /// The "iconPreviews/metroMelbourne" asset catalog image.
        static var metroMelbourne: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.metroMelbourne)
#else
            .init()
#endif
        }

        /// The "iconPreviews/metroid" asset catalog image.
        static var metroid: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.metroid)
#else
            .init()
#endif
        }

        /// The "iconPreviews/milka" asset catalog image.
        static var milka: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.milka)
#else
            .init()
#endif
        }

        /// The "iconPreviews/mms" asset catalog image.
        static var mms: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.mms)
#else
            .init()
#endif
        }

        /// The "iconPreviews/monsterEnergy" asset catalog image.
        static var monsterEnergy: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.monsterEnergy)
#else
            .init()
#endif
        }

        /// The "iconPreviews/monsters" asset catalog image.
        static var monsters: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.monsters)
#else
            .init()
#endif
        }

        /// The "iconPreviews/montblanc" asset catalog image.
        static var montblanc: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.montblanc)
#else
            .init()
#endif
        }

        /// The "iconPreviews/mortal" asset catalog image.
        static var mortal: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.mortal)
#else
            .init()
#endif
        }

        /// The "iconPreviews/moto" asset catalog image.
        static var moto: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.moto)
#else
            .init()
#endif
        }

        /// The "iconPreviews/paris" asset catalog image.
        static var paris: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.paris)
#else
            .init()
#endif
        }

        /// The "iconPreviews/star" asset catalog image.
        static var star: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.star)
#else
            .init()
#endif
        }

        /// The "iconPreviews/sunshine" asset catalog image.
        static var sunshine: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.sunshine)
#else
            .init()
#endif
        }

        /// The "iconPreviews/sydney" asset catalog image.
        static var sydney: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
            .init(resource: .IconPreviews.sydney)
#else
            .init()
#endif
        }

    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    /// The "LaunchLogo" asset catalog image.
    static var launchLogo: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .launchLogo)
#else
        .init()
#endif
    }

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

    /// The "iconPreviews" asset catalog resource namespace.
    enum IconPreviews {

        /// The "iconPreviews/AppIcon" asset catalog image.
        static var appIcon: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.appIcon)
#else
            .init()
#endif
        }

        /// The "iconPreviews/BMW" asset catalog image.
        static var BMW: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.BMW)
#else
            .init()
#endif
        }

        /// The "iconPreviews/DC" asset catalog image.
        static var DC: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.DC)
#else
            .init()
#endif
        }

        /// The "iconPreviews/IBM" asset catalog image.
        static var IBM: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.IBM)
#else
            .init()
#endif
        }

        /// The "iconPreviews/M-stadt" asset catalog image.
        static var mStadt: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.mStadt)
#else
            .init()
#endif
        }

        /// The "iconPreviews/MUC" asset catalog image.
        static var MUC: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.MUC)
#else
            .init()
#endif
        }

        /// The "iconPreviews/Mac" asset catalog image.
        static var mac: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.mac)
#else
            .init()
#endif
        }

        /// The "iconPreviews/Magicalt" asset catalog image.
        static var magicalt: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.magicalt)
#else
            .init()
#endif
        }

        /// The "iconPreviews/Magicneu" asset catalog image.
        static var magicneu: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.magicneu)
#else
            .init()
#endif
        }

        /// The "iconPreviews/Moritz" asset catalog image.
        static var moritz: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.moritz)
#else
            .init()
#endif
        }

        /// The "iconPreviews/NYC" asset catalog image.
        static var NYC: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.NYC)
#else
            .init()
#endif
        }

        /// The "iconPreviews/OG" asset catalog image.
        static var OG: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.OG)
#else
            .init()
#endif
        }

        /// The "iconPreviews/Pride" asset catalog image.
        static var pride: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.pride)
#else
            .init()
#endif
        }

        /// The "iconPreviews/TLS2016" asset catalog image.
        static var TLS_2016: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.TLS_2016)
#else
            .init()
#endif
        }

        /// The "iconPreviews/TLSold" asset catalog image.
        static var tlSold: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.tlSold)
#else
            .init()
#endif
        }

        /// The "iconPreviews/barcelona" asset catalog image.
        static var barcelona: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.barcelona)
#else
            .init()
#endif
        }

        /// The "iconPreviews/berg" asset catalog image.
        static var berg: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.berg)
#else
            .init()
#endif
        }

        /// The "iconPreviews/doom" asset catalog image.
        static var doom: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.doom)
#else
            .init()
#endif
        }

        /// The "iconPreviews/impossible" asset catalog image.
        static var impossible: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.impossible)
#else
            .init()
#endif
        }

        /// The "iconPreviews/ironMaiden" asset catalog image.
        static var ironMaiden: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.ironMaiden)
#else
            .init()
#endif
        }

        /// The "iconPreviews/ironMaiden2" asset catalog image.
        static var ironMaiden2: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.ironMaiden2)
#else
            .init()
#endif
        }

        /// The "iconPreviews/ironman" asset catalog image.
        static var ironman: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.ironman)
#else
            .init()
#endif
        }

        /// The "iconPreviews/macro" asset catalog image.
        static var macro: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.macro)
#else
            .init()
#endif
        }

        /// The "iconPreviews/madsen" asset catalog image.
        static var madsen: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.madsen)
#else
            .init()
#endif
        }

        /// The "iconPreviews/magnum" asset catalog image.
        static var magnum: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.magnum)
#else
            .init()
#endif
        }

        /// The "iconPreviews/mario" asset catalog image.
        static var mario: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.mario)
#else
            .init()
#endif
        }

        /// The "iconPreviews/mars" asset catalog image.
        static var mars: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.mars)
#else
            .init()
#endif
        }

        /// The "iconPreviews/maserati" asset catalog image.
        static var maserati: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.maserati)
#else
            .init()
#endif
        }

        /// The "iconPreviews/massi" asset catalog image.
        static var massi: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.massi)
#else
            .init()
#endif
        }

        /// The "iconPreviews/mclaren" asset catalog image.
        static var mclaren: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.mclaren)
#else
            .init()
#endif
        }

        /// The "iconPreviews/megadrive" asset catalog image.
        static var megadrive: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.megadrive)
#else
            .init()
#endif
        }

        /// The "iconPreviews/megadrive2" asset catalog image.
        static var megadrive2: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.megadrive2)
#else
            .init()
#endif
        }

        /// The "iconPreviews/megaman" asset catalog image.
        static var megaman: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.megaman)
#else
            .init()
#endif
        }

        /// The "iconPreviews/megamanPerspective" asset catalog image.
        static var megamanPerspective: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.megamanPerspective)
#else
            .init()
#endif
        }

        /// The "iconPreviews/metallica" asset catalog image.
        static var metallica: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.metallica)
#else
            .init()
#endif
        }

        /// The "iconPreviews/metroMelbourne" asset catalog image.
        static var metroMelbourne: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.metroMelbourne)
#else
            .init()
#endif
        }

        /// The "iconPreviews/metroid" asset catalog image.
        static var metroid: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.metroid)
#else
            .init()
#endif
        }

        /// The "iconPreviews/milka" asset catalog image.
        static var milka: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.milka)
#else
            .init()
#endif
        }

        /// The "iconPreviews/mms" asset catalog image.
        static var mms: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.mms)
#else
            .init()
#endif
        }

        /// The "iconPreviews/monsterEnergy" asset catalog image.
        static var monsterEnergy: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.monsterEnergy)
#else
            .init()
#endif
        }

        /// The "iconPreviews/monsters" asset catalog image.
        static var monsters: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.monsters)
#else
            .init()
#endif
        }

        /// The "iconPreviews/montblanc" asset catalog image.
        static var montblanc: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.montblanc)
#else
            .init()
#endif
        }

        /// The "iconPreviews/mortal" asset catalog image.
        static var mortal: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.mortal)
#else
            .init()
#endif
        }

        /// The "iconPreviews/moto" asset catalog image.
        static var moto: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.moto)
#else
            .init()
#endif
        }

        /// The "iconPreviews/paris" asset catalog image.
        static var paris: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.paris)
#else
            .init()
#endif
        }

        /// The "iconPreviews/star" asset catalog image.
        static var star: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.star)
#else
            .init()
#endif
        }

        /// The "iconPreviews/sunshine" asset catalog image.
        static var sunshine: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.sunshine)
#else
            .init()
#endif
        }

        /// The "iconPreviews/sydney" asset catalog image.
        static var sydney: UIKit.UIImage {
#if !os(watchOS)
            .init(resource: .IconPreviews.sydney)
#else
            .init()
#endif
        }

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

