import DevBoxCore
import Foundation
import Observation

/// Metadata reports visible objects, not exclusive filesystem allocation or reclaimed space.
struct DatabaseStatisticsPresentation: Equatable {
    let size: String
    let data: String
    let indexes: String
    let tables: String
    let views: String
    let rows: String
    let help: String
    let isStale: Bool

    init(statistics: DatabaseStatistics?, measuredAt: Date?, error: String?) {
        func bytes(_ value: Int64?) -> String {
            value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        }
        size = bytes(statistics?.totalBytes)
        data = bytes(statistics?.dataBytes)
        indexes = bytes(statistics?.indexBytes)
        tables = statistics.map { $0.tableCount.formatted() } ?? "—"
        views = statistics.map { $0.viewCount.formatted() } ?? "—"
        rows = statistics?.estimatedRows.map { $0.formatted() } ?? "—"
        isStale = error != nil && statistics != nil
        var details = [
            "Server-reported estimates for objects visible to this account.",
            "Data: \(data) · Indexes: \(indexes)",
            "Sequence storage is included in bytes, but sequences are not counted as user tables or rows.",
            "Includes storage-engine estimates; MEMORY tables report memory, not disk.",
            "Not guaranteed space reclaimed by deletion. Shared free space and logs are excluded; allocated pages may not be reclaimable."
        ]
        if let measuredAt {
            details.append("Updated \(measuredAt.formatted(date: .abbreviated, time: .standard)).")
        }
        if let error { details.append("Metadata unavailable: \(error)") }
        help = details.joined(separator: "\n")
    }
}

@MainActor @Observable
final class DatabaseRowState: Identifiable {
    let database: DatabaseRecord
    nonisolated let id: String
    private(set) var statistics: DatabaseStatistics?
    private(set) var measuredAt: Date?
    private(set) var statisticsError: String?
    private(set) var presentation = DatabaseStatisticsPresentation(statistics: nil, measuredAt: nil, error: nil)

    init(_ database: DatabaseRecord) {
        self.database = database
        id = database.id
    }

    func update(_ statistics: DatabaseStatistics, at date: Date) {
        self.statistics = statistics
        measuredAt = date
        statisticsError = nil
        refreshPresentation()
    }

    func fail(_ message: String) {
        // Keep the last successful estimate, explicitly marked stale.
        statisticsError = message
        refreshPresentation()
    }

    func refreshPresentation() {
        let next = DatabaseStatisticsPresentation(
            statistics: statistics, measuredAt: measuredAt, error: statisticsError
        )
        if presentation != next { presentation = next }
    }
}

struct DatabaseSizeSummary: Equatable {
    let bytes: Int64
    let knownCount: Int
    let databaseCount: Int
    let isPartial: Bool
    let staleCount: Int
    let text: String

    @MainActor
    init(_ rows: some Sequence<DatabaseRowState>) {
        var sum: Int64 = 0
        var known = 0
        var count = 0
        var partial = false
        var stale = 0
        for row in rows {
            count += 1
            if row.statisticsError != nil { partial = true }
            if row.presentation.isStale { stale += 1 }
            guard let size = row.statistics?.totalBytes else {
                partial = true
                continue
            }
            let addition = sum.addingReportingOverflow(size)
            guard !addition.overflow else {
                partial = true
                continue
            }
            sum = addition.partialValue
            known += 1
        }
        bytes = sum
        knownCount = known
        databaseCount = count
        isPartial = partial
        staleCount = stale
        if known == 0 && count > 0 {
            text = "Estimated size unavailable"
        } else {
            let formatted = ByteCountFormatter.string(fromByteCount: sum, countStyle: .file)
            if stale > 0 {
                text = "\(formatted) estimate · Partial (includes last-known values)"
            } else {
                text = partial ? "\(formatted) known estimate · Partial" : "\(formatted) estimated"
            }
        }
    }
}

/// Session-only cache. The collection changes only when database membership changes.
@MainActor @Observable
final class DatabaseSessionState {
    private(set) var rows: [DatabaseRowState] = []
    private(set) var hasLoadedInventory = false
    private(set) var isLoadingStatistics = false
    private(set) var statisticsRefreshPending = false
    private(set) var statisticsError: String?
    private(set) var summary = DatabaseSizeSummary([DatabaseRowState]())
    @ObservationIgnored private var byID: [String: DatabaseRowState] = [:]

    var records: [DatabaseRecord] { rows.map(\.database) }
    var needsStatisticsLoad: Bool { hasLoadedInventory && statisticsRefreshPending }

    func row(id: String) -> DatabaseRowState? { byID[id] }

    func selectedSummary(_ ids: Set<String>) -> DatabaseSizeSummary {
        DatabaseSizeSummary(ids.compactMap { byID[$0] })
    }

    func invalidateInventory() {
        hasLoadedInventory = false
        statisticsRefreshPending = true
    }

    func removeConfirmedDatabases(ids: Set<String>) {
        guard rows.contains(where: { ids.contains($0.id) }) else { return }
        for id in ids { byID.removeValue(forKey: id) }
        rows.removeAll { ids.contains($0.id) }
        updateSummary()
    }

    func reconcile(_ records: [DatabaseRecord]) {
        let next = records.map { byID[$0.id] ?? DatabaseRowState($0) }
        byID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        if rows.map(\.id) != next.map(\.id) { rows = next }
        hasLoadedInventory = true
        statisticsRefreshPending = true
        updateSummary()
    }

    func beginStatistics() {
        isLoadingStatistics = true
        statisticsRefreshPending = true
        statisticsError = nil
    }

    func receive(_ statistics: [String: DatabaseStatistics], at date: Date = Date()) {
        for row in rows {
            if let value = statistics[row.id] {
                row.update(value, at: date)
            } else {
                row.fail("This database was not present in the metadata response. Refresh to try again.")
            }
        }
        statisticsError = nil
        isLoadingStatistics = false
        statisticsRefreshPending = false
        updateSummary()
    }

    func failStatistics(_ message: String) {
        for row in rows { row.fail(message) }
        statisticsError = message
        isLoadingStatistics = false
        statisticsRefreshPending = false
        updateSummary()
    }

    func pauseStatistics() {
        // Cancellation does not turn an unfinished refresh into a completed snapshot.
        isLoadingStatistics = false
    }

    func refreshPresentation() {
        for row in rows { row.refreshPresentation() }
        updateSummary()
    }

    private func updateSummary() {
        let next = DatabaseSizeSummary(rows)
        if summary != next { summary = next }
    }
}
