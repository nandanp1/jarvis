import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !reopenExistingInstance() else { return }

        startPrimaryInstance(presentWindow: !launchedAtLogin)
    }

    private var launchedAtLogin: Bool {
        ProcessInfo.processInfo.arguments.contains("--launch-at-login")
    }

    private func startPrimaryInstance(presentWindow: Bool) {
        if let coordinator = coordinator {
            coordinator.start(presentWindow: presentWindow)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start(presentWindow: presentWindow)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        startPrimaryInstance(presentWindow: true)
        return true
    }

    /// Directly launching an app executable bypasses Launch Services' usual
    /// single-instance behavior. Ask Launch Services to reopen the oldest
    /// Jarvis process so its applicationShouldHandleReopen callback creates a
    /// window even when that process started headlessly at login.
    private func reopenExistingInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existingInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != currentPID }
        guard !existingInstances.isEmpty else { return false }

        // Every concurrently launching process must elect the same winner.
        // Including this process prevents two new copies from each selecting
        // the other and both terminating.
        let candidates = existingInstances + [NSRunningApplication.current]
        guard let keeper = candidates.min(by: Self.launchedBefore),
              keeper.processIdentifier != currentPID else { return false }

        // A login agent must never bring a deliberately headless instance's
        // window forward. It simply yields to whichever Jarvis is already up.
        if launchedAtLogin {
            NSApp.terminate(nil)
            return true
        }

        guard let applicationURL = keeper.bundleURL else {
            // A bundle-backed app should always have a URL. If Launch Services
            // cannot identify it, retire the unusable process and let this copy
            // become the visible primary instance.
            _ = keeper.terminate()
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) {
            [weak self, weak keeper] reopenedApplication, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if error == nil,
                   let keeper = keeper,
                   reopenedApplication?.processIdentifier == keeper.processIdentifier,
                   !keeper.isTerminated {
                    NSApp.terminate(nil)
                    return
                }

                JarvisLog.error("Jarvis could not reopen an existing instance; starting the requested copy")
                _ = keeper?.terminate()
                self.startPrimaryInstance(presentWindow: true)
            }
        }
        return true
    }

    private static func launchedBefore(_ lhs: NSRunningApplication, _ rhs: NSRunningApplication) -> Bool {
        switch (lhs.launchDate, rhs.launchDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        return lhs.processIdentifier < rhs.processIdentifier
    }
}
