import SwiftUI

/// A split view that keeps a **stable view hierarchy** regardless of orientation.
/// Switching between bottom/right only changes frame sizes — child views are never
/// destroyed or recreated, which preserves terminal NSView rendering state.
struct TerminalSplitView<Content: View, Panel: View>: View {
    let isHorizontal: Bool
    let showPanel: Bool
    @Binding var panelSize: CGFloat
    let minPanelSize: CGFloat
    let minContentSize: CGFloat
    @ViewBuilder let content: () -> Content
    @ViewBuilder let panel: () -> Panel

    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let total = isHorizontal ? geo.size.width : geo.size.height
            let raw = showPanel ? panelSize + dragOffset : 0
            let clamped = max(minPanelSize, min(raw, total - minContentSize))
            let divider: CGFloat = showPanel ? 1 : 0
            let contentSize = showPanel ? total - clamped - divider : total

            // Always the same ZStack → stable view identity for both children
            ZStack(alignment: .topLeading) {
                // Content — pinned to top-left
                content()
                    .frame(
                        width: isHorizontal ? contentSize : geo.size.width,
                        height: isHorizontal ? geo.size.height : contentSize
                    )

                if showPanel {
                    // Divider + Panel group
                    ZStack(alignment: .topLeading) {
                        // Divider line
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(
                                width: isHorizontal ? 1 : geo.size.width,
                                height: isHorizontal ? geo.size.height : 1
                            )

                        // Drag hit area (invisible, wider than the 1px line)
                        Color.clear
                            .frame(
                                width: isHorizontal ? 9 : geo.size.width,
                                height: isHorizontal ? geo.size.height : 9
                            )
                            .offset(x: isHorizontal ? -4 : 0, y: isHorizontal ? 0 : -4)
                            .contentShape(Rectangle())
                            .cursor(isHorizontal ? .resizeLeftRight : .resizeUpDown)
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .updating($dragOffset) { value, state, _ in
                                        state = isHorizontal ? -value.translation.width : -value.translation.height
                                    }
                                    .onEnded { value in
                                        let delta = isHorizontal ? -value.translation.width : -value.translation.height
                                        panelSize = max(minPanelSize, min(panelSize + delta, total - minContentSize))
                                    }
                            )

                        // Panel
                        panel()
                            .frame(
                                width: isHorizontal ? clamped : geo.size.width,
                                height: isHorizontal ? geo.size.height : clamped
                            )
                            .offset(x: isHorizontal ? divider : 0, y: isHorizontal ? 0 : divider)
                    }
                    .offset(
                        x: isHorizontal ? contentSize : 0,
                        y: isHorizontal ? 0 : contentSize
                    )
                }
            }
        }
    }
}

// MARK: - Cursor

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
