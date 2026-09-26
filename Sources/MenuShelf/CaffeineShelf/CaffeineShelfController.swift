//
//  CaffeineShelfController.swift
//  MenuShelf
//
//  Single integration seam between MenuShelf and the CaffeineShelf module.
//  Owns the IOKit power assertion that keeps the Mac awake, the optional
//  expiry timer, and the optional battery / Low Power Mode auto-off monitors.
//  Everything outside `Sources/MenuShelf/CaffeineShelf/` talks to this
//  controller (and `CaffeineShelfMenu`) and nothing else from the module.
//
//  Sleep is prevented with `IOPMAssertionCreateWithName` rather than by
//  spawning `/usr/bin/caffeinate`: MenuShelf is sandboxed, and the assertion
//  is the exact same mechanism caffeinate uses internally — no subprocess and
//  no entitlement required.
//

import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

@MainActor
final class CaffeineShelfController {
    static let shared = CaffeineShelfController()

    private init() {}

    // MARK: - Internal state

    /// Whether the Mac is currently being kept awake by this module.
    private(set) var isActive = false

    /// The live power-assertion identifier. Only valid while `hasAssertion`.
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var hasAssertion = false

    /// One-shot timer that ends the session at `fireDate`. Nil for indefinite
    /// sessions or while inactive.
    private var expiryTimer: Timer?

    /// When the current timed session ends, or `nil` for an indefinite session
    /// (or while inactive). Surfaced to the menu as "Awake until …".
    private(set) var fireDate: Date?

    /// Duration (in seconds) of the current session, or `nil` while inactive.
    /// `0` means indefinite. Lets the menu check the matching duration row (and
    /// the "Off" row when this is `nil`).
    private(set) var activeDurationSeconds: TimeInterval?

    /// Snapshot of the last settings passed through `apply(settings:)`.
    private var lastAppliedSettings: CaffeineShelfSettings?

    /// IOKit power-source change notification source. Alive only while active
    /// and battery auto-off is enabled.
    private var batteryRunLoopSource: CFRunLoopSource?

    /// Low Power Mode observer token. Alive only while active and Low Power
    /// Mode auto-off is enabled.
    private var lowPowerObserver: NSObjectProtocol?

    /// Whether we currently hold the `disablesleep` system flag, so quit can
    /// clear it. Tracked separately from the persisted setting because the flag
    /// is a global system state we must not leave on.
    private var lidFlagApplied = false

    // MARK: - Lifecycle

    /// Idempotent. Records the settings snapshot so the module is ready to
    /// activate. Does not keep the Mac awake on its own — activation is an
    /// explicit user action (menu toggle / duration pick / hotkey).
    func start(with settings: CaffeineShelfSettings) {
        apply(settings: settings)
    }

    /// Release the assertion, cancel the timer, drop the monitors, and clear
    /// the cached settings. Always safe to call (also called on app quit so
    /// the assertion never outlives the process).
    func stop() {
        deactivate()
        lastAppliedSettings = nil
    }

    /// Push a new settings snapshot through. When `enableCaffeineShelf` is
    /// `false` this collapses to `deactivate()`. When active, it re-evaluates
    /// the assertion type (`allowDisplaySleep` may have changed), re-arms the
    /// auto-off monitors, and immediately checks the auto-off conditions in
    /// case a newly enabled guard already applies.
    func apply(settings: CaffeineShelfSettings) {
        let previous = lastAppliedSettings
        lastAppliedSettings = settings

        guard settings.enableCaffeineShelf else {
            deactivate()
            return
        }

        guard isActive else { return }

        if previous?.allowDisplaySleep != settings.allowDisplaySleep {
            // Swap the assertion to the new type without dropping awake state.
            releaseAssertion()
            createAssertion()
        }
        reconcileMonitors()
        evaluateAutoOff()
    }

    // MARK: - Activation

    /// One-line status shown as a disabled info row while active, or `nil`.
    var menuStatusDescription: String? {
        guard isActive else { return nil }
        guard let fireDate else { return "Awake indefinitely" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "Awake until \(formatter.string(from: fireDate))"
    }

    /// Toggle awake state. Turning on uses the configured default duration.
    func toggle() {
        if isActive {
            deactivate()
        } else {
            let seconds = lastAppliedSettings?.defaultDurationSeconds
                ?? CaffeineShelfSettings.defaults.defaultDurationSeconds
            activate(durationSeconds: seconds)
        }
    }

    /// Begin (or restart) keeping the Mac awake. `durationSeconds == 0` (or
    /// `nil`) keeps it awake indefinitely; any positive value arms a one-shot
    /// expiry timer. No-ops when the feature is disabled.
    func activate(durationSeconds: TimeInterval?) {
        guard lastAppliedSettings?.enableCaffeineShelf ?? false else { return }

        createAssertion()
        isActive = true
        activeDurationSeconds = durationSeconds ?? 0

        expiryTimer?.invalidate()
        expiryTimer = nil
        fireDate = nil

        if let durationSeconds, durationSeconds > 0 {
            let date = Date().addingTimeInterval(durationSeconds)
            fireDate = date
            let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleExpiry() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            expiryTimer = timer
        }

        reconcileMonitors()
        updateStatusItemTint()
        // Guard against activating while already below threshold / in Low Power
        // Mode — auto-off should fire immediately, not only on the next change.
        evaluateAutoOff()

        // Engage lid-closed coverage only if the session survived the auto-off
        // check and the user enabled it.
        if isActive, lidClosedModeEnabled {
            applyLidFlag(true)
        }

        logIfVerbose("CaffeineShelf activate duration=\(Int(durationSeconds ?? 0))")
    }

    /// End the session: cancel the timer, release the assertion, drop monitors,
    /// and clear the active tint. Safe to call when already inactive.
    func deactivate() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        fireDate = nil
        activeDurationSeconds = nil

        releaseAssertion()
        let wasActive = isActive
        isActive = false

        teardownMonitors()
        updateStatusItemTint()

        // Always clear the lid-closed system flag if we set it, so a closed-lid
        // session never outlives the awake state.
        if lidFlagApplied {
            applyLidFlag(false)
        }

        if wasActive {
            logIfVerbose("CaffeineShelf deactivate")
        }
    }

    private func handleExpiry() {
        guard isActive else { return }
        deactivate()
    }

    // MARK: - Lid-closed mode

    /// Whether keep-awake-with-lid-closed is currently enabled (persisted).
    var lidClosedModeEnabled: Bool {
        AppContainer.shared.store.settings.resolvedCaffeineShelf.resolvedKeepAwakeWithLidClosed
    }

    /// Toggle the persisted lid-closed mode. Enabling first ensures the one-time
    /// privileged grant is installed (showing the native admin sheet); if that
    /// is declined the setting stays off. When a session is already active the
    /// system flag is applied/cleared immediately.
    func setLidClosedMode(_ enabled: Bool) {
        let store = AppContainer.shared.store

        guard enabled else {
            store.setKeepAwakeWithLidClosed(false)
            if lidFlagApplied { applyLidFlag(false) }
            return
        }

        Task { @MainActor in
            var granted = await Task.detached {
                CaffeineShelfLidControl.isGrantInstalled()
            }.value

            // Explain before macOS asks. Reaching the authorization sheet with no
            // context is jarring from the menu path, where — unlike Settings —
            // there is no surrounding copy warning that approval is coming.
            if !granted {
                guard confirmLidGrantInstall() else {
                    store.setKeepAwakeWithLidClosed(false)
                    logIfVerbose("CaffeineShelf lid-closed setup declined before authorization")
                    return
                }
                granted = await Task.detached {
                    CaffeineShelfLidControl.installGrant()
                }.value
            }

            guard granted else {
                store.setKeepAwakeWithLidClosed(false)
                logIfVerbose("CaffeineShelf lid-closed grant declined")
                return
            }
            store.setKeepAwakeWithLidClosed(true)
            if isActive { applyLidFlag(true) }
        }
    }

    /// One-time explainer shown before the native authorization sheet. Returns
    /// `true` when the user wants to continue.
    @MainActor
    private func confirmLidGrantInstall() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Keep your Mac awake with the lid closed"
        alert.informativeText = """
            This flips a protected macOS setting (pmset disablesleep), so it needs \
            your permission once. macOS will ask you to authenticate with Touch ID \
            or your password. After that the switch works instantly, with no \
            further prompts.

            MenuShelf grants itself permission to run only two exact commands — \
            turning lid-close sleep off and back on — and nothing else. You can \
            revoke it any time from CaffeineShelf settings.
            """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Reconcile our in-memory flag after the grant is removed from Settings.
    /// The caller clears `disablesleep` before removing the grant, so here we
    /// only sync local state.
    func notifyLidGrantRemoved() {
        lidFlagApplied = false
    }

    /// One-time crash recovery at launch: if our grant is installed and the
    /// `disablesleep` flag is still set from a previous run that crashed before
    /// clearing it, reset it. Runs entirely off the main thread.
    func healLidStateAtLaunch() {
        Task.detached {
            guard CaffeineShelfLidControl.isGrantInstalled(),
                  CaffeineShelfLidControl.readSleepDisabled() else { return }
            _ = CaffeineShelfLidControl.setDisableSleep(false)
        }
    }

    /// Clear the `disablesleep` flag if we set it, so a normal quit never leaves
    /// the Mac unable to sleep. Called from `applicationWillTerminate`.
    ///
    /// The reset now runs in the separate helper process, which outlives us, so
    /// we only need to block long enough for the launch to be handed to
    /// LaunchServices — not for the reset to finish. The short timeout keeps quit
    /// responsive; if it elapses the helper still completes the reset on its own.
    func flushLidStateForQuit() {
        guard lidFlagApplied else { return }
        _ = CaffeineShelfLidControl.setDisableSleep(false, timeout: 3)
        lidFlagApplied = false
    }

    /// Set or clear the `disablesleep` system flag off the main thread, tracking
    /// whether we hold it. If the grant has vanished while turning it on, reflect
    /// that by switching the persisted setting back off.
    private func applyLidFlag(_ on: Bool) {
        lidFlagApplied = on
        Task.detached {
            let result = CaffeineShelfLidControl.setDisableSleep(on)
            if on, result == .grantMissing {
                await MainActor.run {
                    AppContainer.shared.store.setKeepAwakeWithLidClosed(false)
                    self.lidFlagApplied = false
                }
            }
        }
    }

    // MARK: - Power assertion

    /// Create the power assertion for the current `allowDisplaySleep` setting.
    /// Releases any existing assertion first so the type can never leak.
    private func createAssertion() {
        releaseAssertion()

        let allowDisplaySleep = lastAppliedSettings?.allowDisplaySleep ?? false
        let type = allowDisplaySleep
            ? kIOPMAssertionTypePreventUserIdleSystemSleep
            : kIOPMAssertionTypePreventUserIdleDisplaySleep

        var id: IOPMAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MenuShelf CaffeineShelf — keeping the Mac awake" as CFString,
            &id
        )

        if result == kIOReturnSuccess {
            assertionID = id
            hasAssertion = true
        } else {
            hasAssertion = false
            logIfVerbose("CaffeineShelf assertion create failed result=\(result)")
        }
    }

    private func releaseAssertion() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        hasAssertion = false
        assertionID = IOPMAssertionID(0)
    }

    // MARK: - Auto-off monitors

    /// Start/stop the battery and Low Power Mode monitors to match the current
    /// settings. Monitors run only while active so an idle module costs nothing.
    private func reconcileMonitors() {
        guard isActive else {
            teardownMonitors()
            return
        }
        let settings = lastAppliedSettings ?? .defaults

        if settings.batteryAutoOffEnabled {
            startBatteryMonitor()
        } else {
            stopBatteryMonitor()
        }

        if settings.lowPowerModeAutoOffEnabled {
            startLowPowerMonitor()
        } else {
            stopLowPowerMonitor()
        }
    }

    private func teardownMonitors() {
        stopBatteryMonitor()
        stopLowPowerMonitor()
    }

    /// Deactivate when any enabled auto-off condition is currently met. Safe to
    /// call any time; no-ops when inactive.
    private func evaluateAutoOff() {
        guard isActive else { return }
        let settings = lastAppliedSettings ?? .defaults

        if settings.batteryAutoOffEnabled,
           Self.isRunningOnBattery(),
           let capacity = Self.currentBatteryCapacityPercent(),
           capacity <= settings.resolvedBatteryThresholdPercent {
            logIfVerbose("CaffeineShelf auto-off battery=\(Int(capacity))")
            deactivate()
            return
        }

        if settings.lowPowerModeAutoOffEnabled,
           ProcessInfo.processInfo.isLowPowerModeEnabled {
            logIfVerbose("CaffeineShelf auto-off lowPowerMode")
            deactivate()
        }
    }

    private func startBatteryMonitor() {
        guard batteryRunLoopSource == nil else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { rawContext in
            guard let rawContext else { return }
            let controller = Unmanaged<CaffeineShelfController>
                .fromOpaque(rawContext)
                .takeUnretainedValue()
            Task { @MainActor in controller.evaluateAutoOff() }
        }

        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        batteryRunLoopSource = source
    }

    private func stopBatteryMonitor() {
        guard let source = batteryRunLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        batteryRunLoopSource = nil
    }

    private func startLowPowerMonitor() {
        guard lowPowerObserver == nil else { return }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluateAutoOff() }
        }
    }

    private func stopLowPowerMonitor() {
        guard let observer = lowPowerObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        lowPowerObserver = nil
    }

    // MARK: - IOKit power-source reads

    /// Current battery charge as a percentage (`0...100`), or `nil` when the
    /// device has no battery or the read fails.
    private static func currentBatteryCapacityPercent() -> Double? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?
                .takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
               let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
               maximum > 0 {
                return current / maximum * 100.0
            }
        }
        return nil
    }

    /// Whether the primary power source is currently the battery (discharging).
    private static func isRunningOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?
                .takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSBatteryPowerValue
            }
        }
        return false
    }

    // MARK: - Status item

    /// Reflect the active state on the menu-bar icon (accent tint when awake).
    private func updateStatusItemTint() {
        AppContainer.shared.statusItemManager.setStandaloneModuleActiveIndicator(
            kind: .caffeineShelf,
            isActive: isActive
        )
    }

    // MARK: - Verbose diagnostics

    /// Forward `message` to the shared logger only when the user has opted into
    /// verbose diagnostics. Mirrors `ClockShelfController.logIfVerbose(_:)`.
    private func logIfVerbose(_ message: String) {
        guard AppContainer.shared.store.settings
            .resolvedEnableVerboseDiagnostics else { return }
        DiagnosticsLogger.shared.log(message)
    }
}
