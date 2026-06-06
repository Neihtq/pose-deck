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
    /// Inline error message to surface under the form, or `nil` when clear.
    private(set) var errorMessage: String?
    /// `true` while a sign-in request is in flight (disables submit / shows spinner).
    private(set) var isLoading: Bool = false

    private let session: any AuthSession

    init(session: any AuthSession) {
        self.session = session
    }

    /// Whether the submit button should be enabled: non-empty trimmed
    /// credentials and not already loading.
    var canSubmit: Bool {
        !isLoading
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    /// Attempt sign-in. Trims the email, surfaces any failure inline, and clears
    /// the loading flag in all paths. On success the session publishes the
    /// authenticated state the root view reacts to.
    func signIn() async {
        guard canSubmit else { return }
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
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    /// - Parameter session: the shared auth session to sign in through.
    init(session: any AuthSession) {
        _model = State(initialValue: AuthViewModel(session: session))
    }

    var body: some View {
        VStack(spacing: 24) {
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
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { submit() }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

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

    /// Kick off sign-in, dismissing the keyboard first.
    private func submit() {
        guard model.canSubmit else { return }
        focusedField = nil
        Task { await model.signIn() }
    }
}

#if DEBUG
/// In-memory fake session for previews: flips `currentUser` after a short delay,
/// or throws to exercise the error path.
@MainActor
@Observable
private final class PreviewAuthSession: AuthSession {
    private(set) var currentUser: User?
    let shouldFail: Bool

    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }

    func signIn(email: String, password: String) async throws {
        try? await Task.sleep(nanoseconds: 600_000_000)
        if shouldFail {
            throw APIClientError.httpError(status: 400, body: Data())
        }
        currentUser = User(
            id: "preview-user",
            email: email,
            name: "Preview",
            created: nil,
            updated: nil
        )
    }

    func signOut() async { currentUser = nil }
    func restore() async {}
}

#Preview("Login") {
    LoginView(session: PreviewAuthSession())
}

#Preview("Login – error") {
    LoginView(session: PreviewAuthSession(shouldFail: true))
}
#endif
