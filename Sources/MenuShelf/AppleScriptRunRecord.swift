import Foundation

/// In-memory record of the most recent run of an AppleScript during the
/// current app session. Not persisted to disk.
struct AppleScriptRunRecord: Equatable {
    enum Outcome: Equatable {
        case success(stringValue: String, durationMs: Int)
        case compileError(message: String, line: Int?)
        case executionError(message: String, code: Int)
        case timeout(elapsedMs: Int)
    }

    let scriptID: UUID
    let startedAt: Date
    let outcome: Outcome

    var summary: String {
        switch outcome {
        case .success(_, let ms):
            return "Success in \(ms) ms"
        case .compileError(let message, let line):
            if let line {
                return "Compile error on line \(line): \(message)"
            }
            return "Compile error: \(message)"
        case .executionError(let message, let code):
            return "Execution error \(code): \(message)"
        case .timeout(let ms):
            return "Timed out after \(ms) ms"
        }
    }

    var detail: String {
        switch outcome {
        case .success(let stringValue, _):
            return stringValue.isEmpty ? "(no return value)" : stringValue
        case .compileError(let message, _):
            return message
        case .executionError(let message, _):
            return message
        case .timeout:
            return "Script timed out before completing."
        }
    }

    var isSuccess: Bool {
        if case .success = outcome { return true }
        return false
    }
}
