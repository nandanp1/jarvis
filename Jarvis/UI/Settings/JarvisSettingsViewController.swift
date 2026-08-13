import AppKit

final class JarvisSettingsViewController: NSViewController {
    private let dependencies: JarvisSettingsDependencies

    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch Jarvis at login", target: nil, action: nil)
    private let startListeningCheckbox = NSButton(checkboxWithTitle: "Start listening automatically", target: nil, action: nil)
    private let wakePhraseField = NSTextField(string: "")

    private let voiceEnabledCheckbox = NSButton(checkboxWithTitle: "Speak Jarvis responses", target: nil, action: nil)
    private let voicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let speakingRateSlider = NSSlider(value: 175, minValue: 90, maxValue: 320, target: nil, action: nil)
    private let speakingRateLabel = NSTextField(labelWithString: "175 wpm")
    private let activationSoundCheckbox = NSButton(checkboxWithTitle: "Play a subtle sound when Jarvis activates", target: nil, action: nil)

    private let geminiAPIKeyField = NSSecureTextField(frame: .zero)
    private let geminiModelField = NSTextField(string: "")
    private let geminiTestButton = NSButton(title: "Test Connection", target: nil, action: nil)
    private let geminiProgress = NSProgressIndicator()
    private let geminiStatusLabel = JarvisSettingsUI.statusLabel()

    private let homeAssistantURLField = NSTextField(string: "")
    private let homeAssistantTokenField = NSSecureTextField(frame: .zero)
    private let homeAssistantTestButton = NSButton(title: "Test Connection", target: nil, action: nil)
    private let deviceRefreshButton = NSButton(title: "Refresh Devices", target: nil, action: nil)
    private let homeAssistantProgress = NSProgressIndicator()
    private let homeAssistantStatusLabel = JarvisSettingsUI.statusLabel()
    private let connectedDevicesView = JarvisConnectedDevicesView(frame: .zero)

    private let saveButton = NSButton(title: "Save Settings", target: nil, action: nil)
    private let saveStatusLabel = JarvisSettingsUI.statusLabel()

    private var voices: [JarvisSettingsDependencies.Voice] = []

    init(dependencies: JarvisSettingsDependencies) {
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = JarvisTheme.background.cgColor
        view = root

        configureControls()
        buildInterface()
        reloadFromPreferences()
    }

    func reloadFromPreferences() {
        guard isViewLoaded else { return }
        let preferences = dependencies.preferences

        launchAtLoginCheckbox.state = dependencies.launchAtLogin.isEnabled ? .on : .off
        startListeningCheckbox.state = preferences.startListeningAutomatically ? .on : .off
        wakePhraseField.stringValue = preferences.wakePhrase

        voiceEnabledCheckbox.state = preferences.voiceEnabled ? .on : .off
        speakingRateSlider.floatValue = preferences.speakingRate
        updateSpeakingRateLabel()
        activationSoundCheckbox.state = preferences.activationSoundsEnabled ? .on : .off
        loadVoices(selectedIdentifier: preferences.voiceIdentifier)
        updateVoiceControlAvailability()

        geminiModelField.stringValue = preferences.geminiModel
        homeAssistantURLField.stringValue = preferences.homeAssistantURL
        geminiAPIKeyField.stringValue = ""
        homeAssistantTokenField.stringValue = ""
        updateCredentialPlaceholders()

        setStatus(geminiStatusLabel, message: "Connection not tested in this session.", result: nil)
        setStatus(homeAssistantStatusLabel, message: "Connection not tested in this session.", result: nil)
        saveStatusLabel.stringValue = "Changes are stored only when you choose Save Settings."
        saveStatusLabel.textColor = JarvisTheme.secondaryText
    }

    private func configureControls() {
        [launchAtLoginCheckbox, startListeningCheckbox, voiceEnabledCheckbox, activationSoundCheckbox].forEach {
            $0.font = NSFont.systemFont(ofSize: 13)
        }

        wakePhraseField.placeholderString = "Hey Jarvis"
        wakePhraseField.toolTip = "Jarvis also recognizes its name by itself."

        voiceEnabledCheckbox.target = self
        voiceEnabledCheckbox.action = #selector(voiceEnabledChanged)
        voicePopup.toolTip = "Choose one of the voices installed in macOS."

        speakingRateSlider.numberOfTickMarks = 0
        speakingRateSlider.isContinuous = true
        speakingRateSlider.target = self
        speakingRateSlider.action = #selector(speakingRateChanged)
        speakingRateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        speakingRateLabel.textColor = JarvisTheme.secondaryText
        speakingRateLabel.alignment = .right
        speakingRateLabel.widthAnchor.constraint(equalToConstant: 66).isActive = true

        geminiAPIKeyField.placeholderString = "Paste a Gemini API key"
        geminiAPIKeyField.toolTip = "Stored in macOS Keychain only after Save Settings is chosen."
        geminiModelField.placeholderString = "Gemini model identifier"

        homeAssistantURLField.placeholderString = "http://homeassistant.local:8123"
        homeAssistantTokenField.placeholderString = "Paste a long-lived access token"
        homeAssistantTokenField.toolTip = "Stored in macOS Keychain only after Save Settings is chosen."

        geminiTestButton.target = self
        geminiTestButton.action = #selector(testGeminiConnection)
        homeAssistantTestButton.target = self
        homeAssistantTestButton.action = #selector(testHomeAssistantConnection)
        deviceRefreshButton.target = self
        deviceRefreshButton.action = #selector(refreshDevices)

        [geminiProgress, homeAssistantProgress].forEach {
            $0.style = .spinning
            $0.controlSize = .small
            $0.isDisplayedWhenStopped = false
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 16).isActive = true
            $0.heightAnchor.constraint(equalToConstant: 16).isActive = true
        }

        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveSettings)
    }

    private func buildInterface() {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let documentView = JarvisFlippedView(frame: NSRect(x: 0, y: 0, width: 720, height: 1_600))
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Jarvis Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = JarvisTheme.primaryText

        let subtitleLabel = NSTextField(wrappingLabelWithString: "Configure the always-on assistant, voice, AI, and room controls. Credentials remain in your Mac's Keychain.")
        subtitleLabel.font = NSFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = JarvisTheme.secondaryText
        subtitleLabel.maximumNumberOfLines = 0

        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(subtitleLabel)
        contentStack.setCustomSpacing(5, after: titleLabel)
        contentStack.setCustomSpacing(24, after: subtitleLabel)

        [
            makeGeneralCard(),
            makeVoiceCard(),
            makeAICard(),
            makeSmartHomeCard(),
            makeGoogleCard(),
            makePrivacyCard()
        ].forEach { card in
            contentStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        documentView.addSubview(contentStack)

        let footer = NSVisualEffectView()
        footer.material = .hudWindow
        footer.blendingMode = .withinWindow
        footer.state = .active
        footer.translatesAutoresizingMaskIntoConstraints = false

        let footerStack = NSStackView(views: [saveStatusLabel, saveButton])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.distribution = .fill
        footerStack.spacing = 16
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        saveStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveButton.setContentHuggingPriority(.required, for: .horizontal)
        footer.addSubview(footerStack)

        view.addSubview(scrollView)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 64),
            footerStack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 28),
            footerStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -28),
            footerStack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 34),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -34),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 32),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -34),
            subtitleLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])
    }

    private func makeGeneralCard() -> JarvisSettingsCardView {
        let card = JarvisSettingsCardView(
            title: "General",
            subtitle: "Control startup behavior and the phrase Jarvis listens for while idle."
        )
        card.add(launchAtLoginCheckbox)
        card.add(startListeningCheckbox)
        card.add(JarvisSettingsUI.formRow(label: "Wake phrase", control: wakePhraseField))
        return card
    }

    private func makeVoiceCard() -> JarvisSettingsCardView {
        let card = JarvisSettingsCardView(
            title: "Voice",
            subtitle: "Speech uses macOS voices and stays entirely on this Mac."
        )
        card.add(voiceEnabledCheckbox)
        card.add(JarvisSettingsUI.formRow(label: "Voice", control: voicePopup))

        let rateStack = NSStackView(views: [speakingRateSlider, speakingRateLabel])
        rateStack.orientation = .horizontal
        rateStack.alignment = .centerY
        rateStack.distribution = .fill
        rateStack.spacing = 10
        card.add(JarvisSettingsUI.formRow(label: "Speaking rate", control: rateStack))
        card.add(activationSoundCheckbox)
        return card
    }

    private func makeAICard() -> JarvisSettingsCardView {
        let card = JarvisSettingsCardView(
            title: "AI",
            subtitle: "Gemini handles reasoning after Jarvis hears a command. Room audio is never sent while Jarvis is idle."
        )
        card.add(JarvisSettingsUI.formRow(label: "Gemini API key", control: geminiAPIKeyField))
        card.add(JarvisSettingsUI.formRow(label: "Gemini model", control: geminiModelField))
        card.add(JarvisSettingsUI.actionRow([geminiProgress, geminiTestButton]))
        card.add(geminiStatusLabel)
        return card
    }

    private func makeSmartHomeCard() -> JarvisSettingsCardView {
        let card = JarvisSettingsCardView(
            title: "Smart Home",
            subtitle: "Connect Jarvis to Home Assistant using its local URL and a long-lived access token."
        )
        card.add(JarvisSettingsUI.formRow(label: "Home Assistant URL", control: homeAssistantURLField))
        card.add(JarvisSettingsUI.formRow(label: "Access token", control: homeAssistantTokenField))
        card.add(JarvisSettingsUI.actionRow([homeAssistantProgress, deviceRefreshButton, homeAssistantTestButton]))
        card.add(homeAssistantStatusLabel)
        card.add(JarvisSettingsUI.separator())

        let devicesTitle = NSTextField(labelWithString: "CONNECTED DEVICES")
        devicesTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        devicesTitle.textColor = JarvisTheme.secondaryText
        card.add(devicesTitle)
        card.add(connectedDevicesView)
        return card
    }

    private func makeGoogleCard() -> JarvisSettingsCardView {
        let card = JarvisSettingsCardView(
            title: "Google",
            subtitle: "Google's current Home APIs do not provide a native macOS 11 control path. Jarvis controls compatible Google Home devices through Home Assistant instead."
        )

        let status = NSTextField(labelWithString: "●  Compatibility mode: Home Assistant bridge")
        status.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        status.textColor = JarvisTheme.success
        card.add(status)

        let connectButton = NSButton(title: "Connect Google Account", target: nil, action: nil)
        connectButton.isEnabled = false
        connectButton.toolTip = "Direct Google account linking is unavailable on macOS 11. Configure devices through Home Assistant."
        let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
        disconnectButton.isEnabled = false
        card.add(JarvisSettingsUI.actionRow([disconnectButton, connectButton]))
        return card
    }

    private func makePrivacyCard() -> JarvisSettingsCardView {
        let card = JarvisSettingsCardView(
            title: "Privacy",
            subtitle: "Jarvis does not retain command audio. Clear conversational context or remove every credential Jarvis owns in Keychain."
        )

        let clearConversationButton = NSButton(title: "Clear Conversation", target: self, action: #selector(clearConversation))
        let clearCredentialsButton = NSButton(title: "Clear Credentials…", target: self, action: #selector(confirmClearCredentials))
        clearCredentialsButton.contentTintColor = JarvisTheme.danger
        card.add(JarvisSettingsUI.actionRow([clearCredentialsButton, clearConversationButton]))
        return card
    }

    @objc private func voiceEnabledChanged() {
        updateVoiceControlAvailability()
    }

    @objc private func speakingRateChanged() {
        updateSpeakingRateLabel()
    }

    @objc private func saveSettings() {
        view.window?.makeFirstResponder(nil)

        let wakePhrase = wakePhraseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wakePhrase.isEmpty else {
            showValidationError("Enter a wake phrase, such as “Hey Jarvis”.", focusing: wakePhraseField)
            return
        }

        let model = geminiModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            showValidationError("Enter a Gemini model identifier.", focusing: geminiModelField)
            return
        }

        let homeAssistantURL = homeAssistantURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !homeAssistantURL.isEmpty && !isValidHTTPURL(homeAssistantURL) {
            showValidationError("Enter a valid Home Assistant HTTP or HTTPS URL.", focusing: homeAssistantURLField)
            return
        }

        do {
            let apiKey = geminiAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !apiKey.isEmpty {
                try dependencies.keychain.set(apiKey, for: .geminiAPIKey)
            }

            let homeAssistantToken = homeAssistantTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !homeAssistantToken.isEmpty {
                try dependencies.keychain.set(homeAssistantToken, for: .homeAssistantAccessToken)
            }
        } catch {
            setSaveStatus("Credentials could not be saved: \(error.localizedDescription)", success: false)
            return
        }

        let preferences = dependencies.preferences
        preferences.startListeningAutomatically = startListeningCheckbox.state == .on
        preferences.wakePhrase = wakePhrase
        preferences.voiceEnabled = voiceEnabledCheckbox.state == .on
        preferences.voiceIdentifier = selectedVoiceIdentifier
        preferences.speakingRate = speakingRateSlider.floatValue
        preferences.activationSoundsEnabled = activationSoundCheckbox.state == .on
        preferences.geminiModel = model
        preferences.homeAssistantURL = homeAssistantURL

        let requestedLaunchAtLogin = launchAtLoginCheckbox.state == .on
        var launchError: Error?
        do {
            if requestedLaunchAtLogin != dependencies.launchAtLogin.isEnabled {
                try dependencies.launchAtLogin.setEnabled(requestedLaunchAtLogin)
            }
            preferences.launchAtLogin = requestedLaunchAtLogin
        } catch {
            launchError = error
            let actualValue = dependencies.launchAtLogin.isEnabled
            preferences.launchAtLogin = actualValue
            launchAtLoginCheckbox.state = actualValue ? .on : .off
        }

        geminiAPIKeyField.stringValue = ""
        homeAssistantTokenField.stringValue = ""
        updateCredentialPlaceholders()
        dependencies.callbacks.onSettingsSaved(currentSnapshot())

        if let error = launchError {
            setSaveStatus("Settings saved, but launch at login was not changed: \(error.localizedDescription)", success: false)
        } else {
            setSaveStatus("Settings saved securely.", success: true)
        }
    }

    @objc private func testGeminiConnection() {
        view.window?.makeFirstResponder(nil)
        let model = geminiModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            setStatus(geminiStatusLabel, message: "Enter a Gemini model identifier first.", result: false)
            return
        }

        let apiKey: String
        do {
            apiKey = try pendingOrStoredCredential(field: geminiAPIKeyField, credential: .geminiAPIKey)
        } catch {
            setStatus(geminiStatusLabel, message: error.localizedDescription, result: false)
            return
        }
        guard !apiKey.isEmpty else {
            setStatus(geminiStatusLabel, message: "Enter a Gemini API key or save one to Keychain first.", result: false)
            return
        }

        setGeminiBusy(true)
        setStatus(geminiStatusLabel, message: "Contacting Gemini…", result: nil)
        let test = dependencies.testGeminiConnection
        Task { [weak self] in
            do {
                let response = try await test(apiKey, model)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.setGeminiBusy(false)
                    let confirmation = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.setStatus(
                        self.geminiStatusLabel,
                        message: confirmation.isEmpty ? "Gemini connection succeeded." : "Connected. \(confirmation)",
                        result: true
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.setGeminiBusy(false)
                    self.setStatus(self.geminiStatusLabel, message: error.localizedDescription, result: false)
                }
            }
        }
    }

    @objc private func testHomeAssistantConnection() {
        beginHomeAssistantConnectionTest()
    }

    @objc private func refreshDevices() {
        beginHomeAssistantConnectionTest()
    }

    private func beginHomeAssistantConnectionTest() {
        view.window?.makeFirstResponder(nil)
        let baseURL = homeAssistantURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidHTTPURL(baseURL) else {
            setStatus(homeAssistantStatusLabel, message: "Enter a valid Home Assistant HTTP or HTTPS URL first.", result: false)
            return
        }

        let token: String
        do {
            token = try pendingOrStoredCredential(field: homeAssistantTokenField, credential: .homeAssistantAccessToken)
        } catch {
            setStatus(homeAssistantStatusLabel, message: error.localizedDescription, result: false)
            return
        }
        guard !token.isEmpty else {
            setStatus(homeAssistantStatusLabel, message: "Enter an access token or save one to Keychain first.", result: false)
            return
        }

        setHomeAssistantBusy(true)
        connectedDevicesView.showLoading()
        setStatus(homeAssistantStatusLabel, message: "Connecting and discovering devices…", result: nil)
        let test = dependencies.testHomeAssistantConnection
        Task { [weak self] in
            do {
                let devices = try await test(baseURL, token)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.setHomeAssistantBusy(false)
                    self.connectedDevicesView.update(devices: devices)
                    self.setStatus(
                        self.homeAssistantStatusLabel,
                        message: devices.isEmpty ? "Connected, but no compatible entities were found." : "Connected. Discovered \(devices.count) compatible device\(devices.count == 1 ? "" : "s").",
                        result: true
                    )
                    self.dependencies.callbacks.onDevicesDiscovered(devices)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.setHomeAssistantBusy(false)
                    self.connectedDevicesView.showFailure()
                    self.setStatus(self.homeAssistantStatusLabel, message: error.localizedDescription, result: false)
                }
            }
        }
    }

    @objc private func clearConversation() {
        dependencies.callbacks.onClearConversation()
        setSaveStatus("Conversation context cleared.", success: true)
    }

    @objc private func confirmClearCredentials() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear all Jarvis credentials?"
        alert.informativeText = "This removes the Gemini API key, Home Assistant token, and any Google token from macOS Keychain. You will need to enter them again."
        alert.addButton(withTitle: "Clear Credentials")
        alert.addButton(withTitle: "Cancel")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.clearCredentials()
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func clearCredentials() {
        do {
            try dependencies.keychain.removeAll()
            geminiAPIKeyField.stringValue = ""
            homeAssistantTokenField.stringValue = ""
            updateCredentialPlaceholders()
            connectedDevicesView.update(devices: [])
            setStatus(geminiStatusLabel, message: "Gemini credential removed.", result: nil)
            setStatus(homeAssistantStatusLabel, message: "Home Assistant credential removed.", result: nil)
            setSaveStatus("All Jarvis credentials were removed from Keychain.", success: true)
            dependencies.callbacks.onCredentialsCleared()
        } catch {
            setSaveStatus("Credentials could not be cleared: \(error.localizedDescription)", success: false)
        }
    }

    private func loadVoices(selectedIdentifier: String?) {
        voices = dependencies.availableVoices().sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        voicePopup.removeAllItems()
        voicePopup.addItem(withTitle: "System Default")
        voicePopup.lastItem?.representedObject = ""

        for voice in voices {
            voicePopup.addItem(withTitle: voice.displayName)
            voicePopup.lastItem?.representedObject = voice.identifier
        }

        if let selectedIdentifier = selectedIdentifier,
           let index = voicePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedIdentifier }) {
            voicePopup.selectItem(at: index)
        } else {
            voicePopup.selectItem(at: 0)
        }
    }

    private var selectedVoiceIdentifier: String? {
        guard let identifier = voicePopup.selectedItem?.representedObject as? String,
              !identifier.isEmpty else { return nil }
        return identifier
    }

    private func updateVoiceControlAvailability() {
        let enabled = voiceEnabledCheckbox.state == .on
        voicePopup.isEnabled = enabled
        speakingRateSlider.isEnabled = enabled
        speakingRateLabel.alphaValue = enabled ? 1 : 0.45
    }

    private func updateSpeakingRateLabel() {
        speakingRateLabel.stringValue = "\(Int(speakingRateSlider.doubleValue.rounded())) wpm"
    }

    private func updateCredentialPlaceholders() {
        let geminiStored = (try? dependencies.keychain.contains(JarvisCredential.geminiAPIKey.rawValue)) ?? false
        geminiAPIKeyField.placeholderString = geminiStored
            ? "Stored securely — leave blank to keep"
            : "Paste a Gemini API key"

        let homeAssistantStored = (try? dependencies.keychain.contains(JarvisCredential.homeAssistantAccessToken.rawValue)) ?? false
        homeAssistantTokenField.placeholderString = homeAssistantStored
            ? "Stored securely — leave blank to keep"
            : "Paste a long-lived access token"
    }

    private func pendingOrStoredCredential(field: NSSecureTextField, credential: JarvisCredential) throws -> String {
        let pending = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty { return pending }
        return try dependencies.keychain.string(for: credential)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func currentSnapshot() -> JarvisSettingsSnapshot {
        let preferences = dependencies.preferences
        return JarvisSettingsSnapshot(
            launchAtLogin: preferences.launchAtLogin,
            startListeningAutomatically: preferences.startListeningAutomatically,
            wakePhrase: preferences.wakePhrase,
            voiceEnabled: preferences.voiceEnabled,
            voiceIdentifier: preferences.voiceIdentifier,
            speakingRate: preferences.speakingRate,
            activationSoundsEnabled: preferences.activationSoundsEnabled,
            geminiModel: preferences.geminiModel,
            homeAssistantURL: preferences.homeAssistantURL
        )
    }

    private func setGeminiBusy(_ busy: Bool) {
        geminiTestButton.isEnabled = !busy
        if busy { geminiProgress.startAnimation(nil) } else { geminiProgress.stopAnimation(nil) }
    }

    private func setHomeAssistantBusy(_ busy: Bool) {
        homeAssistantTestButton.isEnabled = !busy
        deviceRefreshButton.isEnabled = !busy
        if busy { homeAssistantProgress.startAnimation(nil) } else { homeAssistantProgress.stopAnimation(nil) }
    }

    private func setStatus(_ label: NSTextField, message: String, result: Bool?) {
        label.stringValue = message
        switch result {
        case .some(let succeeded):
            label.textColor = succeeded ? JarvisTheme.success : JarvisTheme.danger
        case .none:
            label.textColor = JarvisTheme.secondaryText
        }
    }

    private func setSaveStatus(_ message: String, success: Bool) {
        saveStatusLabel.stringValue = message
        saveStatusLabel.textColor = success ? JarvisTheme.success : JarvisTheme.danger
    }

    private func showValidationError(_ message: String, focusing control: NSControl) {
        setSaveStatus(message, success: false)
        view.window?.makeFirstResponder(control)
    }

    private func isValidHTTPURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else { return false }
        return true
    }
}
