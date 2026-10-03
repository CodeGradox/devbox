import DevBoxCore
import SwiftUI

struct DatabasesView: View {
    @Environment(AppStore.self) private var store
    let connection: SavedConnection
    let session: DatabaseSessionState

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            DatabaseHeader(connection: connection)
            DatabaseTotalsView(session: session)
            if let error = store.loadError, session.rows.isEmpty {
                LoadErrorView(message: error, retry: store.refresh)
            } else {
                if let error = store.loadError {
                    HStack {
                        Label("Refresh failed. Showing the last-known database list.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(error)
                        Spacer()
                        Button("Retry", action: store.refresh)
                            .disabled(store.isRefreshing || store.isDeleting)
                    }
                    .font(.callout)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                DatabaseTable(session: session, selection: $store.databaseSelection)
                    .overlay {
                        if session.rows.isEmpty {
                            if store.isRefreshing {
                                ProgressView("Connecting…")
                            } else {
                                ContentUnavailableView(
                                    "No Databases", systemImage: "externaldrive",
                                    description: Text("This account has no visible databases.")
                                )
                            }
                        }
                    }
            }
            DatabaseFooter(session: session)
        }
    }
}

private struct DatabaseHeader: View {
    @Environment(AppStore.self) private var store
    let connection: SavedConnection

    var body: some View {
        DetailHeader(title: "Databases", subtitle: endpoint, symbol: "externaldrive") {
            Button("Connection Settings…") {
                store.connectionEditor = .init(connection: connection)
            }
            .disabled(store.isDeleting || store.isModalPresented)
        }
    }

    private var endpoint: String {
        connection.settings.socketPath.isEmpty
            ? "\(connection.settings.username)@\(connection.settings.host):\(connection.settings.port)"
            : "\(connection.settings.username) · \(connection.settings.socketPath)"
    }
}

struct DatabaseTotalsView: View {
    let session: DatabaseSessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    !session.hasLoadedInventory && session.rows.isEmpty ? "Statistics not loaded" : session.summary.text,
                    systemImage: "chart.bar"
                )
                    .font(.callout.weight(.medium))
                Spacer()
                if session.isLoadingStatistics {
                    ProgressView().controlSize(.mini)
                    Text("Updating statistics…").font(.caption).foregroundStyle(.secondary)
                } else if session.statisticsRefreshPending {
                    Text("Statistics pending").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Visible objects only · Server estimates, not reclaimable disk space")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = session.statisticsError {
                Label("Statistics could not be updated. Refresh to retry.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .help("Data and index estimates can omit tables this account cannot see. InnoDB row counts are approximate; MEMORY sizes describe memory. Old values remain visible if a refresh fails.")
        Divider()
    }
}

/// The table observes membership; cells observe only their own cached presentation.
struct DatabaseTable: View {
    let session: DatabaseSessionState
    @Binding var selection: Set<String>

    var body: some View {
        Table(session.rows, selection: $selection) {
            TableColumn("Database") { row in
                Label(row.database.name, systemImage: "externaldrive")
                    .fontWeight(.medium)
                    .padding(.vertical, 6)
            }
            .width(min: 150, ideal: 210)
            TableColumn("Estimated Size") { row in
                DatabaseStatisticsCell(row: row)
            }
            .width(min: 170, ideal: 220)
            TableColumn("Tables") { row in
                DatabaseCountCell(row: row, value: \.tables)
            }
            .width(min: 55, ideal: 70, max: 95)
            TableColumn("Views") { row in
                DatabaseCountCell(row: row, value: \.views)
            }
            .width(min: 55, ideal: 65, max: 95)
            TableColumn("Est. Rows") { row in
                DatabaseCountCell(row: row, value: \.rows)
                    .help("Estimated row count, not a full-table count. InnoDB values can be approximate or unavailable.")
            }
            .width(min: 70, ideal: 100, max: 160)
            TableColumn("Type") { row in
                if row.database.isSystem {
                    Label("Protected", systemImage: "lock").foregroundStyle(.secondary)
                } else {
                    Text("User database").foregroundStyle(.secondary)
                }
            }
            .width(min: 105, ideal: 130, max: 170)
        }
    }
}

struct DatabaseStatisticsCell: View {
    let row: DatabaseRowState

    var body: some View {
        let presentation = row.presentation
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(presentation.isStale ? "\(presentation.size) · Last known" : presentation.size)
                    .monospacedDigit()
                if row.statisticsError != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(presentation.isStale ? "Last known estimate" : "Statistics unavailable")
                }
            }
            if row.statistics != nil {
                Text("\(presentation.data) data + \(presentation.indexes) indexes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(presentation.help)
    }
}

private struct DatabaseCountCell: View {
    let row: DatabaseRowState
    let value: KeyPath<DatabaseStatisticsPresentation, String>

    var body: some View {
        Text(row.presentation[keyPath: value])
            .monospacedDigit()
            .foregroundStyle(row.presentation.isStale ? .secondary : .primary)
            .help(row.presentation.help)
    }
}

private struct DatabaseFooter: View {
    @Environment(AppStore.self) private var store
    let session: DatabaseSessionState

    var body: some View {
        StatusFooter {
            if !store.databaseSelection.isEmpty {
                Text("\(store.databaseSelection.count) selected · \(session.selectedSummary(store.databaseSelection).text)")
                if store.selectedDatabases.contains(where: \.isSystem) {
                    Label("System databases are protected", systemImage: "lock")
                }
            } else {
                Text("\(session.rows.count) databases · Local connection")
            }
        }
    }
}
