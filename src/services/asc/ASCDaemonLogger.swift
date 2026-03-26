import Foundation

actor ASCDaemonLogger {
    static let shared = ASCDaemonLogger()

    private let fileManager = FileManager.default
    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    init() {
        let home = fileManager.homeDirectoryForCurrentUser
        self.logURL = home.appendingPathComponent(".blitz/logs/ascd-client.log")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
    }

    func info(_ message: String) async {
        await write(level: "INFO", message: message)
    }

    func error(_ message: String) async {
        await write(level: "ERROR", message: message)
    }

    func debug(_ message: String) async {
        await write(level: "DEBUG", message: message)
    }

    private func write(level: String, message: String) async {
        let directoryURL = logURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if fileManager.fileExists(atPath: logURL.path) {
            do {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? data.write(to: logURL, options: .atomic)
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
