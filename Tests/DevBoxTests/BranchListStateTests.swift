import Foundation
import Testing
@testable import DevBox
import DevBoxCore

@MainActor
struct BranchListStateTests {
    private func branch(
        _ reference: String, name: String = "topic", date: Date? = nil,
        committer: String = "Pat Developer", email: String = "pat@example.com",
        remote: String? = nil
    ) -> ManagedBranch {
        ManagedBranch(
            reference: reference, name: name, commit: "abc123",
            committerName: committer, committerEmail: email, committedAt: date,
            remoteName: remote
        )
    }

    @Test func filtersAndReferenceIdentity() {
        let session = BranchListState()
        let local = branch("refs/heads/topic")
        let remote = branch("refs/remotes/origin/topic", remote: "origin")
        session.reconcile([local, remote])
        #expect(session.hasLoadedInventory)
        #expect(Set(session.rows.map(\.id)) == [local.reference, remote.reference])
        session.selection = [local.reference, remote.reference]
        session.filter = .local
        #expect(session.rows.map(\.branch) == [local])
        #expect(session.selection == [local.reference])
        session.filter = .remote
        #expect(session.rows.map(\.branch) == [remote])
        #expect(session.selection.isEmpty)
        session.filter = .all
        #expect(session.rows.count == 2)
    }

    @Test func oldestNewestAndUnknownDates() {
        let session = BranchListState()
        let oldest = branch("refs/heads/old", date: Date(timeIntervalSince1970: 10))
        let newest = branch("refs/heads/new", date: Date(timeIntervalSince1970: 20))
        let unknown = branch("refs/heads/unknown")
        session.reconcile([unknown, oldest, newest])
        #expect(session.rows.map(\.id) == [newest.reference, oldest.reference, unknown.reference])
        session.sort = .oldest
        #expect(session.rows.map(\.id) == [oldest.reference, newest.reference, unknown.reference])
    }

    @Test func queryMatchesBranchCommitterAndEmailAndDropsHiddenSelection() {
        let session = BranchListState()
        let a = branch("refs/heads/alpha", name: "Alpha")
        let b = branch("refs/heads/beta", name: "Beta", committer: "Sam", email: "sam@example.org")
        session.reconcile([b, a])
        session.sort = .name
        #expect(session.rows.map(\.id) == [a.reference, b.reference])
        session.selection = [a.reference, b.reference]
        session.query = " ALPHA "
        #expect(session.rows.map(\.id) == [a.reference])
        #expect(session.selection == [a.reference])
        session.query = "SAM"
        #expect(session.rows.map(\.id) == [b.reference])
        #expect(session.selection.isEmpty)
        session.query = "example.org"
        #expect(session.rows.map(\.id) == [b.reference])
        session.selection = [a.reference, b.reference, "missing"]
        #expect(session.selectedBranches == [b])
    }

    @Test func reconcileDeletionAndInvalidation() {
        let session = BranchListState()
        let a = branch("refs/heads/a")
        let b = branch("refs/heads/b")
        session.reconcile([a, b])
        session.selection = [a.reference, b.reference]
        session.reconcile([b])
        #expect(session.selection == [b.reference])
        session.removeConfirmedBranches(ids: [b.reference])
        #expect(session.rows.isEmpty)
        #expect(session.selectedBranches.isEmpty)
        session.reconcile([a])
        session.selection = [a.reference]
        session.invalidateInventory()
        #expect(!session.hasLoadedInventory)
        #expect(session.selection.isEmpty)
        #expect(session.rows.map(\.branch) == [a])
    }

    @Test func refreshPresentationPreservesSelectionAndFetchDate() {
        let session = BranchListState()
        let a = branch("refs/heads/a")
        session.reconcile([a])
        session.selection = [a.reference]
        session.lastFetchedAt = Date(timeIntervalSince1970: 100)
        session.refreshPresentation()
        #expect(session.selection == [a.reference])
        #expect(session.fetchDescription.contains("Last fetched"))
        #expect(session.rows[0].commitHelp.contains(a.commit))
    }

    @Test func gravatarUsesNormalizedSHA256AndRejectsEmptyEmail() {
        let expected = URL(string: "https://www.gravatar.com/avatar/973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b?s=64&d=404")
        #expect(Gravatar.url(email: " \nTEST@Example.com\t") == expected)
        #expect(Gravatar.url(email: "test@example.com") == expected)
        #expect(Gravatar.url(email: " \n\t") == nil)
        #expect(Gravatar.url(email: "") == nil)
    }
}
