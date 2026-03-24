import SwiftUI

struct DashboardView: View {
    @Bindable var appState: AppState

    private var projects: [Project] { appState.projectManager.projects }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Stat cards
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 12
                ) {
                    statCard(title: "Live on Store", value: "\(liveCount)", color: .green, icon: "checkmark.seal.fill")
                    statCard(title: "Pending Review", value: "\(pendingCount)", color: .orange, icon: "clock.fill")
                    statCard(title: "Rejected Apps", value: "\(rejectedCount)", color: .red, icon: "xmark.seal.fill")
                }

                // App grid header
                HStack {
                    Text("My Apps")
                        .font(.title3.weight(.semibold))
                    Spacer()
                }

                // App grid
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(projects) { project in
                        appCard(project: project)
                            .onTapGesture {
                                selectProject(project)
                            }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            Button {
                appState.showNewProjectSheet = true
            } label: {
                Label("Create App", systemImage: "plus")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(20)
        }
        .task {
            if projects.isEmpty {
                await appState.projectManager.loadProjects()
            }
        }
    }

    // MARK: - Stat Card

    private func statCard(title: String, value: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - App Card

    private func appCard(project: Project) -> some View {
        let isSelected = project.id == appState.activeProjectId

        return VStack(spacing: 8) {
            appIconView(project: project)
                .frame(width: 56, height: 56)

            Text(project.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            Text(project.metadata.bundleIdentifier ?? project.type.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }

    private func appIconView(project: Project) -> some View {
        Group {
            if let icon = Self.loadAppIcon(projectId: project.id) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(projectColor(project).opacity(0.15))
                    Image(systemName: projectIcon(project))
                        .font(.system(size: 24))
                        .foregroundStyle(projectColor(project))
                }
            }
        }
    }

    // MARK: - Actions

    private func selectProject(_ project: Project) {
        let storage = ProjectStorage()
        storage.updateLastOpened(projectId: project.id)
        appState.activeProjectId = project.id
    }

    // MARK: - Stats (placeholder counts from project metadata)

    private var liveCount: Int {
        // Placeholder — real implementation would query ASC per project
        0
    }

    private var pendingCount: Int {
        0
    }

    private var rejectedCount: Int {
        0
    }

    // MARK: - Helpers

    private func projectIcon(_ project: Project) -> String {
        if project.platform == .macOS { return "desktopcomputer" }
        switch project.type {
        case .reactNative: return "atom"
        case .swift: return "swift"
        case .flutter: return "bird"
        }
    }

    private func projectColor(_ project: Project) -> Color {
        switch project.type {
        case .reactNative: return .cyan
        case .swift: return .orange
        case .flutter: return .blue
        }
    }

    static func loadAppIcon(projectId: String) -> NSImage? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let blitzPath = "\(home)/.blitz/projects/\(projectId)/assets/AppIcon/icon_1024.png"
        if let image = NSImage(contentsOfFile: blitzPath) { return image }

        let projectDir = "\(home)/.blitz/projects/\(projectId)"
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: projectDir) else { return nil }
        while let file = enumerator.nextObject() as? String {
            guard file.hasSuffix("AppIcon.appiconset/Contents.json") else { continue }
            let contentsPath = "\(projectDir)/\(file)"
            guard let data = fm.contents(atPath: contentsPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = json["images"] as? [[String: Any]] else { continue }
            for entry in images {
                if let filename = entry["filename"] as? String {
                    let iconDir = (contentsPath as NSString).deletingLastPathComponent
                    if let image = NSImage(contentsOfFile: "\(iconDir)/\(filename)") { return image }
                }
            }
        }
        return nil
    }
}
