import Foundation

struct ShortcutInfo: Codable, Hashable, Identifiable {
    let identifier: String?
    let name: String

    var id: String { identifier ?? name }
}

struct ShortcutsFolderInfo: Codable, Hashable, Identifiable {
    let identifier: String?
    let name: String

    var id: String { identifier ?? name }
}

enum ShortcutsServiceError: LocalizedError {
    case executionFailed(message: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let message, let status):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "The shortcuts command exited with status \(status)."
            }

            if trimmed.count > 500 {
                return "\(trimmed.prefix(500))..."
            }

            return trimmed
        }
    }
}

actor ShortcutsService {
    private let shortcutsPath = "/usr/bin/shortcuts"

    func listShortcuts() async throws -> [ShortcutInfo] {
        let output = try await run(["list", "--show-identifiers"])
        return parseShortcutsWithIdentifiers(output)
    }

    func listFolders() async throws -> [ShortcutsFolderInfo] {
        let output = try await run(["list", "--folders", "--show-identifiers"])
        return parseFoldersWithIdentifiers(output)
    }

    func listShortcuts(inFolder folderName: String) async throws -> [ShortcutInfo] {
        let output = try await run(["list", "-f", folderName, "--show-identifiers"])
        return parseShortcutsWithIdentifiers(output)
    }

    func runShortcut(identifierOrName: String, textInput: String? = nil) async throws {
        _ = try await run(["run", identifierOrName, "--output-path", "/dev/null"], standardInput: textInput, captureOutput: false)
    }

    func openShortcutForEditing(identifierOrName: String) async throws {
        _ = try await run(["view", identifierOrName], captureOutput: false)
    }

    private func run(_ arguments: [String], standardInput: String? = nil, captureOutput: Bool = true) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shortcutsPath)
            process.arguments = arguments

            let outputBuffer = PipeBuffer()
            let errorBuffer = PipeBuffer()
            let drainGroup = DispatchGroup()

            // Drain each captured pipe to EOF on its own background thread.
            // `readDataToEndOfFile()` consumes incrementally as the child writes
            // (so the child never blocks on a full pipe buffer) and a single
            // reader per handle avoids the `availableData`/`readToEnd` race the
            // previous readabilityHandler approach had.
            func drain(_ pipe: Pipe, into buffer: PipeBuffer) {
                drainGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    drainGroup.leave()
                }
            }

            let outputPipe: Pipe?
            if captureOutput {
                let pipe = Pipe()
                process.standardOutput = pipe
                outputPipe = pipe
            } else {
                process.standardOutput = FileHandle.nullDevice
                outputPipe = nil
            }

            let errorPipe = Pipe()
            process.standardError = errorPipe

            let inputPipe: Pipe?
            if standardInput != nil {
                let pipe = Pipe()
                process.standardInput = pipe
                inputPipe = pipe
            } else {
                process.standardInput = FileHandle.nullDevice
                inputPipe = nil
            }

            process.terminationHandler = { process in
                // Resume only after both pipes reach EOF, so no output is lost.
                drainGroup.notify(queue: DispatchQueue.global(qos: .utility)) {
                    let output = outputBuffer.string()
                    let error = errorBuffer.string()

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        let message = error.isEmpty ? output : error
                        DiagnosticsLogger.shared.log("shortcuts \(arguments.joined(separator: " ")) failed status=\(process.terminationStatus): \(String(message.prefix(500)))")
                        continuation.resume(throwing: ShortcutsServiceError.executionFailed(message: message, status: process.terminationStatus))
                    }
                }
            }

            // Start draining before launch so the readers are ready and the
            // termination handler can never fire against an empty group.
            if let outputPipe { drain(outputPipe, into: outputBuffer) }
            drain(errorPipe, into: errorBuffer)

            do {
                try process.run()

                if let standardInput, let inputPipe, let data = standardInput.data(using: .utf8) {
                    inputPipe.fileHandleForWriting.write(data)
                    try? inputPipe.fileHandleForWriting.close()
                }
            } catch {
                // Launch failed: the child never started, so the parent still
                // holds the pipe write ends and the drain reads would block
                // forever. Close them to unblock the readers, then fail.
                outputPipe?.fileHandleForWriting.closeFile()
                errorPipe.fileHandleForWriting.closeFile()
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Thread-safe accumulator for incremental pipe reads.
private final class PipeBuffer {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let copy = data
        lock.unlock()
        return String(data: copy, encoding: .utf8) ?? ""
    }
}

func parseShortcutsWithIdentifiers(_ output: String) -> [ShortcutInfo] {
    parseNamedIdentifierLines(output).map { ShortcutInfo(identifier: $0.identifier, name: $0.name) }
}

func parseFoldersWithIdentifiers(_ output: String) -> [ShortcutsFolderInfo] {
    parseNamedIdentifierLines(output).map { ShortcutsFolderInfo(identifier: $0.identifier, name: $0.name) }
}

private let namedIdentifierRegex: NSRegularExpression = {
    // Pattern is compile-time constant; force-try is justified.
    try! NSRegularExpression(pattern: #"^(.*)\s+\(([A-Fa-f0-9-]{36})\)$"#)
}()

private func parseNamedIdentifierLines(_ output: String) -> [(name: String, identifier: String?)] {
    return output
        .split(separator: "\n")
        .compactMap { line -> (name: String, identifier: String?)? in
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            if let match = namedIdentifierRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let nameRange = Range(match.range(at: 1), in: text),
               let idRange = Range(match.range(at: 2), in: text) {
                return (String(text[nameRange]), String(text[idRange]))
            }

            return (text, nil)
        }
}
