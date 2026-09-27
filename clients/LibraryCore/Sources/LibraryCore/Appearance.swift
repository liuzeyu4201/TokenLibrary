import Foundation

/// In-app 设置 labels. Raw values are exactly what the UI shows.
public enum AppearanceStyle: String, CaseIterable, Sendable, Equatable {
    case day = "白天"
    case night = "夜晚"
    case system = "跟随系统"

    public static let allLabels = ["白天", "夜晚", "跟随系统"]

    /// light / dark / unspecified (follow OS)
    public var mappedScheme: String {
        switch self {
        case .day: return "light"
        case .night: return "dark"
        case .system: return "unspecified"
        }
    }
}

public final class AppearanceStore: @unchecked Sendable {
    public static let key = "appearanceStyle"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public convenience init(suiteName: String) {
        let d = UserDefaults(suiteName: suiteName) ?? UserDefaults()
        self.init(defaults: d)
    }

    public var style: AppearanceStyle {
        get {
            if let raw = defaults.string(forKey: Self.key), let s = AppearanceStyle(rawValue: raw) {
                return s
            }
            return .system
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }
}
