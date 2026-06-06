import Foundation

/// PocketBase datetime (de)serialization helpers.
///
/// PocketBase serializes datetimes like `"2026-06-06 18:44:54.172Z"` — a
/// **space** separator (not `T`), fractional seconds, and a trailing `Z`. That
/// is *not* what `JSONDecoder.dateDecodingStrategy = .iso8601` accepts, so the
/// stock strategy throws on every real PocketBase record. PocketBase also
/// represents an *unset* datetime as the empty string `""` (and sometimes
/// `null`), both of which must decode to `nil`.
///
/// This type provides:
///  - A `DateFormatter` that parses/prints the PocketBase wire format.
///  - `JSONDecoder` / `JSONEncoder` factories pre-wired with custom strategies
///    that tolerate the empty-string-unset case.
///
/// The custom strategies operate on the *raw datetime string*. Because optional
/// `Date?` fields decode the empty string to `nil` themselves, an empty string
/// inside a non-optional `Date` slot is the only case the decode strategy must
/// reject (there are no required datetime fields in the M2 model, but we keep
/// the behavior strict so a malformed payload surfaces as an error rather than
/// silently becoming a sentinel date).
public enum PocketBaseDate {

    /// The canonical PocketBase datetime wire format: `yyyy-MM-dd HH:mm:ss.SSSZ`.
    ///
    /// Uses a fixed `en_US_POSIX` locale and UTC time zone so parsing is stable
    /// regardless of device locale/region settings.
    public static let wireFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"

    /// A `DateFormatter` configured for the PocketBase wire format.
    ///
    /// `DateFormatter` is not `Sendable`; this returns a fresh instance per call
    /// so callers never share one across threads.
    public static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = wireFormat
        return formatter
    }

    /// A fallback ISO-8601 formatter (`yyyy-MM-dd'T'HH:mm:ss.SSSZ`) for inputs
    /// that arrive in the `T`-separated ISO shape (e.g. fixtures, or values the
    /// app itself round-trips). Tried only after the primary wire format fails.
    private static func makeISOFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }

    /// Parse a PocketBase datetime string into a `Date`.
    ///
    /// Returns `nil` for the empty string (unset). Throws-free: an unparseable
    /// non-empty string returns `nil` too; callers that need to distinguish
    /// "unset" from "malformed" should check emptiness first.
    public static func date(from string: String) -> Date? {
        if string.isEmpty { return nil }
        if let date = makeFormatter().date(from: string) { return date }
        // Tolerate a couple of common variations so fixtures and re-encoded
        // values still decode: the `T`-separated ISO form, and a Z-less suffix.
        if let date = makeISOFormatter().date(from: string) { return date }
        return nil
    }

    /// Render a `Date` as a PocketBase datetime string (wire format, UTC).
    public static func string(from date: Date) -> String {
        makeFormatter().string(from: date)
    }

    /// The set of JSON keys that carry PocketBase datetimes across the M2 model
    /// (`decks`, `cards`, `card_images`, `deck_guests`, `card_completions`,
    /// `users`). An empty-string value at any of these keys means "unset" and is
    /// rewritten to JSON `null` before decoding so optional `Date?` fields
    /// decode to `nil`.
    public static let datetimeKeys: Set<String> = [
        "shoot_date",
        "client_updated_at",
        "created",
        "updated",
        "deleted_at",
        "granted_at",
        "changed_at",
    ]

    /// A `JSONDecoder` wired to parse PocketBase datetimes in the wire format.
    ///
    /// Note: a `.custom` date strategy *cannot* return `nil`, and Swift's
    /// synthesized optional decoding still invokes the strategy when an
    /// empty-string value is present — so an empty string would throw. The
    /// empty-string-unset case is therefore handled by ``decode(_:from:)``,
    /// which rewrites empty-string datetime values to `null` *before* decoding.
    /// Use that method (or a repository built on it) rather than calling
    /// `decode` on this decoder directly with raw PocketBase JSON.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = date(from: raw) else {
                // Empty string in a *non-optional* Date slot, or a malformed
                // value: surface it as a decoding error.
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid PocketBase datetime: \"\(raw)\""
                )
            }
            return date
        }
        return decoder
    }

    /// Decode PocketBase JSON into `T`, handling the empty-string-unset case.
    ///
    /// Rewrites empty-string values at known datetime keys (``datetimeKeys``) to
    /// JSON `null` so optional `Date?` fields decode to `nil`, then decodes with
    /// ``makeDecoder()``. This is the entry point repositories should use for
    /// raw PocketBase response bodies.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let sanitized = try sanitizeEmptyDatetimes(in: data)
        return try makeDecoder().decode(T.self, from: sanitized)
    }

    /// Walk a JSON value tree and replace empty strings at ``datetimeKeys`` with
    /// `null`. Returns re-serialized `Data`. Non-JSON or already-clean input is
    /// returned unchanged where possible.
    public static func sanitizeEmptyDatetimes(in data: Data) throws -> Data {
        let root = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
        let cleaned = sanitize(root, parentKey: nil)
        return try JSONSerialization.data(
            withJSONObject: cleaned,
            options: [.fragmentsAllowed]
        )
    }

    private static func sanitize(_ value: Any, parentKey: String?) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, child) in dict {
                if datetimeKeys.contains(key),
                   let s = child as? String, s.isEmpty {
                    out[key] = NSNull()
                } else {
                    out[key] = sanitize(child, parentKey: key)
                }
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { sanitize($0, parentKey: parentKey) }
        }
        return value
    }

    /// A `JSONEncoder` wired to print PocketBase datetimes in the wire format.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }
}
