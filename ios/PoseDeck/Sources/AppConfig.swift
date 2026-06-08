import Foundation

/// Static app configuration resolving the API base URL.
///
/// Precedence (mirrors the web client): a user-entered URL persisted in
/// `UserDefaults` (set at login, item 4) → the build-time value injected from
/// `Config/Config.xcconfig` (`API_BASE_URL`) → Info.plist key `APIBaseURL` → a
/// local default. The login override lets one built app point at any deployment
/// without rebuilding, while the build-time value remains the default.
enum AppConfig {
    /// Fallback used if no override / Info.plist value is usable.
    static let defaultBaseURLString = "http://localhost:8090"

    /// `UserDefaults` key holding a user-entered backend URL. Non-secret (it's a
    /// deployment pointer the user types), so `UserDefaults` rather than the
    /// Keychain — and it must be readable synchronously at app init to build the
    /// client before any view renders.
    static let storedBaseURLKey = "posedeck.backendURL"

    /// The build-time backend URL from Info.plist, or `nil` if unset/blank.
    static var buildTimeBaseURLString: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return raw
    }

    /// A user-entered override, if one has been persisted and is non-blank.
    static var storedBaseURLString: String? {
        let raw = UserDefaults.standard.string(forKey: storedBaseURLKey)
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    /// Persist (or clear) the user-entered backend URL override. Passing a blank
    /// string clears it, falling back to the build-time/default URL.
    static func setStoredBaseURLString(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: storedBaseURLKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: storedBaseURLKey)
        }
    }

    /// Resolved raw API base URL string, applying the override precedence.
    static var apiBaseURLString: String {
        storedBaseURLString ?? buildTimeBaseURLString ?? defaultBaseURLString
    }

    /// Parsed API base URL, falling back to the default if parsing fails.
    static var apiBaseURL: URL {
        URL(string: apiBaseURLString) ?? URL(string: defaultBaseURLString)!
    }
}
