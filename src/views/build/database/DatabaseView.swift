import SwiftUI

struct DatabaseView: View {
    @Bindable var appState: AppState

    @State private var showRecordEditor = false
    @State private var editingRow: TableRow? = nil
    @State private var deleteRowId: String? = nil
    @State private var showDeleteAlert = false

    private var db: DatabaseManager { appState.databaseManager }
    private var backend: TeenybaseProcessService { db.backendProcess }

    @State private var hasBackend = false

    var body: some View {
        VStack(spacing: 0) {
            if db.connectionStatus == .connected {
                HStack(spacing: 0) {
                    tableListSidebar
                    Divider()
                    VStack(spacing: 0) {
                        dataToolbar
                        Divider()
                        dataGrid
                        Divider()
                        paginationBar
                    }
                }
            } else {
                emptyState
            }
        }
        .alert("Delete Record", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let id = deleteRowId {
                    Task { await db.deleteRecord(id: id) }
                }
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .sheet(isPresented: $showRecordEditor) {
            if let table = db.selectedTable {
                DatabaseRecordEditor(
                    fields: table.fields,
                    existingRow: editingRow
                ) { values in
                    Task {
                        if let row = editingRow, let id = rowId(row) {
                            await db.updateRecord(id: id, values: values)
                        } else {
                            await db.insertRecord(values: values)
                        }
                    }
                }
            }
        }
        .onAppear {
            guard let project = appState.activeProject else { return }
            hasBackend = FileManager.default.fileExists(atPath: project.path + "/package.json")
            guard hasBackend else { return }
            // Already connected to this project — nothing to do
            guard db.connectedProjectId != project.id || db.connectionStatus != .connected else { return }
            Task {
                // Wait for project setup to finish
                while appState.projectSetup.isSettingUp
                        && appState.projectSetup.setupProjectId == project.id {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard appState.projectSetup.errorMessage == nil else { return }
                await db.startAndConnect(projectId: project.id, projectPath: project.path)
            }
        }
        .onChange(of: db.selectedTable) {
            db.currentPage = 0
            db.sortField = nil
            db.searchText = ""
            Task { await db.loadRows() }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    statusDot

                    switch db.connectionStatus {
                    case .connected:
                        Text(backend.baseURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .connecting:
                        statusLabel
                    case .error:
                        if let err = db.errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    case .disconnected:
                        Text("Disconnected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }

            ToolbarItem(placement: .primaryAction) {
                switch db.connectionStatus {
                case .connected:
                    Button { db.disconnect() } label: {
                        Text("Disconnect").padding(.horizontal, 4)
                    }
                    .controlSize(.small)
                case .error:
                    if let project = appState.activeProject, hasBackend {
                        Button {
                            Task { await db.startAndConnect(projectId: project.id, projectPath: project.path) }
                        } label: {
                            Text("Retry").padding(.horizontal, 4)
                        }
                        .controlSize(.small)
                    }
                case .disconnected:
                    if let project = appState.activeProject, hasBackend {
                        Button {
                            Task { await db.startAndConnect(projectId: project.id, projectPath: project.path) }
                        } label: {
                            Text("Start Backend").padding(.horizontal, 4)
                        }
                        .controlSize(.small)
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            switch backend.status {
            case .migrating:
                Text("Running migrations...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .starting:
                Text("Starting backend...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                Text("Connecting...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch db.connectionStatus {
        case .connected: .green
        case .connecting: .orange
        case .error: .red
        case .disconnected: .gray
        }
    }

    // MARK: - Table List Sidebar

    private var tableListSidebar: some View {
        VStack(spacing: 0) {
            if let schema = db.schema {
                DatabaseTableList(dbManager: db, tables: schema.tables)
            }
        }
        .frame(width: 200)
    }

    // MARK: - Data Toolbar

    private var dataToolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search...", text: Binding(
                get: { db.searchText },
                set: { db.searchText = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)
            .onSubmit {
                db.currentPage = 0
                Task { await db.loadRows() }
            }

            Spacer()

            Button {
                editingRow = nil
                showRecordEditor = true
            } label: {
                Image(systemName: "plus")
            }
            .help("Add Record")

            Button {
                Task { await db.loadRows() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Data Grid

    private let colWidth: CGFloat = 150
    private let actionsWidth: CGFloat = 50
    private let rowHeight: CGFloat = 32
    private let borderColor = Color.white.opacity(0.08)

    private var dataGrid: some View {
        let columns = db.selectedTable?.fields ?? []
        let totalWidth = actionsWidth + CGFloat(columns.count) * colWidth

        return ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                headerRow(columns: columns, totalWidth: totalWidth)

                // Rows
                if db.rows.isEmpty {
                    Text("No records")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: totalWidth, height: 60)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(db.rows.enumerated()), id: \.offset) { index, row in
                            dataRow(row, columns: columns, index: index)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func headerRow(columns: [TeenybaseField], totalWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Actions header
            Color.clear
                .frame(width: actionsWidth, height: rowHeight)
                .overlay(alignment: .trailing) {
                    borderColor.frame(width: 1)
                }

            ForEach(Array(columns.enumerated()), id: \.element.id) { i, field in
                Button {
                    if db.sortField == field.name {
                        db.sortAscending.toggle()
                    } else {
                        db.sortField = field.name
                        db.sortAscending = true
                    }
                    Task { await db.loadRows() }
                } label: {
                    HStack(spacing: 3) {
                        Text(field.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if db.sortField == field.name {
                            Image(systemName: db.sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: colWidth, height: rowHeight, alignment: .leading)
                    .padding(.leading, 8)
                    .overlay(alignment: .trailing) {
                        if i < columns.count - 1 {
                            borderColor.frame(width: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: totalWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            borderColor.frame(height: 1)
        }
    }

    private func dataRow(_ row: TableRow, columns: [TeenybaseField], index: Int) -> some View {
        let totalWidth = actionsWidth + CGFloat(columns.count) * colWidth

        return HStack(spacing: 0) {
            // Actions cell
            HStack(spacing: 6) {
                Button {
                    editingRow = row
                    showRecordEditor = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    deleteRowId = rowId(row)
                    showDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .frame(width: actionsWidth, height: rowHeight)
            .overlay(alignment: .trailing) {
                borderColor.frame(width: 1)
            }

            // Data cells
            ForEach(Array(columns.enumerated()), id: \.element.id) { i, field in
                let value = row[field.name]
                Text(value?.description ?? "NULL")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(value == nil || value == .null ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: colWidth, height: rowHeight, alignment: .leading)
                    .padding(.leading, 8)
                    .overlay(alignment: .trailing) {
                        if i < columns.count - 1 {
                            borderColor.frame(width: 1)
                        }
                    }
            }
        }
        .frame(width: totalWidth)
        .background(index % 2 == 0 ? Color.clear : Color.white.opacity(0.02))
        .overlay(alignment: .bottom) {
            borderColor.frame(height: 1)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Pagination

    private var paginationBar: some View {
        HStack {
            Text("\(db.totalRows) records")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            let totalPages = max(1, (db.totalRows + db.pageSize - 1) / db.pageSize)

            Button {
                db.currentPage = max(0, db.currentPage - 1)
                Task { await db.loadRows() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(db.currentPage == 0)

            Text("Page \(db.currentPage + 1) of \(totalPages)")
                .font(.caption)
                .monospacedDigit()

            Button {
                db.currentPage = min(totalPages - 1, db.currentPage + 1)
                Task { await db.loadRows() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(db.currentPage >= totalPages - 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cylinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            if db.connectionStatus == .connecting {
                statusLabel
            } else if db.connectionStatus == .error {
                Text("Connection Failed")
                    .font(.headline)
                if let err = db.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                if let project = appState.activeProject, hasBackend {
                    Button {
                        Task { await db.startAndConnect(projectId: project.id, projectPath: project.path) }
                    } label: {
                        Text("Retry")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            } else if !hasBackend {
                Text("Database Inspector")
                    .font(.headline)
                Text("Select a project with a Teenybase backend to get started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Database Inspector")
                    .font(.headline)
                Text("Click Start Backend to launch the database server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func rowId(_ row: TableRow) -> String? {
        if let v = row["id"] { return v.description }
        if let v = row["record_uid"] { return v.description }
        return nil
    }
}
