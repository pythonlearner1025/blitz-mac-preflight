import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsService
    @Bindable var appState: AppState
    var mcpServer: MCPServerService?

    @State private var showClearCredentialsConfirm = false

    private let gateableCategories: [(ApprovalRequest.ToolCategory, String)] = [
        (.ascFormMutation, "ASC form editing"),
        (.ascScreenshotMutation, "ASC screenshot upload"),
        (.ascSubmitMutation, "ASC submit for review"),
        (.buildPipeline, "Build pipeline"),
        (.projectMutation, "Project mutations"),
        (.settingsMutation, "Settings mutations"),
        (.simulatorControl, "Simulator control"),
    ]

    var body: some View {
        Form {
            Section("Simulator") {
                Toggle("Show Cursor Overlay", isOn: $settings.showCursor)

                if settings.showCursor {
                    HStack {
                        Text("Cursor Size")
                        Slider(value: $settings.cursorSize, in: 10...40, step: 2)
                        Text("\(Int(settings.cursorSize))px")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section("Permissions") {
                Toggle("Auto-navigate to tab on tool call", isOn: $settings.autoNavEnabled)
                    .onChange(of: settings.autoNavEnabled) { _, _ in settings.save() }

                Toggle("Approve all", isOn: Binding(
                    get: {
                        gateableCategories.allSatisfy { settings.permissionToggles[$0.0.rawValue] ?? false }
                    },
                    set: { newValue in
                        for (category, _) in gateableCategories {
                            settings.permissionToggles[category.rawValue] = newValue
                        }
                        settings.save()
                    }
                ))
                .fontWeight(.medium)

                ForEach(gateableCategories, id: \.0.rawValue) { category, label in
                    Toggle(label, isOn: Binding(
                        get: { settings.permissionToggles[category.rawValue] ?? false },
                        set: { newValue in
                            settings.permissionToggles[category.rawValue] = newValue
                            settings.save()
                        }
                    ))
                }
            }

            MCPSetupSection(mcpServer: mcpServer)

            Section("Updates") {
                UpdateSettingsRow(autoUpdate: appState.autoUpdate)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("App Store Connect Credentials")
                        Spacer()
                        if appState.ascManager.credentials != nil {
                            Text("Configured")
                                .font(.callout)
                                .foregroundStyle(.green)
                        } else {
                            Text("Not set")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Clear Credentials", role: .destructive) {
                        showClearCredentialsConfirm = true
                    }
                    .disabled(appState.ascManager.credentials == nil)

                    Text("This will remove your saved API key, Key ID, and Issuer ID. You will need to re-enter them to use App Store Connect features.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Danger Zone")
            }
            .confirmationDialog(
                "Clear App Store Connect Credentials?",
                isPresented: $showClearCredentialsConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Credentials", role: .destructive) {
                    if let projectId = appState.ascManager.loadedProjectId {
                        appState.ascManager.deleteCredentials(projectId: projectId)
                    }
                }
            } message: {
                Text("This action cannot be undone. You will need to re-enter your API credentials to access App Store Connect data.")
            }

            Section("About") {
                HStack {
                    Text("Blitz")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
