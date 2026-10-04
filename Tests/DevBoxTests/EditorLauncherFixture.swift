import Testing
@testable import DevBox

/// Store tests must not discover or launch applications installed on the test host.
@MainActor
func inertEditorLauncher() -> EditorLauncher {
    EditorLauncher(
        findApplications: { [] },
        describeApplication: { _ in nil },
        findApplication: { _ in nil },
        openURLs: { _, _, _ in Issue.record("Unexpected editor launch in an inert fixture.") }
    )
}
