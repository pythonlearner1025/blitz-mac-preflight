import SwiftUI

struct AppTabView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Top navbar
            topNavbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            // Sub-tab content
            subTabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Top Navbar

    private var topNavbar: some View {
        HStack(spacing: 2) {
            ForEach(AppSubTab.allCases) { tab in
                Button {
                    appState.activeAppSubTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11))
                        Text(tab.label)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        appState.activeAppSubTab == tab
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                    .foregroundStyle(
                        appState.activeAppSubTab == tab
                            ? Color.accentColor
                            : Color.secondary
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Sub-tab Content

    @ViewBuilder
    private var subTabContent: some View {
        switch appState.activeAppSubTab {
        case .overview:
            ASCOverview(appState: appState)
        case .simulator:
            SimulatorView(appState: appState)
        case .database:
            DatabaseView(appState: appState)
        case .tests:
            TestsView(appState: appState)
        case .icon:
            AssetsView(appState: appState)
        }
    }
}
