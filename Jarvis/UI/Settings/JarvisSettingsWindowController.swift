import AppKit

final class JarvisSettingsWindowController: NSWindowController {
    let contentController: JarvisSettingsViewController

    init(dependencies: JarvisSettingsDependencies = .live()) {
        contentController = JarvisSettingsViewController(dependencies: dependencies)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Jarvis Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = JarvisTheme.background
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 620, height: 620)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("JarvisSettingsWindow")
        window.contentViewController = contentController

        super.init(window: window)
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        contentController.reloadFromPreferences()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
