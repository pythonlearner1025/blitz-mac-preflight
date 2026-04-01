import Foundation

struct GestureVisualizationEvent: Codable, Equatable, Identifiable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        let client: String
        let sessionId: String?
    }

    struct Target: Codable, Equatable, Sendable {
        let platform: String
        let deviceId: String
    }

    enum Kind: String, Codable, Sendable {
        case tap
        case longpress
        case swipe
        case scroll
        case backSwipe = "back-swipe"
        case pinch
    }

    let v: Int
    let id: String
    let tsMs: Int64
    let source: Source
    let target: Target
    let kind: Kind
    let x: Double?
    let y: Double?
    let x2: Double?
    let y2: Double?
    let durationMs: Double?
    let scale: Double?
    let referenceWidth: Double
    let referenceHeight: Double
    let actionCommand: String?
    let actionIndex: Int?
    let recordingId: String?

    var isRenderableInBlitz: Bool {
        switch kind {
        case .tap, .swipe:
            return true
        default:
            return false
        }
    }

    var expiryInterval: TimeInterval {
        switch kind {
        case .tap:
            return 0.7
        case .longpress:
            return max((durationMs ?? 0) / 1_000, 0) + 0.4
        case .swipe, .scroll, .backSwipe:
            return max((durationMs ?? 0) / 1_000, 0) + 0.4
        case .pinch:
            return max((durationMs ?? 0) / 1_000, 0) + 0.4
        }
    }

    func validateForLiveRendering() -> Bool {
        guard v == 1,
              !id.isEmpty,
              !source.client.isEmpty,
              !target.platform.isEmpty,
              !target.deviceId.isEmpty,
              referenceWidth > 0,
              referenceHeight > 0 else {
            return false
        }

        switch kind {
        case .tap:
            return x != nil && y != nil
        case .longpress:
            return x != nil && y != nil && durationMs != nil
        case .swipe, .scroll, .backSwipe:
            return x != nil && y != nil && x2 != nil && y2 != nil && durationMs != nil
        case .pinch:
            return x != nil && y != nil && scale != nil && durationMs != nil
        }
    }

    static func decodeLiveEvent(from data: Data, decoder: JSONDecoder = JSONDecoder()) -> GestureVisualizationEvent? {
        guard let event = try? decoder.decode(GestureVisualizationEvent.self, from: data),
              event.validateForLiveRendering() else {
            return nil
        }
        return event
    }
}
