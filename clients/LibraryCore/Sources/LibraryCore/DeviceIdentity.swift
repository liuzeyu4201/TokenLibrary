import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum DeviceIdentity {
    public static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "mac"
        #else
        return "swift"
        #endif
    }

    public static var name: String {
        #if os(iOS)
        let raw = UIDevice.current.name
        #elseif os(macOS)
        let raw = Host.current().localizedName ?? "Mac"
        #else
        let raw = "client"
        #endif
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return platform == "ios" ? "iPhone" : "Mac" }
        return String(trimmed.prefix(40))
    }
}
