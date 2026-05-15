import AppKit
import Foundation

/// Runs AppleScripts on behalf of menu clicks and URL invocations. Owns the
/// per-script running-state set so it can suppress re-entrant clicks and drive
/// the menu bar running indicator. All mutating state is touched from the main
/// thread; the public API can be invoked from any thread.
///
/// Marked `@unchecked Sendable` because all mutating state (`runningScripts`)
/// is read and written exclusively from the main thread via `runOnMain` /
/// `handleOutcome` / the watchdog `MainActor.run` block.
final class AppleScriptRunCoordinator: @unchecked Sendable {
    private let store: PreferencesStore
    private let service: AppleScriptService
    private weak var actionHandler: MenuActionHandler?

    private var runningScripts: Set<UUID> = []
    private static let timeout: Duration = .seconds(30)
    private static let timeoutMs = 30_000

    init(store: PreferencesStore, service: AppleScriptService, actionHandler: MenuActionHandler) {
        self.store = store
        self.service = service
        self.actionHandler = actionHandler
    }

    func run(scriptID: UUID, fromMenuViewID menuViewID: UUID?) {
        if Thread.isMainThread {
            runOnMain(scriptID: scriptID, fromMenuViewID: menuViewID)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.runOnMain(scriptID: scriptID, fromMenuViewID: menuViewID)
            }
        }
    }

    private func runOnMain(scriptID: UUID, fromMenuViewID menuViewID: UUID?) {
        guard let config = store.appleScript(id: scriptID) else {
            actionHandler?.showAppleScriptMissingAlert(scriptID: scriptID)
            DiagnosticsLogger.shared.log("runAppleScript suppressed: \(scriptID.uuidString) not found")
            return
        }

        guard !runningScripts.contains(scriptID) else {
            DiagnosticsLogger.shared.log("runAppleScript suppressed: \(scriptID.uuidString) already running")
            return
        }

        runningScripts.insert(scriptID)
        if let menuViewID {
            AppContainer.shared.statusItemManager.setRunningIndicator(menuViewID: menuViewID, isRunning: true)
        }
        logStart(config: config)

        let scriptName = config.name
        let source = config.source

        Task { [service] in
            let outcome = await service.run(source: source, scriptName: scriptName, timeout: Self.timeout)
            await MainActor.run {
                self.handleOutcome(scriptID: scriptID, menuViewID: menuViewID, outcome: outcome, name: scriptName)
            }
        }

        // Watchdog
        let watchdogDeadline: Duration = Self.timeout + .seconds(2)
        let coordinator = self
        Task {
            try? await Task.sleep(for: watchdogDeadline)
            await MainActor.run {
                if coordinator.runningScripts.contains(scriptID) {
                    DiagnosticsLogger.shared.log("AppleScript watchdog cleared orphaned run \(scriptID.uuidString)")
                    coordinator.runningScripts.remove(scriptID)
                    if let menuViewID {
                        AppContainer.shared.statusItemManager.setRunningIndicator(menuViewID: menuViewID, isRunning: false)
                    }
                    coordinator.store.recordAppleScriptRun(AppleScriptRunRecord(
                        scriptID: scriptID,
                        startedAt: Date(),
                        outcome: .timeout(elapsedMs: Self.timeoutMs)
                    ))
                }
            }
        }
    }

    // MARK: - Private

    private func handleOutcome(scriptID: UUID, menuViewID: UUID?, outcome: RunOutcome, name: String) {
        runningScripts.remove(scriptID)
        if let menuViewID {
            AppContainer.shared.statusItemManager.setRunningIndicator(menuViewID: menuViewID, isRunning: false)
        }

        let record: AppleScriptRunRecord
        switch outcome {
        case .success(let stringValue, let durationMs):
            record = AppleScriptRunRecord(
                scriptID: scriptID,
                startedAt: Date(),
                outcome: .success(stringValue: stringValue, durationMs: durationMs)
            )
            logFinish(name: name, scriptID: scriptID, outcome: "success", verbose: stringValue)

        case .compileFailed(let error):
            record = AppleScriptRunRecord(
                scriptID: scriptID,
                startedAt: Date(),
                outcome: .compileError(message: error.message, line: error.line)
            )
            actionHandler?.showAppleScriptCompileAlert(scriptID: scriptID, error: error, scriptName: name)
            logFinish(name: name, scriptID: scriptID, outcome: "compile error", verbose: error.message)

        case .executionFailed(let error):
            record = AppleScriptRunRecord(
                scriptID: scriptID,
                startedAt: Date(),
                outcome: .executionError(message: error.message, code: error.errorNumber)
            )
            if error.isPermissionFamily {
                actionHandler?.showAppleScriptPermissionAlert(error: error, scriptName: name)
            } else {
                actionHandler?.showAppleScriptExecutionAlert(error: error, scriptName: name)
            }
            logFinish(name: name, scriptID: scriptID, outcome: "execution error", verbose: error.message)

        case .timedOut(let elapsedMs):
            record = AppleScriptRunRecord(
                scriptID: scriptID,
                startedAt: Date(),
                outcome: .timeout(elapsedMs: elapsedMs)
            )
            actionHandler?.showAppleScriptTimeoutAlert(scriptName: name, elapsedMs: elapsedMs)
            logFinish(name: name, scriptID: scriptID, outcome: "timeout", verbose: "elapsed \(elapsedMs) ms")
        }

        store.recordAppleScriptRun(record)
    }

    private func logStart(config: AppleScriptConfig) {
        let safeName = String(config.name.prefix(256))
        let timestamp = ISO8601DateFormatter.menushelfMillis.string(from: Date())
        DiagnosticsLogger.shared.log("AppleScript run start id=\(config.id.uuidString) name=\(safeName) at=\(timestamp)")
    }

    private func logFinish(name: String, scriptID: UUID, outcome: String, verbose: String) {
        let safeName = String(name.prefix(256))
        DiagnosticsLogger.shared.log("AppleScript run finish id=\(scriptID.uuidString) name=\(safeName) outcome=\(outcome)")

        guard store.settings.resolvedEnableVerboseDiagnostics, !verbose.isEmpty else { return }
        let truncated = String(verbose.prefix(500))
        let suffix = verbose.count > 500 ? " …(\(verbose.count - 500) more)" : ""
        DiagnosticsLogger.shared.log("AppleScript verbose id=\(scriptID.uuidString): \(truncated)\(suffix)")
    }
}

private extension ISO8601DateFormatter {
    static let menushelfMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
