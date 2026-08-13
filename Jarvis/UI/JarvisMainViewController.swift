import AppKit

final class JarvisMainViewController: NSViewController {
    var onTalk: (() -> Void)?
    var onStop: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let orbView = AmbientOrbView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "JARVIS")
    private let statusLabel = NSTextField(labelWithString: "Listening")
    private let promptLabel = NSTextField(labelWithString: "Say \"Hey Jarvis\"")
    private let transcriptLabel = NSTextField(wrappingLabelWithString: "")
    private let responseLabel = NSTextField(wrappingLabelWithString: "")
    private let talkButton = NSButton(title: "Talk to Jarvis", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Jarvis Settings", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "")
    private var clockTimer: Timer?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = JarvisTheme.background.cgColor
        view = root
        buildInterface()
        update(state: .idle, userText: nil, jarvisText: nil, detail: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startClock()
    }

    deinit {
        clockTimer?.invalidate()
    }

    func update(state: AssistantState, userText: String?, jarvisText: String?, detail: String?) {
        guard isViewLoaded else { return }
        orbView.update(state: state)
        statusLabel.stringValue = detail ?? state.statusText
        statusLabel.textColor = state == .error ? JarvisTheme.danger : (state == .executing ? JarvisTheme.success : JarvisTheme.accent)
        promptLabel.stringValue = state.promptText
        talkButton.title = state == .listening ? "Stop Listening" : "Talk to Jarvis"

        if let userText = userText, !userText.isEmpty {
            transcriptLabel.stringValue = "YOU\n\(userText)"
        }
        if let jarvisText = jarvisText, !jarvisText.isEmpty {
            responseLabel.stringValue = "JARVIS\n\(jarvisText)"
        }
    }

    private func buildInterface() {
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .withinWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 28
        visualEffect.layer?.borderWidth = 1
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        nameLabel.font = NSFont.systemFont(ofSize: 28, weight: .light)
        nameLabel.textColor = JarvisTheme.primaryText
        nameLabel.alignment = .center
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.alignment = .center
        promptLabel.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        promptLabel.textColor = JarvisTheme.secondaryText
        promptLabel.alignment = .center
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .light)
        timeLabel.textColor = JarvisTheme.secondaryText
        timeLabel.alignment = .center

        transcriptLabel.font = NSFont.systemFont(ofSize: 14)
        transcriptLabel.textColor = JarvisTheme.secondaryText
        transcriptLabel.maximumNumberOfLines = 3
        responseLabel.font = NSFont.systemFont(ofSize: 15)
        responseLabel.textColor = JarvisTheme.primaryText
        responseLabel.maximumNumberOfLines = 5

        talkButton.bezelStyle = .rounded
        talkButton.target = self
        talkButton.action = #selector(talkPressed)
        talkButton.keyEquivalent = "\r"
        settingsButton.bezelStyle = .inline
        settingsButton.isBordered = false
        settingsButton.contentTintColor = JarvisTheme.secondaryText
        settingsButton.target = self
        settingsButton.action = #selector(settingsPressed)

        [visualEffect, orbView, nameLabel, statusLabel, promptLabel, transcriptLabel, responseLabel, talkButton, settingsButton, timeLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        view.addSubview(visualEffect)
        [timeLabel, orbView, nameLabel, statusLabel, promptLabel, transcriptLabel, responseLabel, talkButton, settingsButton].forEach(visualEffect.addSubview)

        NSLayoutConstraint.activate([
            visualEffect.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            visualEffect.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            visualEffect.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            visualEffect.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),

            timeLabel.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 24),
            timeLabel.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),

            orbView.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 20),
            orbView.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
            orbView.widthAnchor.constraint(equalToConstant: 128),
            orbView.heightAnchor.constraint(equalToConstant: 128),

            nameLabel.topAnchor.constraint(equalTo: orbView.bottomAnchor, constant: 12),
            nameLabel.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 10),
            statusLabel.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
            promptLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            promptLabel.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),

            transcriptLabel.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 32),
            transcriptLabel.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -32),
            transcriptLabel.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 26),
            responseLabel.leadingAnchor.constraint(equalTo: transcriptLabel.leadingAnchor),
            responseLabel.trailingAnchor.constraint(equalTo: transcriptLabel.trailingAnchor),
            responseLabel.topAnchor.constraint(equalTo: transcriptLabel.bottomAnchor, constant: 14),

            talkButton.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
            talkButton.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -16),
            talkButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            settingsButton.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
            settingsButton.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -18)
        ])
    }

    private func startClock() {
        clockTimer?.invalidate()
        updateClock()
        clockTimer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(updateClock), userInfo: nil, repeats: true)
    }

    @objc private func updateClock() {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        timeLabel.stringValue = formatter.string(from: Date())
    }

    @objc private func talkPressed() {
        if talkButton.title == "Stop Listening" { onStop?() } else { onTalk?() }
    }

    @objc private func settingsPressed() {
        onOpenSettings?()
    }
}

