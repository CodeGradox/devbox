import DevBoxCore
import SwiftUI

/// Keep account and PR progress observation out of the branch table's body.
struct BranchPullRequestControls: View {
    let branches: Set<GitHubBranch>
    let session: GitHubSession
    let disabled: Bool
    let showAccount: () -> Void

    private struct LoadID: Equatable {
        let account: UUID
        let branches: Set<GitHubBranch>
    }

    var body: some View {
        Button {
            if session.user != nil {
                session.pullRequests.load(branches, session: session, force: true)
            } else {
                showAccount()
            }
        } label: {
            Image(systemName: "arrow.triangle.pull")
        }
        .accessibilityLabel(session.user == nil ? "Sign in for pull requests" : "Refresh PRs")
        .help(session.user == nil
              ? "Sign in to GitHub to load pull request links."
              : "Refresh PRs: contacts GitHub for visible branches without fetching Git refs.")
        .disabled(disabled || session.isRestoring ||
                  (session.user != nil && (branches.isEmpty || session.pullRequests.isLoading)))
        .modifier(GitHubRateLimitGate(retryAt: session.pullRequests.rateLimitRetryAt))
        .task(id: LoadID(account: session.accountGeneration, branches: branches)) {
            session.pullRequests.load(branches, session: session)
        }
        .onDisappear { session.pullRequests.cancelLoading() }
    }
}

struct BranchPullRequestStatus: View {
    let branches: Set<GitHubBranch>
    let session: GitHubSession
    let disabled: Bool
    let showAccount: () -> Void
    @State private var showsFailures = false

    var body: some View {
        if session.user == nil {
            Button(session.errorMessage == nil ? "Sign in for PRs…" : "GitHub sign-in needs attention…", action: showAccount)
                .buttonStyle(.plain)
                .disabled(disabled || session.isRestoring)
        } else if !branches.isEmpty {
            let failures = session.pullRequests.failures(for: branches)
            HStack(spacing: 6) {
                if session.pullRequests.isLoading {
                    ProgressView().controlSize(.mini)
                    Text("Loading PRs…")
                }
                if !failures.isEmpty {
                    let count = failures.reduce(0) { $0 + $1.branchCount }
                    Button {
                        showsFailures = true
                    } label: {
                        Label(count == 1 ? "1 PR lookup failed" : "\(count) PR lookups failed",
                              systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .disabled(disabled)
                    .help("Show GitHub errors and recovery steps")
                    .popover(isPresented: $showsFailures) {
                        GitHubPullRequestFailureDetails(
                            failures: failures,
                            canRetry: !disabled && !session.pullRequests.isLoading,
                            retryAt: session.pullRequests.rateLimitRetryAt,
                            retry: {
                                showsFailures = false
                                session.pullRequests.load(branches, session: session, force: true)
                            },
                            showAccount: {
                                showsFailures = false
                                showAccount()
                            }
                        )
                    }
                } else if !session.pullRequests.isLoading {
                    Text("PRs cached").help("Use Refresh PRs to contact GitHub for fresh results.")
                }
            }
        }
    }
}

struct GitHubPullRequestFailureDetails: View {
    let failures: [GitHubPullRequestFailureSummary]
    let canRetry: Bool
    var retryAt: Date? = nil
    let retry: () -> Void
    let showAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pull requests unavailable", systemImage: "exclamationmark.triangle")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(failures) { failure in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.repository).fontWeight(.medium)
                            Text(failure.branchCount == 1 ? "1 affected branch" : "\(failure.branchCount) affected branches")
                                .foregroundStyle(.secondary)
                            Text(failure.message)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 240)
            Text("Signing in does not install the GitHub App. For access errors, check that it is installed on these repositories with Pull requests: Read-only. Organization repositories may require approval or SSO.")
                .foregroundStyle(.secondary)
            Link("Manage GitHub App installations", destination: URL(string: "https://github.com/settings/installations")!)
            HStack {
                Button("Retry PRs", action: retry).disabled(!canRetry)
                    .modifier(GitHubRateLimitGate(retryAt: retryAt))
                Button("GitHub Account…", action: showAccount)
            }
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .lineLimit(nil)
        .padding(16)
        .frame(width: 380)
    }
}

/// Wake once at GitHub's deadline, rather than polling or leaving retry disabled
/// until an unrelated UI change. The cache also enforces this bound independently.
private struct GitHubRateLimitGate: ViewModifier {
    let retryAt: Date?

    func body(content: Content) -> some View {
        TimelineView(.explicit(retryAt.map { [$0] } ?? [])) { context in
            if let retryAt, retryAt > context.date {
                content.disabled(true)
                    .help("GitHub rate limit reached. Retry after \(retryAt.formatted()).")
            } else {
                content
            }
        }
    }
}

struct BranchPullRequestCell: View {
    let branch: GitHubBranch?
    let session: GitHubSession
    let disabled: Bool
    let showAccount: () -> Void
    @State private var showsFailure = false

    var body: some View {
        if let branch {
            if session.user == nil {
                Text("Sign in").foregroundStyle(.secondary)
                    .help("Sign in to GitHub to load pull requests.")
            } else {
                switch session.pullRequests.entries[branch] {
                case .loading:
                    Text("Loading…").foregroundStyle(.secondary)
                case .loaded(let request, let checkedAt):
                    if let request {
                        Link(destination: request.url) {
                            Text("#\(request.number) · \(title(request.state))")
                                .lineLimit(1)
                        }
                        .tint(color(request.state))
                        .help("\(request.title)\nNewest-created PR · Checked \(checkedAt.formatted())")
                        .accessibilityLabel("Pull request \(request.number), \(title(request.state)): \(request.title)")
                    } else {
                        Text("No PR").foregroundStyle(.secondary)
                            .help("No pull request found for this branch in its repository or fork parent. Checked \(checkedAt.formatted()).")
                    }
                case .failed(let message):
                    Button {
                        showsFailure = true
                    } label: {
                        Label("Unavailable", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .disabled(disabled)
                    .help(message)
                    .accessibilityLabel("Pull request unavailable: \(message). Show details.")
                    .popover(isPresented: $showsFailure) {
                        GitHubPullRequestFailureDetails(
                            failures: [.init(repository: branch.repository, message: message, branchCount: 1)],
                            canRetry: !session.pullRequests.isLoading && !disabled,
                            retryAt: session.pullRequests.rateLimitRetryAt,
                            retry: {
                                showsFailure = false
                                session.pullRequests.load([branch], session: session, force: true)
                            },
                            showAccount: {
                                showsFailure = false
                                showAccount()
                            }
                        )
                    }
                case nil:
                    Text("Not loaded").foregroundStyle(.secondary)
                }
            }
        } else {
            Text("—").foregroundStyle(.secondary)
                .help("This branch is unpublished or has no supported GitHub upstream.")
        }
    }

    private func title(_ state: GitHubPullRequest.State) -> String {
        switch state {
        case .open: "Open"
        case .closed: "Closed"
        case .merged: "Merged"
        }
    }

    private func color(_ state: GitHubPullRequest.State) -> Color {
        switch state {
        case .open: .green
        case .closed: .secondary
        case .merged: .purple
        }
    }
}
