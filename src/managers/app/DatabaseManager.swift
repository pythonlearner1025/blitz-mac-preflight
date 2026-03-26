import Foundation

@MainActor
@Observable
final class DatabaseManager {
    // Connection & data state
    var connectionStatus: ConnectionStatus = .disconnected
    var schema: TeenybaseSettingsResponse?
    var selectedTable: TeenybaseTable?
    var rows: [TableRow] = []
    var totalRows: Int = 0
    var currentPage: Int = 0
    var pageSize: Int = 50
    var sortField: String?
    var sortAscending: Bool = true
    var searchText: String = ""
    var errorMessage: String?

    // Tracks which project we're connected to
    private(set) var connectedProjectId: String?

    // Backend process
    let backendProcess = TeenybaseProcessService()
    let client = TeenybaseClient()

    /// Start the backend server for a project and connect to it.
    func startAndConnect(projectId: String, projectPath: String) async {
        // Already connected to this project
        if connectedProjectId == projectId && connectionStatus == .connected { return }
        // Already in progress for this project
        if connectedProjectId == projectId && connectionStatus == .connecting { return }

        // Switching projects — tear down old connection
        if connectedProjectId != nil && connectedProjectId != projectId {
            disconnect()
        }

        connectedProjectId = projectId
        connectionStatus = .connecting
        errorMessage = nil

        let token = TeenybaseProjectEnvironment.adminToken(projectPath: projectPath)
        guard let token, !token.isEmpty else {
            connectionStatus = .error
            errorMessage = "No ADMIN_SERVICE_TOKEN in .dev.vars"
            return
        }

        // Start the backend process
        await backendProcess.start(projectPath: projectPath)

        // Wait for it to be running
        guard backendProcess.status == .running else {
            connectionStatus = .error
            errorMessage = backendProcess.errorMessage ?? "Backend failed to start"
            return
        }

        // Connect the API client
        let baseURL = backendProcess.baseURL
        await client.configure(baseURL: baseURL, token: token)

        do {
            let settings = try await client.fetchSchema()
            self.schema = settings
            self.connectionStatus = .connected
            self.errorMessage = nil
            if self.selectedTable == nil, let first = settings.tables.first {
                self.selectedTable = first
            }
        } catch {
            self.connectionStatus = .error
            self.errorMessage = "Connected but schema fetch failed: \(error.localizedDescription)"
        }
    }

    func loadRows() async {
        guard let table = selectedTable else { return }
        do {
            var whereClause: String? = nil
            if !searchText.isEmpty {
                let textFields = table.fields.filter { ($0.type ?? "text") == "text" || ($0.sqlType ?? "") == "text" }
                if !textFields.isEmpty {
                    let escaped = searchText
                        .replacingOccurrences(of: "'", with: "''")
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "%", with: "\\%")
                        .replacingOccurrences(of: "_", with: "\\_")
                    let clauses = textFields.map { "\($0.name) LIKE '%\(escaped)%'" }
                    whereClause = clauses.joined(separator: " OR ")
                }
            }

            let result = try await client.listRecords(
                table: table.name,
                limit: pageSize,
                offset: currentPage * pageSize,
                orderBy: sortField,
                ascending: sortAscending,
                where: whereClause
            )
            self.rows = result.items
            self.totalRows = result.total
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func insertRecord(values: [String: Any]) async {
        guard let table = selectedTable else { return }
        do {
            _ = try await client.insertRecord(table: table.name, values: values)
            await loadRows()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func updateRecord(id: String, values: [String: Any]) async {
        guard let table = selectedTable else { return }
        do {
            _ = try await client.updateRecord(table: table.name, id: id, values: values)
            await loadRows()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func deleteRecord(id: String) async {
        guard let table = selectedTable else { return }
        do {
            _ = try await client.deleteRecord(table: table.name, id: id)
            await loadRows()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        backendProcess.stop()
        connectedProjectId = nil
        connectionStatus = .disconnected
        schema = nil
        selectedTable = nil
        rows = []
        totalRows = 0
        currentPage = 0
        errorMessage = nil
    }
}
