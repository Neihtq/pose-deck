import SwiftUI
import PoseDeckCore

/// App settings (items 3 + 4): pick the appearance (System / Light / Dark) and
/// see which backend the app is connected to.
///
/// The appearance change is applied live at the app root via
/// `AppEnvironment.theme` → `preferredColorScheme`. The backend URL is shown
/// read-only here because changing it rebuilds the API stack and is only safe
/// while signed out, so it's edited on the login screen (item 4); this screen
/// surfaces the current value and points the user there.
struct SettingsView: View {
    @Bindable var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $env.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Label(theme.label, systemImage: theme.symbol).tag(theme)
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier("settings.theme")
                } header: {
                    Text("Appearance")
                }

                Section {
                    LabeledContent("Server", value: env.baseURLString)
                        .accessibilityIdentifier("settings.backendURL")
                } header: {
                    Text("Backend")
                } footer: {
                    Text("To connect to a different server, sign out and enter its URL on the sign-in screen.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
        }
        .accessibilityIdentifier("settings.sheet")
    }
}
