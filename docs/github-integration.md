# GitHub integration

DevBox uses a **GitHub App** with OAuth Device Flow, not an OAuth App with a broad
`repo` scope. The public Client ID is in
`Sources/DevBoxCore/GitHubAuthenticationClient.swift`. It is an identifier, not a secret;
it belongs in the distributed app and does not need a GitHub Actions secret.

## App registration

For a separate deployment, register a GitHub App and replace the public Client ID:

- Enable **Device Flow**.
- Leave **Expire user authorization tokens** enabled.
- Leave **Request user authorization during installation** disabled.
- Grant **Repository permissions → Pull requests → Read-only**.
- Keep mandatory **Metadata → Read-only**; no other permissions are required.
- Disable **Webhook → Active** and leave event subscriptions empty.
- Leave the setup URL blank. Device Flow does not use a redirect/callback URL;
  the repository homepage can serve as a placeholder if GitHub requests one.
- Choose **Any account** to allow other users and organizations to install the app.
  This does not automatically grant repository access.
- Install the app on the selected repositories. Private organization repositories
  may need administrator approval or an active SSO session.

**Do not add a private key, client secret, or user token to the repository, build
configuration, or app bundle.** Neither sign-in nor refresh needs an app secret for
device-issued tokens.

## Runtime behavior

1. DevBox requests a device code and displays the short user code.
2. It opens the fixed `https://github.com/login/device` verification page.
3. Polling respects GitHub's interval, `slow_down`, expiration, and cancellation.
4. DevBox verifies the signed-in identity and stores tokens in the non-synchronizing
   `app.devbox.github` macOS Keychain service.
5. Expiring access tokens refresh with the refresh token. Concurrent API requests
   share one refresh. Rotated credentials are retained before subsequent network
   work, so a transient identity-check failure does not lose the new refresh token.
6. Sign-out cancels account work and clears PR results only after Keychain removal
   succeeds. It does not revoke the authorization on GitHub.

HTTP uses one ephemeral URLSession with cookies, credential storage, and caching
disabled. Redirects are rejected so tokens and OAuth POST bodies cannot be forwarded
to another endpoint. Error messages never include raw response bodies or credentials.

PR queries use the same branch URL mapping as existing GitHub branch links. Local
branches without an existing upstream do not get guessed PR targets. Lookups include
all PR states, sort by creation time, match both source repository and exact branch,
and paginate when necessary. Fork lookups include the source repository and its
immediate parent, not arbitrary destinations elsewhere in the fork network.

Repository/fork discovery uses REST once per source repository in a load. PR lookups
use GraphQL aliases in batches of up to **25 distinct branches**, with at most **two
batch operations** in flight. For 100 branches in a non-fork repository, the ordinary
initial load is one metadata request plus four PR requests, rather than 101 requests.
Only fields needed to identify and display PRs are requested. Additional pages fetch
only aliases still searching for an exact source match.

PR results (including successful empty results) stay in memory until **Refresh PRs**
or sign-out. Filter changes load uncached visible branches. Duplicate targets share a
lookup; completed batches publish incrementally. Scoped GraphQL errors affect only
their branches; successful results in the same response are retained. Missing/null
data and failed candidate repositories never become “No PR”.

Rate limits can arrive in an HTTP 200 GraphQL response as well as HTTP 403/429.
DevBox stops further batches and pagination when throttled and honors GitHub's
`Retry-After`/`x-ratelimit-reset` deadline, using a 60-second minimum fallback when
no usable deadline is supplied. Refresh and retry stay disabled until that time;
the cache also blocks requests independently of the UI. No automatic retry loop
consumes the rate budget. Git operations and remote credentials remain independent.

The compact branch controls put **Refresh PRs** beside **Fetch & Prune** as a
pull-request icon; explanatory text stays in the branch information popover.
The footer reports PR loading, cached results, or failed lookups. Clicking a failure
opens repository-grouped, selectable error details and retry/account actions.
Access errors include their access classification and explain installation, repository
selection, approval, and SSO rather than hiding those steps behind “Unavailable”.

## Validation

```sh
sh scripts/test.sh --filter 'GitHub|github'
sh scripts/test.sh --filter BranchRenderingTests
```

The tests use synthetic tokens, injected API responses, and in-memory credentials.
They do not open a real authorization page or read the user's Keychain.
For visible-window checks in a macOS GUI session:

```sh
DEVBOX_UI_TESTS=1 sh scripts/test.sh --filter BranchRenderingTests
```

A live acceptance check still needs the user's browser approval: sign in, inspect a
known branch PR, refresh it, relaunch to check restoration, then sign out.

References:
- [GitHub App Device Flow](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app#using-the-device-flow-to-generate-a-user-access-token)
- [Refreshing GitHub App user tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens)
- [GraphQL rate and query limits](https://docs.github.com/en/graphql/overview/rate-limits-and-node-limits-for-the-graphql-api)
