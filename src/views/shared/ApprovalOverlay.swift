import SwiftUI

/// Modifier kept for API compatibility — approval is now handled via NSAlert in MCPExecutor.
struct ApprovalAlertModifier: ViewModifier {
    @Bindable var appState: AppState

    func body(content: Content) -> some View {
        content
    }
}

extension View {
    func approvalAlert(appState: AppState) -> some View {
        modifier(ApprovalAlertModifier(appState: appState))
    }
}
