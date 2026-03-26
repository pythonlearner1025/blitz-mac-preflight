import SwiftUI

/// Transparent overlay that captures touch/click events and translates to device actions
struct TouchOverlayView: View {
    let deviceConfig: SimulatorDeviceConfig
    let frameWidth: Int
    let frameHeight: Int
    let onTap: (Double, Double) -> Void
    /// (fromX, fromY, toX, toY, duration, delta)
    let onSwipe: (Double, Double, Double, Double, Double, Int) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragStartTime: Date?
    @State private var clickMarkers: [ClickMarker] = []
    @State private var swipePath: [CGPoint] = []

    struct ClickMarker: Identifiable {
        let id = UUID()
        let position: CGPoint
        var opacity: Double = 1.0
    }

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStart == nil {
                                dragStart = value.startLocation
                                dragStartTime = Date()
                            }
                            swipePath.append(value.location)
                        }
                        .onEnded { value in
                            let start = dragStart ?? value.startLocation
                            let end = value.location
                            let distance = hypot(end.x - start.x, end.y - start.y)

                            if distance < 10 {
                                // Tap
                                let (simX, simY) = SimulatorConfigDatabase.viewToSimulatorCoords(
                                    viewX: Double(end.x),
                                    viewY: Double(end.y),
                                    viewWidth: Double(geometry.size.width),
                                    viewHeight: Double(geometry.size.height),
                                    config: deviceConfig,
                                    frameWidth: frameWidth,
                                    frameHeight: frameHeight
                                )
                                onTap(simX, simY)

                                let marker = ClickMarker(position: end)
                                clickMarkers.append(marker)
                                withAnimation(.easeOut(duration: 0.5)) {
                                    if let index = clickMarkers.firstIndex(where: { $0.id == marker.id }) {
                                        clickMarkers[index].opacity = 0
                                    }
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    clickMarkers.removeAll { $0.id == marker.id }
                                }
                            } else {
                                // Swipe — match blitz-cn: pass duration + delta
                                let (startX, startY) = SimulatorConfigDatabase.viewToSimulatorCoords(
                                    viewX: Double(start.x),
                                    viewY: Double(start.y),
                                    viewWidth: Double(geometry.size.width),
                                    viewHeight: Double(geometry.size.height),
                                    config: deviceConfig,
                                    frameWidth: frameWidth,
                                    frameHeight: frameHeight
                                )
                                let (endX, endY) = SimulatorConfigDatabase.viewToSimulatorCoords(
                                    viewX: Double(end.x),
                                    viewY: Double(end.y),
                                    viewWidth: Double(geometry.size.width),
                                    viewHeight: Double(geometry.size.height),
                                    config: deviceConfig,
                                    frameWidth: frameWidth,
                                    frameHeight: frameHeight
                                )

                                // Duration = actual drag hold time in seconds
                                let duration = dragStartTime.map { Date().timeIntervalSince($0) } ?? 0.3

                                // Delta = one interpolation point per 10 simulator pixels (matches blitz-cn)
                                let simDistance = hypot(endX - startX, endY - startY)
                                let delta = max(1, Int(round(simDistance / 10)))

                                onSwipe(startX, startY, endX, endY, duration, delta)
                            }

                            dragStart = nil
                            dragStartTime = nil
                            swipePath = []
                        }
                )
                .overlay {
                    ForEach(clickMarkers) { marker in
                        Circle()
                            .stroke(.white.opacity(marker.opacity * 0.6), lineWidth: 2)
                            .frame(width: 30, height: 30)
                            .position(marker.position)
                    }

                    if swipePath.count > 1 {
                        Path { path in
                            path.move(to: swipePath[0])
                            for point in swipePath.dropFirst() {
                                path.addLine(to: point)
                            }
                        }
                        .stroke(.white.opacity(0.4), lineWidth: 2)
                    }
                }
        }
    }
}
