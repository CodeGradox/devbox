import DevBoxCore
import SwiftUI

struct ConnectionEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private let existing: SavedConnection?
    @State private var id: UUID
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password = ""
    @State private var useSocket: Bool
    @State private var socketPath: String
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var isLoadingCredential = false
    @State private var message: String?
    @State private var testSucceeded = false
    @State private var credentialLoadFailed = false

    init(connection: SavedConnection?) {
        existing = connection
        let settings = connection?.settings ?? ConnectionSettings()
        _id = State(initialValue: connection?.id ?? UUID())
        _name = State(initialValue: connection?.name ?? "Local MariaDB")
        _host = State(initialValue: settings.host)
        _port = State(initialValue: String(settings.port))
        _username = State(initialValue: settings.username)
        _socketPath = State(initialValue: settings.socketPath)
        _useSocket = State(initialValue: !settings.socketPath.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "Add MariaDB Connection" : "Connection Settings")
                .font(.title2.weight(.semibold))
                .padding([.top, .horizontal], 24)
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Connection", selection: $useSocket) {
                        Text("Local TCP").tag(false)
                        Text("Unix Socket").tag(true)
                    }
                    if useSocket {
                        TextField("Socket path", text: $socketPath, prompt: Text("/tmp/mysql.sock"))
                    } else {
                        Picker("Host", selection: $host) {
                            Text("127.0.0.1").tag("127.0.0.1")
                            Text("localhost").tag("localhost")
                            Text("::1").tag("::1")
                        }
                        TextField("Port", text: $port)
                    }
                }
                Section {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                        .onChange(of: password) { credentialLoadFailed = false }
                } footer: {
                    Text("Your password is stored in macOS Keychain. Only local connections are supported in v0.")
                }
                if let message {
                    Section {
                        Label(message, systemImage: testSucceeded ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(testSucceeded ? Color.green : Color.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isTesting || isSaving || isLoadingCredential)
            Divider()
            HStack {
                Button("Test Connection") { test() }
                    .disabled(!valid || isTesting || isSaving || isLoadingCredential)
                if isTesting || isSaving || isLoadingCredential { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isTesting || isSaving)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || isTesting || isSaving || isLoadingCredential || credentialLoadFailed)
            }
            .padding(20)
        }
        .frame(width: 520, height: 550)
        .interactiveDismissDisabled(isTesting || isSaving)
        .task {
            guard let existing else { return }
            isLoadingCredential = true
            defer { isLoadingCredential = false }
            do {
                let saved = try await store.password(for: existing.id)
                try Task.checkCancellation()
                password = saved
            }
            catch is CancellationError {}
            catch {
                credentialLoadFailed = true
                message = "\(error.localizedDescription)\nEnter the password again to update this connection."
            }
        }
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.isEmpty
            && (useSocket ? socketPath.hasPrefix("/") : (Int(port).map { (1...65535).contains($0) } ?? false))
    }

    private var connection: SavedConnection {
        SavedConnection(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), settings: ConnectionSettings(
            host: useSocket ? "127.0.0.1" : host,
            port: useSocket ? 3306 : (Int(port) ?? 3306),
            username: username,
            socketPath: useSocket ? socketPath : ""
        ))
    }

    private func test() {
        isTesting = true
        message = nil
        let settings = connection.settings
        let secret = password
        Task {
            defer { isTesting = false }
            do {
                try await store.databaseService.testConnection(settings: settings, password: secret)
                testSucceeded = true
                message = "Connected successfully."
            } catch {
                testSucceeded = false
                message = error.localizedDescription
            }
        }
    }

    private func save() {
        isSaving = true
        let connection = connection
        let secret = password
        Task {
            defer { isSaving = false }
            do {
                try await store.saveConnection(connection, password: secret)
                password = ""
                dismiss()
            } catch {
                testSucceeded = false
                message = error.localizedDescription
            }
        }
    }
}
