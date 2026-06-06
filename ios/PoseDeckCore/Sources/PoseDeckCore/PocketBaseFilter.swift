import Foundation

/// Helpers for building PocketBase filter expressions safely.
///
/// PocketBase filters embed values as double-quoted string literals
/// (e.g. `id = "abc123"`). The repositories build these by interpolation; today
/// every interpolated value is a server-issued alphanumeric record id, so the
/// quotes never break. But interpolating *any* caller-supplied text without
/// escaping is a filter-injection sink — a value containing `"` could close the
/// literal and inject extra `||`/`&&` clauses, widening the result set past the
/// intended record.
///
/// ``quoted(_:)`` renders a value as a properly-escaped quoted literal so the
/// embedded value can never break out of the quotes regardless of its content,
/// giving the pattern defense-in-depth even if a future caller routes user text
/// through it.
public enum PocketBaseFilter {

    /// Escape a value for use inside a double-quoted PocketBase filter literal.
    ///
    /// Backslashes are escaped first (so the escapes themselves aren't re-escaped),
    /// then double-quotes. Control characters (newlines, NUL, etc.) are stripped
    /// because they can't appear in a single-line filter expression and only serve
    /// to obfuscate injection attempts.
    public static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                result += "\\\\"
            case "\"":
                result += "\\\""
            default:
                // Drop ASCII/Unicode control characters; keep everything else.
                if scalar.properties.generalCategory == .control {
                    continue
                }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Render a value as an escaped, double-quoted PocketBase filter literal,
    /// e.g. `"abc123"`. Use this everywhere a value is embedded in a filter so it
    /// cannot break out of the quoted literal.
    public static func quoted(_ value: String) -> String {
        "\"\(escape(value))\""
    }
}
