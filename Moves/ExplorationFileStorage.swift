import Foundation

enum ExplorationFileStorage {
    static var atomicWriteOptions: Data.WritingOptions {
#if os(iOS) || os(tvOS) || os(watchOS)
        [.atomic, .completeFileProtection]
#else
        [.atomic]
#endif
    }

    static var protectedWriteOptions: Data.WritingOptions {
#if os(iOS) || os(tvOS) || os(watchOS)
        [.completeFileProtection]
#else
        []
#endif
    }
}
