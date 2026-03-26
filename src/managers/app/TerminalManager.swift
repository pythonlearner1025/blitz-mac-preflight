import Foundation
import AppKit
import SwiftTerm

/// A single terminal session backed by a pseudo-terminal process.
/// The `terminalView` is created once and reused across show/hide cycles.
@MainActor
final class TerminalSession: Identifiable {
    let id = UUID()
    var title: String
    let terminalView: LocalProcessTerminalView
    private(set) var isTerminated = false

    private var delegateProxy: TerminalSessionDelegateProxy?

    init(title: String, projectPath: String?, onTerminated: @escaping (UUID) -> Void, onTitleChanged: @escaping (UUID, String) -> Void) {
        self.title = title

        let termView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        termView.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        termView.nativeForegroundColor = NSColor.white
        termView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        self.terminalView = termView

        let proxy = TerminalSessionDelegateProxy()
        let sessionId = id
        proxy.onTerminated = { onTerminated(sessionId) }
        proxy.onTitleChanged = { newTitle in onTitleChanged(sessionId, newTitle) }
        self.delegateProxy = proxy
        termView.processDelegate = proxy

        let cwd: String
        if let path = projectPath, FileManager.default.fileExists(atPath: path) {
            cwd = path
        } else {
            cwd = FileManager.default.homeDirectoryForCurrentUser.path
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        let authEnvironment = ASCAuthBridge().environmentOverrides(forLaunchPath: projectPath)
        for (key, value) in authEnvironment {
            env[key] = value
        }
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        termView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: envPairs,
            execName: "-\((shell as NSString).lastPathComponent)",
            currentDirectory: cwd
        )
    }

    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        terminalView.terminate()
    }

    func markTerminated() {
        isTerminated = true
    }

    /// Send a command string to the shell (types it and presses Enter).
    func sendCommand(_ command: String) {
        guard !isTerminated else { return }
        let data = Array((command + "\n").utf8)
        terminalView.send(source: terminalView, data: data[...])
    }
}

/// Bridges SwiftTerm delegate callbacks to closures for TerminalSession.
private class TerminalSessionDelegateProxy: NSObject, LocalProcessTerminalViewDelegate {
    var onTerminated: (() -> Void)?
    var onTitleChanged: ((String) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { self.onTitleChanged?(title) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { self.onTerminated?() }
    }
}

/// Manages terminal session lifecycle. Lives on AppState to persist across all views.
@MainActor
@Observable
final class TerminalManager {
    var sessions: [TerminalSession] = []
    var activeSessionId: UUID?

    private var sessionCounter = 0

    var activeSession: TerminalSession? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    @discardableResult
    func createSession(projectPath: String?) -> TerminalSession {
        sessionCounter += 1
        let session = TerminalSession(
            title: "Terminal \(sessionCounter)",
            projectPath: projectPath,
            onTerminated: { [weak self] id in
                self?.sessions.first { $0.id == id }?.markTerminated()
            },
            onTitleChanged: { [weak self] id, newTitle in
                self?.sessions.first { $0.id == id }?.title = newTitle
            }
        )
        sessions.append(session)
        activeSessionId = session.id
        return session
    }

    func closeSession(_ id: UUID) {
        sessions.first { $0.id == id }?.terminate()
        sessions.removeAll { $0.id == id }
        if activeSessionId == id {
            activeSessionId = sessions.last?.id
        }
    }

    func closeAllSessions() {
        sessions.forEach { $0.terminate() }
        sessions.removeAll()
        activeSessionId = nil
        sessionCounter = 0
    }
}
