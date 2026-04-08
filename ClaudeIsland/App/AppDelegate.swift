import AppKit
import IOKit
import Mixpanel
import os.log
import Sparkle
import SwiftUI

final class AppBootstrapCoordinator {
    static let shared = AppBootstrapCoordinator()

    private init() {}

    /// This is the one app-level seam for provider setup.
    /// Codex wiring plugs in here next without creating a second startup path.
    var enabledProviders: [ProviderKind] {
        [.claude, .codex]
    }

    func bootstrapIntegrations() {
        if enabledProviders.contains(.claude) || enabledProviders.contains(.codex) {
            HookInstaller.installIfNeeded()
        }
        if enabledProviders.contains(.codex) {
            CodexTelemetryInstaller.installIfNeeded()
            CodexTelemetryServer.shared.start()
        }
    }

    func stopRuntimeServices() {
        if enabledProviders.contains(.codex) {
            CodexTelemetryServer.shared.stop()
        }
    }

    func uninstallConfiguredIntegrations() {
        stopRuntimeServices()
        if enabledProviders.contains(.claude) || enabledProviders.contains(.codex) {
            HookInstaller.uninstall()
        }
        if enabledProviders.contains(.codex) {
            CodexTelemetryInstaller.uninstall()
        }
    }

    func areConfiguredIntegrationsInstalled() -> Bool {
        let claudeInstalled = !enabledProviders.contains(.claude) || HookInstaller.isClaudeInstalled()
        let codexInstalled = !enabledProviders.contains(.codex) || (HookInstaller.isCodexInstalled() && CodexTelemetryInstaller.isInstalled())
        return claudeInstalled && codexInstalled
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private enum QuitIntentKeys {
        static let timestamp = "app.quitIntent.timestamp"
        static let bundleID = "app.quitIntent.bundleID"
        static let executablePath = "app.quitIntent.executablePath"
    }

    private let logger = Logger(subsystem: "com.claudeisland", category: "AppLifecycle")
    private let relaunchSuppressionWindow: TimeInterval = 4
    private let legacyBundleIdentifiers = ["com.celestial.ClaudeIsland"]
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var updateCheckTimer: Timer?

    static var shared: AppDelegate?
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

    override init() {
        userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )
        super.init()
        AppDelegate.shared = self

        do {
            try updater.start()
        } catch {
            print("Failed to start Sparkle updater: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if shouldSuppressUnexpectedRelaunch() {
            logger.notice("Suppressing immediate relaunch after user-requested quit")
            NSApplication.shared.terminate(nil)
            DispatchQueue.main.async {
                exit(0)
            }
            return
        }

        terminateLegacyInstances()

        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        clearQuitIntent()

        Mixpanel.initialize(token: "49814c1436104ed108f3fc4735228496")

        let distinctId = getOrCreateDistinctId()
        Mixpanel.mainInstance().identify(distinctId: distinctId)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersionString

        Mixpanel.mainInstance().registerSuperProperties([
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        fetchAndRegisterClaudeVersion()

        Mixpanel.mainInstance().people.set(properties: [
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        Mixpanel.mainInstance().track(event: "App Launched")
        Mixpanel.mainInstance().flush()

        AppBootstrapCoordinator.shared.bootstrapIntegrations()
        NSApplication.shared.setActivationPolicy(.accessory)

        windowManager = WindowManager()
        _ = windowManager?.setupNotchWindow()

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let updater = self?.updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdates()
        }
    }

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Mixpanel.mainInstance().flush()
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
        screenObserver = nil
        windowManager?.tearDown()
        windowManager = nil
        AppBootstrapCoordinator.shared.stopRuntimeServices()
    }

    @MainActor
    func requestFullQuit() {
        recordQuitIntent()
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
        screenObserver = nil
        windowManager?.tearDown()
        windowManager = nil
        AppBootstrapCoordinator.shared.stopRuntimeServices()
        Mixpanel.mainInstance().flush()

        NSApplication.shared.terminate(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            exit(0)
        }
    }

    private func getOrCreateDistinctId() -> String {
        let key = "mixpanel_distinct_id"

        if let existingId = UserDefaults.standard.string(forKey: key) {
            return existingId
        }

        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        if let uuid = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            UserDefaults.standard.set(uuid, forKey: key)
            return uuid
        }

        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    private func fetchAndRegisterClaudeVersion() {
        let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var latestFile: URL?
        var latestDate: Date?

        for projectDir in projectDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" && !file.lastPathComponent.hasPrefix("agent-") {
                if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = attrs.contentModificationDate {
                    if latestDate == nil || modDate > latestDate! {
                        latestDate = modDate
                        latestFile = file
                    }
                }
            }
        }

        guard let jsonlFile = latestFile,
              let handle = FileHandle(forReadingAtPath: jsonlFile.path) else { return }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 8192)
        guard let content = String(data: data, encoding: .utf8) else { return }

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let version = json["version"] as? String else { continue }

            Mixpanel.mainInstance().registerSuperProperties(["claude_code_version": version])
            Mixpanel.mainInstance().people.set(properties: ["claude_code_version": version])
            return
        }
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.celestial.CodexIsland"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }

    private func recordQuitIntent() {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: QuitIntentKeys.timestamp)
        defaults.set(Bundle.main.bundleIdentifier, forKey: QuitIntentKeys.bundleID)
        defaults.set(Bundle.main.executablePath, forKey: QuitIntentKeys.executablePath)
        logger.notice("Recorded quit intent for bundle \(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public)")
    }

    private func clearQuitIntent() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: QuitIntentKeys.timestamp)
        defaults.removeObject(forKey: QuitIntentKeys.bundleID)
        defaults.removeObject(forKey: QuitIntentKeys.executablePath)
    }

    private func shouldSuppressUnexpectedRelaunch() -> Bool {
        let defaults = UserDefaults.standard
        guard let timestamp = defaults.object(forKey: QuitIntentKeys.timestamp) as? Double else {
            return false
        }

        let quitAge = Date().timeIntervalSince1970 - timestamp
        guard quitAge >= 0, quitAge <= relaunchSuppressionWindow else {
            clearQuitIntent()
            return false
        }

        let recordedBundleID = defaults.string(forKey: QuitIntentKeys.bundleID)
        let recordedExecutablePath = defaults.string(forKey: QuitIntentKeys.executablePath)
        let currentBundleID = Bundle.main.bundleIdentifier
        let currentExecutablePath = Bundle.main.executablePath

        let matchesCurrentIdentity = recordedBundleID == currentBundleID &&
            recordedExecutablePath == currentExecutablePath

        if matchesCurrentIdentity {
            logger.notice("Detected relaunch \(quitAge, privacy: .public)s after quit for \(currentBundleID ?? "unknown", privacy: .public)")
            clearQuitIntent()
            return true
        }

        clearQuitIntent()
        return false
    }

    private func terminateLegacyInstances() {
        let runningApps = NSWorkspace.shared.runningApplications
        for legacyBundleID in legacyBundleIdentifiers {
            let legacyApps = runningApps.filter { $0.bundleIdentifier == legacyBundleID }
            guard !legacyApps.isEmpty else { continue }

            logger.notice("Terminating \(legacyApps.count, privacy: .public) legacy app instance(s) for \(legacyBundleID, privacy: .public)")
            for app in legacyApps {
                _ = app.terminate()
            }
        }
    }
}
