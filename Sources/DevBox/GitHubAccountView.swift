import AppKit
import DevBoxCore
import SwiftUI

struct GitHubAccountButton: View {
    let session: GitHubSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                session.user.map { "GitHub: \($0.login)" } ?? "Sign in to GitHub…",
                systemImage: "person.crop.circle"
            )
            .lineLimit(1)
        }
        .help("Manage GitHub sign-in for pull request links")
    }
}

struct GitHubAccountView: View {
    let session: GitHubSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("GitHub Account", systemImage: "person.crop.circle")
                .font(.title2.bold())
            if session.isSigningOut {
                ProgressView("Removing saved GitHub sign-in…")
            } else if let user = session.user {
                Text("Signed in as **\(user.login)**")
                Text("DevBox can read pull requests in repositories available to both you and the GitHub App.")
                    .foregroundStyle(.secondary)
                Button("Sign out of DevBox", role: .destructive) { Task { await session.signOut() } }
                    .disabled(session.isSigningOut)
                Text("Sign-out removes this Mac’s saved tokens. To revoke access on GitHub too, use your GitHub application settings.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if session.isRestoring {
                ProgressView("Restoring GitHub sign-in…")
            } else if let authorization = session.authorization {
                Text("Enter this code on GitHub, then authorize DevBox:")
                HStack {
                    Text(authorization.userCode)
                        .font(.system(.title, design: .monospaced).bold())
                        .textSelection(.enabled)
                    Button("Copy code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(authorization.userCode, forType: .string)
                    }
                }
                Link("Open GitHub", destination: authorization.verificationURL)
                ProgressView("Waiting for authorization…")
                    .controlSize(.small)
                Text("Code expires \(authorization.expiresAt.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel sign-in", action: session.cancelSignIn)
                    .disabled(session.isSavingCredential)
            } else if session.isSigningIn {
                ProgressView("Requesting a GitHub sign-in code…")
                Button("Cancel sign-in", action: session.cancelSignIn)
                    .disabled(session.isSavingCredential)
            } else {
                Text("Sign in in your browser to see the latest pull request for each published GitHub branch.")
                Text("Access and refresh tokens are stored only in macOS Keychain. No client secret or private key is needed.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Sign in with GitHub", action: session.beginSignIn)
                    .buttonStyle(.borderedProminent)
            }
            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                if session.credentialAccessFailed {
                    HStack {
                        Button("Retry Keychain access") { Task { await session.retryCredentialAccess() } }
                        if session.user == nil {
                            Button("Forget saved sign-in") { Task { await session.signOut() } }
                        }
                    }
                    .disabled(session.isSigningOut || session.isSavingCredential || session.isRestoring)
                } else if session.user == nil && !session.isSigningIn && !session.isRestoring {
                    HStack {
                        Button("Retry saved sign-in") { Task { await session.retryCredentialAccess() } }
                        Button("Forget saved sign-in") { Task { await session.signOut() } }
                    }
                    .disabled(session.isSigningOut)
                }
            }
            Divider()
            Text("Missing repositories? Install the GitHub App on those repositories with Pull requests: Read-only. Organization access may require an administrator’s approval.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Manage GitHub applications", destination: URL(string: "https://github.com/settings/installations")!)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(session.isSavingCredential && session.isSigningIn)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(session.isSavingCredential && session.isSigningIn)
        .onDisappear { session.cancelSignIn() }
    }
}
