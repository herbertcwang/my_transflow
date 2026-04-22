import Foundation
import AppKit

/// Log severity levels.
enum LogLevel: String, Sendable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

/// Lightweight logger with multi-level support, file persistence, and in-memory cache.
///
/// - One log file per app launch, named `yyyy-MM-dd_HH-mm-ss.log`.
/// - Supports info / warning / error levels.
/// - In-memory ring buffer for quick export without re-reading disk.
/// - Thread-safe via a serial DispatchQueue; all I/O is async and non-blocking.
/// - Automatically cleans up old log files (keeps the most recent 20).
final class ErrorLogger: Sendable {
    static let shared = ErrorLogger()

    private let maxLogFiles = 20
    private let queue = DispatchQueue(label: "com.transflow.logger", qos: .utility)
    private let state: LoggerState

    /// The URL of the `logs/` directory.
    let logsDirectory: URL

    // MARK: - Init

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.transflow"
        let logsDir = appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        self.logsDirectory = logsDir

        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "\(formatter.string(from: Date())).log"
        let fileURL = logsDir.appendingPathComponent(filename)

        let header = Self.buildHeader()
        try? header.write(to: fileURL, atomically: true, encoding: .utf8)

        let handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
        self.state = LoggerState(handle: handle)

        queue.async { [logsDir, maxLogFiles] in
            Self.cleanupOldLogs(in: logsDir, keeping: maxLogFiles)
        }
    }

    deinit {
        state.handle?.closeFile()
    }

    // MARK: - Public API

    /// Legacy entry point — logs at error level by default.
    func log(_ message: String, source: String, file: String = #fileID, line: Int = #line) {
        write(message, level: .error, source: source, file: file, line: line)
    }

    func info(_ message: String, source: String, file: String = #fileID, line: Int = #line) {
        write(message, level: .info, source: source, file: file, line: line)
    }

    func warning(_ message: String, source: String, file: String = #fileID, line: Int = #line) {
        write(message, level: .warning, source: source, file: file, line: line)
    }

    func error(_ message: String, source: String, file: String = #fileID, line: Int = #line) {
        write(message, level: .error, source: source, file: file, line: line)
    }

    /// Returns the most recent log lines from the in-memory cache (newest last).
    func recentLines(limit: Int = 500) -> [String] {
        queue.sync {
            Array(state.cachedLines.suffix(limit))
        }
    }

    /// Exports recent logs to a temporary file and returns its URL.
    func exportLogs(limit: Int = 2000) -> URL? {
        let lines = queue.sync { Array(state.cachedLines.suffix(limit)) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "transflow-log-\(formatter.string(from: Date())).log"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        let content = Self.buildHeader() + lines.joined(separator: "\n")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Open the logs directory in Finder.
    @MainActor
    func openLogsFolder() {
        NSWorkspace.shared.open(logsDirectory)
    }

    // MARK: - Private

    private func write(_ message: String, level: LogLevel, source: String, file: String, line: Int) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let entry = "[\(timestamp)] [\(level.rawValue)] [\(source)] \(message)  (\(file):\(line))"

        #if DEBUG
        print(entry)
        #endif

        queue.async { [state] in
            state.cachedLines.append(entry)
            if state.cachedLines.count > state.maxCachedLines {
                state.cachedLines.removeFirst(state.cachedLines.count - state.maxCachedLines)
            }

            guard let handle = state.handle,
                  let data = (entry + "\n").data(using: .utf8) else { return }
            handle.write(data)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func buildHeader() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return """
        ──────────────────────────────────────
        TransFlow Log
        Version: \(version) (\(build))
        macOS: \(os)
        Launch: \(Date())
        ──────────────────────────────────────

        """
    }

    private nonisolated static func cleanupOldLogs(in directory: URL, keeping maxFiles: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let logFiles = files
            .filter { $0.pathExtension == "log" }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return dateA > dateB
            }

        if logFiles.count > maxFiles {
            for file in logFiles.dropFirst(maxFiles) {
                try? fm.removeItem(at: file)
            }
        }
    }
}

// MARK: - Thread-safe State Wrapper

private final class LoggerState: @unchecked Sendable {
    let handle: FileHandle?
    var cachedLines: [String] = []
    let maxCachedLines = 5000

    init(handle: FileHandle?) {
        self.handle = handle
    }
}
