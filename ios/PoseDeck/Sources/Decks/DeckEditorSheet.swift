import SwiftUI
import PoseDeckCore

/// Reusable name + optional shoot-date form used for both **New deck** and
/// **Rename / edit date**. The parent passes an initial name/date and gets the
/// edited values back via `onSave`; `nil` date means undated.
struct DeckEditorSheet: View {
    let title: String
    let saveLabel: String
    @State private var name: String
    @State private var hasDate: Bool
    @State private var date: Date

    let onSave: (_ name: String, _ shootDate: Date?) -> Void
    let onCancel: () -> Void

    init(
        title: String,
        saveLabel: String = "Save",
        initialName: String = "",
        initialDate: Date? = nil,
        onSave: @escaping (_ name: String, _ shootDate: Date?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.saveLabel = saveLabel
        self._name = State(initialValue: initialName)
        self._hasDate = State(initialValue: initialDate != nil)
        self._date = State(initialValue: initialDate ?? Date())
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Deck name", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Shoot date") {
                    Toggle("Has a shoot date", isOn: $hasDate.animation())
                    if hasDate {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveLabel) {
                        onSave(trimmedName, hasDate ? date : nil)
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }
}

#Preview("New deck") {
    DeckEditorSheet(title: "New Deck", saveLabel: "Create",
                    onSave: { _, _ in }, onCancel: {})
}

#Preview("Edit deck") {
    DeckEditorSheet(title: "Edit Deck", initialName: "Smith Wedding",
                    initialDate: Date(), onSave: { _, _ in }, onCancel: {})
}
