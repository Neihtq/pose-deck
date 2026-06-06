import Foundation
import PoseDeckCore

/// Shared display formatting for deck/card screens.
enum DeckFormatting {
    private static let shootDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// Human-readable shoot date, or `nil` when undated.
    static func shootDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return shootDateFormatter.string(from: date)
    }

    /// Subtitle for a deck row: the shoot date, or "No date".
    static func subtitle(for deck: Deck) -> String {
        shootDate(deck.shootDate) ?? "No date"
    }
}
