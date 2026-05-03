import Foundation

final class DiagnosticsLogger {
    static let shared = DiagnosticsLogger()

    let logURL: URL
    private let formatter: ISO8601DateFormatter

    private init() {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("MenuShelf", isDirectory: true)

        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        logURL = supportURL.appendingPathComponent("diagnostics.log")

        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: [.atomic])
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: logURL)
    }
}
