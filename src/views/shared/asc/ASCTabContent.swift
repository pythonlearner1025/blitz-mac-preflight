import SwiftUI

/// Wraps a tab's content with loading, error, and empty-app states.
struct ASCTabContent<Content: View>: View {
    var asc: ASCManager
    var tab: AppTab
    var platform: ProjectPlatform = .iOS
    @ViewBuilder var content: () -> Content

    private var isLoading: Bool {
        asc.isLoadingTab[tab] == true || asc.isLoadingApp
    }

    private var shouldRenderOverviewWhileLoading: Bool {
        tab == .app && asc.credentials != nil
    }

    var body: some View {
        if isLoading && !shouldRenderOverviewWhileLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading\u{2026}")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if asc.app == nil && asc.credentials != nil && !isLoading {
            // App not found — show bundle ID setup instead of flashing content
            BundleIDSetupView(asc: asc, tab: tab, platform: platform)
        } else if let error = asc.tabError[tab] {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button("Retry") {
                    Task { await asc.refreshTabData(tab) }
                }
                .buttonStyle(.bordered)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content()
                .overlay(alignment: .topTrailing) {
                    if isLoading && shouldRenderOverviewWhileLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.background.secondary, in: Capsule())
                            .padding(12)
                    }
                }
        }
    }
}

/// Reusable info row for detail views.
struct InfoRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

/// Formats an ISO 8601 date string for display.
func ascShortDate(_ iso: String) -> String {
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let f2 = ISO8601DateFormatter()
    if let d = f1.date(from: iso) ?? f2.date(from: iso) {
        return d.formatted(date: .abbreviated, time: .omitted)
    }
    return iso
}

/// Formats an ISO 8601 date string with time.
func ascLongDate(_ iso: String) -> String {
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let f2 = ISO8601DateFormatter()
    if let d = f1.date(from: iso) ?? f2.date(from: iso) {
        return d.formatted(date: .abbreviated, time: .shortened)
    }
    return iso
}

/// Converts HTML to plain text using NSAttributedString, with regex fallback.
func htmlToPlainText(_ html: String) -> String {
    if let data = html.data(using: .utf8),
       let attributed = try? NSAttributedString(
           data: data,
           options: [
               .documentType: NSAttributedString.DocumentType.html,
               .characterEncoding: String.Encoding.utf8.rawValue,
           ],
           documentAttributes: nil
       ) {
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Regex fallback: strip tags
    return html
        .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
