import SwiftUI
import PoseDeckCore

/// Owner-only deck-sharing screen (M5 / ARCHITECTURE.md §6).
///
/// Lists the deck's current guests (re-queried from the mirror on each
/// ``MirrorChangeTicker`` bump so a realtime grant/revoke reflects live) each
/// with a Revoke action, plus an "add by email" field that resolves the email to
/// a user and grants access. Not-found, duplicate, and self-share are surfaced as
/// errors via the view model's `actionError`.
///
/// Presented as a PUSHED destination (not a `.sheet`) from ``DeckDetailView``:
/// an optimistic grant writes the SwiftData mirror, bumping the deck-list ticker
/// and re-rendering the list — which would tear down an attached sheet. A pushed
/// destination is keyed by the route value and survives that re-render, so the
/// screen stays put while guests are added/revoked. Only ever shown for the deck
/// owner (gated on `model.isOwner`), matching the web `ShareDeckDialog`.
struct ShareDeckView: View {
    @Bindable var model: DeckDetailViewModel
    /// Bumps when the SwiftData mirror changes (a realtime grant/revoke), so the
    /// guest list re-queries without a manual pull. Optional (nil in previews).
    let ticker: MirrorChangeTicker?

    @State private var email: String = ""
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section("Add a guest") {
                HStack {
                    TextField("Email address", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .submitLabel(.done)
                        .onSubmit { submit() }
                        .accessibilityIdentifier("share.email")
                    Button("Share", action: submit)
                        .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                        .accessibilityIdentifier("share.submit")
                }
            }

            Section("Shared with") {
                if model.guests.isEmpty {
                    Text("Not shared with anyone yet.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("share.empty")
                } else {
                    ForEach(model.guests) { guest in
                        HStack {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                            Text(guest.user)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityIdentifier("share.guest.\(guest.user)")
                            Spacer(minLength: 8)
                            Button("Revoke", role: .destructive) {
                                Task { await model.revokeGuest(guest) }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("share.revoke")
                        }
                    }
                }
            }
        }
        .navigationTitle("Share Deck")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadGuests() }
        // Reactive re-query on a realtime grant/revoke (mirror of the deck
        // detail's ticker-driven refresh).
        .task(id: ticker?.revision) {
            if let revision = ticker?.revision, revision > 0 {
                await model.loadGuests()
            }
        }
        .alert(
            "Couldn't share",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            ),
            presenting: model.actionError
        ) { _ in
            Button("OK", role: .cancel) { model.actionError = nil }
        } message: { msg in Text(msg) }
    }

    private func submit() {
        // SWIFT-A2: re-entry guard so the Button and the field's `.onSubmit`
        // (keyboard Return) paths are both gated by the same in-flight flag — a
        // Return racing a Share tap, or two rapid Returns, must not spawn two
        // overlapping grant Tasks. `model.grantGuest` also guards at the source
        // (GuestGrantGate); this elides the redundant Task before it even spawns.
        guard !isSubmitting else { return }
        let target = email
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSubmitting = true
        Task {
            await model.grantGuest(email: target)
            // Clear the field only on success (no error surfaced).
            if model.actionError == nil { email = "" }
            isSubmitting = false
        }
    }
}

#Preview("Shared with two") {
    let model = DeckDetailViewModel(
        deck: Deck(id: "d0", owner: "u1", name: "Beach Shoot"),
        deckRepo: FakeDeckRepository(),
        cardRepo: FakeCardRepository(cardsByDeck: [:]),
        imageRepo: FakeCardImageRepository(),
        guestRepo: FakeDeckGuestRepository(
            guests: [
                DeckGuest(id: "g1", deck: "d0", user: "friend-user-id", grantedAt: Date()),
            ],
            knownUsers: ["guest@posedeck.test": "guest-user-id"]
        ),
        ownerId: "u1"
    )
    return ShareDeckView(model: model, ticker: nil)
}
