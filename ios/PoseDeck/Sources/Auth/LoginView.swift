import SwiftUI
import PoseDeckCore

/// Drives the ``LoginView`` form state and the sign-in side effect.
///
/// Generic over ``AuthSession`` so the view (and `#Preview`) can run against a
/// fake session without a network or keychain. On success the injected session's
/// observable `isAuthenticated` flips to `true`, which the app's root view
/// observes to swap to the deck list — this view model exposes no navigation of
/// its own.
@MainActor
@Observable
final class AuthViewModel {
    /// Bound to the email field.
    var email: String = ""
    /// Bound to the password field.
    var password: String = ""
    /// Bound to the optional backend-URL field (item 4).
    var backendURL: String = ""
    /// Whether the server section is expanded (defaults open only when a custom
    /// backend is already set, so first-time/local users see a clean form).
    var serverExpanded: Bool = false
    /// Inline error message to surface under the form, or `nil` when clear.
    private(set) var errorMessage: String?
    /// `true` while a sign-in request is in flight (disables submit / shows spinner).
    private(set) var isLoading: Bool = false

    private let session: any AuthSession
    /// Applies a user-entered backend URL (rebuilds the API stack) before sign-in.
    /// `nil` in previews/tests that don't exercise the backend switch.
    private let applyBackendURL: ((String) -> Void)?

    init(session: any AuthSession, applyBackendURL: ((String) -> Void)? = nil) {
        self.session = session
        self.applyBackendURL = applyBackendURL
    }

    /// Whether the submit button should be enabled: non-empty trimmed
    /// credentials and not already loading.
    var canSubmit: Bool {
        !isLoading
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    /// Attempt sign-in. Points the app at the entered backend (if any) first so a
    /// wrong server surfaces as a sign-in failure here, then trims the email,
    /// surfaces any failure inline, and clears the loading flag in all paths. On
    /// success the session publishes the authenticated state the root reacts to.
    func signIn() async {
        guard canSubmit else { return }

        // Apply the backend URL only when the user engaged the server field, so
        // the prefilled default never silently shadows a later config change.
        if serverExpanded {
            let trimmedURL = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedURL.isEmpty, URL(string: trimmedURL) == nil {
                errorMessage = "Enter a valid server URL, e.g. https://api.example.com"
                return
            }
            applyBackendURL?(trimmedURL)
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await session.signIn(email: trimmedEmail, password: password)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Map an arbitrary sign-in error to a concise, user-facing message.
    private static func message(for error: Error) -> String {
        if case let APIClientError.httpError(status, _) = error {
            switch status {
            case 400, 401, 403:
                return "Incorrect email or password."
            case 500...:
                return "The server is unavailable. Try again shortly."
            default:
                break
            }
        }
        if (error as? URLError) != nil {
            return "Can't reach the server. Check your connection and try again."
        }
        return "Sign in failed. Please try again."
    }
}

/// Email + password sign-in screen.
///
/// Intended root usage: the app shows ``LoginView`` while
/// `session.isAuthenticated == false` and the deck list once it flips to `true`.
/// This view performs no navigation itself; success is signalled purely through
/// the observable ``AuthSession`` state the root observes.
struct LoginView: View {
    @State private var model: AuthViewModel
    /// The app environment, for the appearance toggle (item 3) and backend
    /// switch (item 4). Optional so the `#Preview` can run without one.
    @Bindable private var env: AppEnvironment
    @FocusState private var focusedField: Field?

    private enum Field { case email, password, server }

    /// - Parameter env: the composition root to sign in through + reconfigure.
    init(env: AppEnvironment) {
        self._env = Bindable(env)
        let vm = AuthViewModel(
            session: env,
            applyBackendURL: { env.applyBackendURL($0) }
        )
        // Prefill the server field with the live backend so it shows where we'd
        // connect, and expand the section if the user already set a custom one.
        vm.backendURL = env.baseURLString
        vm.serverExpanded = AppConfig.storedBaseURLString != nil
        _model = State(initialValue: vm)
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Spacer()
                themeMenu
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                Text("Pose Deck")
                    .font(.largeTitle.weight(.bold))
                Text("Sign in to your shotlists")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                TextField("Email", text: $model.email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .email)
                    .onSubmit { focusedField = .password }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                    .submitLabel(model.serverExpanded ? .next : .go)
                    .focused($focusedField, equals: .password)
                    .onSubmit {
                        if model.serverExpanded { focusedField = .server } else { submit() }
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                serverSection

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("login.error")
                }

                Button(action: submit) {
                    HStack {
                        if model.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text("Sign In")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("login.submit")
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Appearance menu (item 3) — reachable pre-auth so the login screen honors a
    /// dark-mode preference instead of flashing light.
    private var themeMenu: some View {
        Menu {
            Picker("Appearance", selection: $env.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Label(theme.label, systemImage: theme.symbol).tag(theme)
                }
            }
        } label: {
            Image(systemName: env.theme.symbol)
                .font(.title3)
                .padding(8)
        }
        .accessibilityLabel("Appearance")
        .accessibilityIdentifier("login.theme")
    }

    /// Optional backend-URL field (item 4): collapsed behind a disclosure so the
    /// common login stays clean. Expanded by default only when a custom backend
    /// is already stored.
    @ViewBuilder
    private var serverSection: some View {
        if model.serverExpanded {
            VStack(alignment: .leading, spacing: 4) {
                // type: a plain field; we validate with URL(string:) on submit so
                // the user gets a friendly message rather than silent native
                // constraint blocking (mirrors the web login).
                TextField("Server URL", text: $model.backendURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focusedField, equals: .server)
                    .onSubmit { submit() }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Text("The Pose Deck backend to connect to. Leave the default unless you self-host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("login.server-field")
        } else {
            Button("Use a different server") {
                model.serverExpanded = true
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("login.server-disclosure")
        }
    }

    /// Kick off sign-in, dismissing the keyboard first.
    private func submit() {
        guard model.canSubmit else { return }
        focusedField = nil
        Task { await model.signIn() }
    }
}

#if DEBUG
/// Build an in-memory ``AppEnvironment`` for previews (no on-disk store / network).
@MainActor
private func previewEnvironment() -> AppEnvironment {
    let container = try! LocalMirrorStore.makeContainer(inMemory: true)
    return AppEnvironment(modelContainer: container, keychain: InMemoryKeychainStore())
}

#Preview("Login") {
    LoginView(env: previewEnvironment())
}
#endif
