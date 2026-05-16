import Foundation
import AppKit

enum DefaultBrowserSwitchResult {
    case success
    case userKeptPrevious(currentBrowserName: String)
    case partialFailure(httpChanged: Bool, httpsChanged: Bool, diagnostics: SwitchDiagnostics)
    case browserUnavailable
    case timeout(diagnostics: SwitchDiagnostics)
    case systemError(Error, diagnostics: SwitchDiagnostics)
}

enum DefaultBrowserError: LocalizedError {
    case failedToSetHTTP(OSStatus)
    case failedToSetHTTPS(OSStatus)
    case verificationFailed
    case permissionDenied
    case apiError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .failedToSetHTTP(let status):
            return "Failed to set default browser for HTTP (Error: \(status))"
        case .failedToSetHTTPS(let status):
            return "Failed to set default browser for HTTPS (Error: \(status))"
        case .verificationFailed:
            return "macOS did not accept the default browser change."
        case .permissionDenied:
            return "macOS blocked the change. This usually happens with unsigned apps."
        case .apiError(let msg):
            return "System API error: \(msg)"
        case .timeout:
            return "The operation timed out waiting for macOS confirmation."
        }
    }
}

struct SwitchDiagnostics {
    let selectedBrowserName: String
    let selectedBrowserBundleID: String
    let selectedBrowserAppURL: String
    let httpHandlerBefore: String
    let httpsHandlerBefore: String
    let httpHandlerAfter: String
    let httpsHandlerAfter: String
    let errorDescription: String?
    let macOSVersion: String
    let isSandboxed: Bool

    var report: String {
        var lines = [String]()
        lines.append("Browser Flip Diagnostics Report")
        lines.append("================================")
        lines.append("macOS Version: \(macOSVersion)")
        lines.append("Sandboxed: \(isSandboxed)")
        lines.append("")
        lines.append("Selected Browser:")
        lines.append("  Name: \(selectedBrowserName)")
        lines.append("  Bundle ID: \(selectedBrowserBundleID)")
        lines.append("  Path: \(selectedBrowserAppURL)")
        lines.append("")
        lines.append("HTTP Handler:")
        lines.append("  Before: \(httpHandlerBefore)")
        lines.append("  After: \(httpHandlerAfter)")
        lines.append("")
        lines.append("HTTPS Handler:")
        lines.append("  Before: \(httpsHandlerBefore)")
        lines.append("  After: \(httpsHandlerAfter)")
        lines.append("")
        lines.append("Error: \(errorDescription ?? "None")")
        return lines.joined(separator: "\n")
    }
}

struct BrowserInfo: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let appURL: URL
    var isVisible: Bool
    var sortOrder: Int

    init(id: String, name: String, appURL: URL, isVisible: Bool = true, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.appURL = appURL
        self.isVisible = isVisible
        self.sortOrder = sortOrder
    }

    static func == (lhs: BrowserInfo, rhs: BrowserInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

final class DefaultBrowserService {
    static let shared = DefaultBrowserService()

    private init() {}

    // MARK: - Read Current Default

    func currentDefaultBrowserID() -> String? {
        guard let probe = URL(string: "http://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundle = Bundle(url: appURL),
              let bundleID = bundle.bundleIdentifier else {
            return nil
        }
        return bundleID
    }

    func currentDefaultBrowserName() -> String? {
        guard let probe = URL(string: "http://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            return nil
        }
        let bundle = Bundle(url: appURL)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    func handlerForScheme(_ scheme: String) -> (bundleID: String, name: String, url: URL)? {
        guard let probe = URL(string: "\(scheme)://example.com"),
              let url = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            return nil
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (bundleID, name, url)
    }

    // MARK: - Set Default Browser

    func setDefaultBrowser(_ browser: BrowserInfo) async -> DefaultBrowserSwitchResult {
        guard FileManager.default.fileExists(atPath: browser.appURL.path) else {
            return .browserUnavailable
        }

        let httpBefore = handlerForScheme("http")
        let httpsBefore = handlerForScheme("https")

        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }

        do {
            try Task.checkCancellation()
            try await setDefaultWithTimeout(browser: browser, scheme: "http")

            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)

            let httpAfter1 = handlerForScheme("http")
            let httpsAfter1 = handlerForScheme("https")

            let httpChanged1 = httpAfter1?.bundleID == browser.id
            let httpsChanged1 = httpsAfter1?.bundleID == browser.id

            if httpChanged1 && httpsChanged1 {
                return .success
            }

            try Task.checkCancellation()

            if !httpsChanged1 {
                do {
                    try await setDefaultWithTimeout(browser: browser, scheme: "https")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    DiagnosticsLogger.shared.log("BrowserFlip: HTTPS set callback reported error: \(error.localizedDescription)")
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

            let httpAfter2 = handlerForScheme("http")
            let httpsAfter2 = handlerForScheme("https")

            let httpChanged2 = httpAfter2?.bundleID == browser.id
            let httpsChanged2 = httpsAfter2?.bundleID == browser.id

            let finalDiagnostics = SwitchDiagnostics(
                selectedBrowserName: browser.name,
                selectedBrowserBundleID: browser.id,
                selectedBrowserAppURL: browser.appURL.path,
                httpHandlerBefore: httpBefore?.bundleID ?? "unknown",
                httpsHandlerBefore: httpsBefore?.bundleID ?? "unknown",
                httpHandlerAfter: httpAfter2?.bundleID ?? "unknown",
                httpsHandlerAfter: httpsAfter2?.bundleID ?? "unknown",
                errorDescription: nil,
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                isSandboxed: isSandboxed()
            )

            if httpChanged2 && httpsChanged2 {
                return .success
            } else if !httpChanged2 && !httpsChanged2 {
                let currentName = httpAfter2?.name ?? httpsAfter2?.name ?? "previous browser"
                return .userKeptPrevious(currentBrowserName: currentName)
            } else {
                return .partialFailure(httpChanged: httpChanged2, httpsChanged: httpsChanged2, diagnostics: finalDiagnostics)
            }

        } catch let error as DefaultBrowserError {
            if case .timeout = error {
                let timeoutDiagnostics = SwitchDiagnostics(
                    selectedBrowserName: browser.name,
                    selectedBrowserBundleID: browser.id,
                    selectedBrowserAppURL: browser.appURL.path,
                    httpHandlerBefore: httpBefore?.bundleID ?? "unknown",
                    httpsHandlerBefore: httpsBefore?.bundleID ?? "unknown",
                    httpHandlerAfter: handlerForScheme("http")?.bundleID ?? "unknown",
                    httpsHandlerAfter: handlerForScheme("https")?.bundleID ?? "unknown",
                    errorDescription: "Timeout waiting for user confirmation",
                    macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    isSandboxed: isSandboxed()
                )
                return .timeout(diagnostics: timeoutDiagnostics)
            } else {
                let errorDiagnostics = SwitchDiagnostics(
                    selectedBrowserName: browser.name,
                    selectedBrowserBundleID: browser.id,
                    selectedBrowserAppURL: browser.appURL.path,
                    httpHandlerBefore: httpBefore?.bundleID ?? "unknown",
                    httpsHandlerBefore: httpsBefore?.bundleID ?? "unknown",
                    httpHandlerAfter: handlerForScheme("http")?.bundleID ?? "unknown",
                    httpsHandlerAfter: handlerForScheme("https")?.bundleID ?? "unknown",
                    errorDescription: error.localizedDescription,
                    macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    isSandboxed: isSandboxed()
                )
                return .systemError(error, diagnostics: errorDiagnostics)
            }
        } catch {
            let errorDiagnostics = SwitchDiagnostics(
                selectedBrowserName: browser.name,
                selectedBrowserBundleID: browser.id,
                selectedBrowserAppURL: browser.appURL.path,
                httpHandlerBefore: httpBefore?.bundleID ?? "unknown",
                httpsHandlerBefore: httpsBefore?.bundleID ?? "unknown",
                httpHandlerAfter: handlerForScheme("http")?.bundleID ?? "unknown",
                httpsHandlerAfter: handlerForScheme("https")?.bundleID ?? "unknown",
                errorDescription: error.localizedDescription,
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                isSandboxed: isSandboxed()
            )
            return .systemError(error, diagnostics: errorDiagnostics)
        }
    }

    // MARK: - Browser Discovery

    func discoverBrowsers() -> [BrowserInfo] {
        guard let probeURL = URL(string: "https://example.com") else { return [] }
        var browsersByID: [String: BrowserInfo] = [:]

        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: probeURL)

        for appURL in appURLs {
            guard let bundle = Bundle(url: appURL),
                  let bundleID = bundle.bundleIdentifier else {
                continue
            }

            let name = resolveBrowserName(for: bundle, appURL: appURL)

            browsersByID[bundleID] = BrowserInfo(
                id: bundleID,
                name: name,
                appURL: appURL
            )
        }

        var browsersByName: [String: BrowserInfo] = [:]
        for browser in browsersByID.values {
            let key = browser.name.lowercased()
            if let existing = browsersByName[key] {
                browsersByName[key] = pickBetterBrowser(existing, browser)
            } else {
                browsersByName[key] = browser
            }
        }

        return browsersByName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Private Helpers

    private final class ResumeGuard: @unchecked Sendable {
        private var consumed = false
        private let lock = NSLock()

        func tryConsume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }

    private func setDefaultWithTimeout(browser: BrowserInfo, scheme: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let guardState = ResumeGuard()

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if guardState.tryConsume() {
                    continuation.resume(throwing: DefaultBrowserError.timeout)
                }
            }

            NSWorkspace.shared.setDefaultApplication(
                at: browser.appURL,
                toOpenURLsWithScheme: scheme
            ) { error in
                timeoutTask.cancel()
                guard guardState.tryConsume() else { return }

                if let error = error as NSError? {
                    if error.domain == NSOSStatusErrorDomain && error.code == -128 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func isSandboxed() -> Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private func pickBetterBrowser(_ a: BrowserInfo, _ b: BrowserInfo) -> BrowserInfo {
        let aInApplications = a.appURL.path.hasPrefix("/Applications/")
        let bInApplications = b.appURL.path.hasPrefix("/Applications/")

        if aInApplications && !bInApplications { return a }
        if bInApplications && !aInApplications { return b }

        if a.id.count < b.id.count { return a }
        if b.id.count < a.id.count { return b }

        return a.id <= b.id ? a : b
    }

    private func resolveBrowserName(for bundle: Bundle, appURL: URL) -> String {
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }

        if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty {
            return bundleName
        }

        return appURL.deletingPathExtension().lastPathComponent
    }
}
