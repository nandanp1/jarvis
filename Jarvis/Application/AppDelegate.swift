import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !yieldToExistingInstance() else { return }

        NSApp.setActivationPolicy(.accessory)
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        let launchedAtLogin = ProcessInfo.processInfo.arguments.contains("--launch-at-login")
        coordinator.start(presentWindow: !launchedAtLogin)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.start(presentWindow: true)
        return true
    }

    /// Directly launching an app executable bypasses Launch Services' usual
    /// single-instance behavior. Keep the oldest Jarvis process, bring it
    /// forward, and end this duplicate before it creates audio or UI services.
    private func yieldToExistingInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existingInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != currentPID }
        guard let keeper = existingInstances.min(by: Self.launchedBefore) else { return false }

        keeper.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.terminate(nil)
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
