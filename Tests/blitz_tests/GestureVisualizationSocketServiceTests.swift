import Darwin
import Foundation
import Testing
@testable import Blitz

@Test func decodeLiveEventRejectsInvalidTapPayload() {
    let json = """
    {
      "v": 1,
      "id": "evt-1",
      "tsMs": 1774853265123,
      "source": { "client": "test" },
      "target": { "platform": "ios", "deviceId": "SIM-1" },
      "kind": "tap",
      "referenceWidth": 393,
      "referenceHeight": 852
    }
    """.data(using: .utf8)!

    #expect(GestureVisualizationEvent.decodeLiveEvent(from: json) == nil)
}

@MainActor
@Test func gestureSocketServiceReceivesLiveEventsAndDedupesByID() async throws {
    let root = URL(fileURLWithPath: "/tmp/gv-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let socketURL = root.appendingPathComponent("gesture-events.sock")
    let service = GestureVisualizationSocketService(socketURL: socketURL)
    defer { service.tearDown() }

    let tapEvent: [String: Any] = [
        "v": 1,
        "id": "evt-1",
        "tsMs": 1_774_853_265_123 as Int64,
        "source": ["client": "test-client"],
        "target": ["platform": "ios", "deviceId": "SIM-1"],
        "kind": "tap",
        "x": 120,
        "y": 240,
        "referenceWidth": 393,
        "referenceHeight": 852,
    ]

    try sendDatagram(jsonObject: tapEvent, to: socketURL)
    try sendDatagram(jsonObject: tapEvent, to: socketURL)

    for _ in 0..<50 where service.liveEvents.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(service.liveEvents.count == 1)
    #expect(service.events(for: "SIM-1").count == 1)
    #expect(service.events(for: "OTHER").isEmpty)
}

private func sendDatagram(jsonObject: [String: Any], to socketURL: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: jsonObject)
    let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
    #expect(fd >= 0)
    defer { Darwin.close(fd) }

    var address = try makeSocketAddress(path: socketURL.path)
    let addressLength = socklen_t(address.sun_len)
    let sent = data.withUnsafeBytes { buffer in
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                sendto(fd, buffer.baseAddress, buffer.count, 0, sockaddrPointer, addressLength)
            }
        }
    }

    #expect(sent == data.count)
}

private func makeSocketAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1
    guard path.utf8.count <= maxPathLength else {
        struct PathError: Error {}
        throw PathError()
    }

    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        path.withCString { source in
            destination.copyBytes(from: UnsafeRawBufferPointer(start: source, count: path.utf8.count + 1))
        }
    }
    return address
}
