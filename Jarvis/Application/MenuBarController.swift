import AppKit

final class MenuBarController: NSObject {
    var onTalk: (() -> Void)?
    var onStopListening: (() -> Void)?
    var onOpenJarvis: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onClearConversation: (() -> Void)?
    var onToggleLaunchAtLogin: ((Bool) -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let stateItem = NSMenuItem(title: "● Listening", action: nil, keyEquivalent: "")
    private let lastRequestItem = NSMenuItem(title: "Last request: —", action: nil, keyEquivalent: "")
    private let deviceItem = NSMenuItem(title: "Smart Home: Not configured", action: nil, keyEquivalent: "")
    private let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let talkItem = NSMenuItem(title: "Talk to Jarvis", action: #selector(talk), keyEquivalent: "t")
    private let stopItem = NSMenuItem(title: "Stop Listening", action: #selector(stopListening), keyEquivalent: "")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
    }

    func update(state: AssistantState, lastRequest: String?, deviceCount: Int?) {
        stateItem.title = "● \(state.statusText)"
        stateItem.isEnabled = false
        lastRequestItem.title = "Last request: \(lastRequest.map { "\"\($0)\"" } ?? "—")"
        lastRequestItem.isEnabled = false
        if let count = deviceCount {
            deviceItem.title = "Smart Home: \(count) device\(count == 1 ? "" : "s") connected"
        }
        stopItem.isHidden = state != .listening
        talkItem.isHidden = state == .listening
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        launchItem.state = enabled ? .on : .off
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.title = "◆ Jarvis"
            button.toolTip = "Jarvis"
        }

        let menu = NSMenu(title: "Jarvis")
        [stateItem, .separator(), talkItem, stopItem, lastRequestItem, .separator()].forEach(menu.addItem)
        menu.addItem(actionItem("Open Jarvis", action: #selector(openJarvis), key: "j"))
        menu.addItem(actionItem("Jarvis Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(deviceItem)
        menu.addItem(actionItem("Clear Conversation", action: #selector(clearConversation), key: ""))
        launchItem.target = self
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit Jarvis", action: #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func actionItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func talk() { onTalk?() }
    @objc private func stopListening() { onStopListening?() }
    @objc private func openJarvis() { onOpenJarvis?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func clearConversation() { onClearConversation?() }
    @objc private func quit() { onQuit?() }
    @objc private func toggleLaunchAtLogin() {
        onToggleLaunchAtLogin?(launchItem.state != .on)
    }
}

