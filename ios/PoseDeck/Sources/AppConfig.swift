import Foundation

/// Static app configuration resolved from the bundle's Info.plist.
///
/// The API base URL is injected at build time from `Config/Config.xcconfig`
/// (`API_BASE_URL`) → Info.plist key `APIBaseURL` → read here. This keeps the
/// dev/prod endpoint out of source and lets the integration agent point the
/// shell at any backend without code changes.
enum AppConfig {
    /// Fallback used if the Info.plist value is missing or malformed.
    static let defaultBaseURLString = "http://localhost:8090"

    /// Raw API base URL string from Info.plist, falling back to the default.
    static var apiBaseURLString: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return defaultBaseURLString
        }
        return raw
    }

    /// Parsed API base URL, falling back to the default if parsing fails.
    static var apiBaseURL: URL {
        URL(string: apiBaseURLString) ?? URL(string: defaultBaseURLString)!
    }
}
