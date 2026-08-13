import AppKit

final class AppCoordinator {
    private let preferences: Preferences
    private let windowController = JarvisWindowController()
    private let menuBarController = MenuBarController()
    private let stateMachine = AssistantStateMachine()
    private let microphone = MicrophoneService()
    private lazy var speechRecognition = SpeechRecognitionService(microphone: microphone)
    private lazy var speechSynthesis = SpeechSynthesisService()
    private let keychain = KeychainService.shared
    private let launchAtLogin = LaunchAtLoginService()
    private lazy var homeAssistantService = HomeAssistantService(
        baseURL: { [weak self] in self?.preferences.homeAssistantURL },
        accessToken: { [weak self] in try? self?.keychain.string(for: .homeAssistantAccessToken) }
    )
    private lazy var homeProvider = HomeAssistantProvider(service: homeAssistantService)
    private let macCommands = MacCommandService()
    private lazy var routineExecutor = RoutineExecutor(homeProvider: homeProvider, macCommandService: macCommands)
    private lazy var toolRouter = ToolCallRouter(homeProvider: homeProvider, routineExecutor: routineExecutor, macCommands: macCommands)
    private lazy var gemini = GeminiService(
        apiKeyProvider: { [weak self] in
            guard let self = self else { throw GeminiError.missingAPIKey }
            return try self.keychain.string(for: .geminiAPIKey) ?? ""
        },
        modelProvider: { [weak self] in self?.preferences.geminiModel ?? "gemini-3.6-flash" },
        maximumTurnsProvider: { [weak self] in self?.preferences.maxConversationTurns ?? 12 }
    )
    private lazy var wakeDetector: WakeWordDetector = NativeSpeechWakeWordDetector(
        microphone: microphone,
        phraseProvider: { [weak self] in self?.preferences.wakePhrase ?? "Hey Jarvis" }
    )
    private lazy var settingsWindowController = JarvisSettingsWindowController(
        dependencies: .live(
            preferences: preferences,
            keychain: keychain,
            launchAtLogin: launchAtLogin,
            speechSynthesis: speechSynthesis,
            callbacks: JarvisSettingsCallbacks(
                onSettingsSaved: { [weak self] snapshot in self?.applySettings(snapshot) },
                onClearConversation: { [weak self] in self?.clearConversation() },
                onCredentialsCleared: { [weak self] in self?.credentialsCleared() },
                onDevicesDiscovered: { [weak self] devices in self?.devicesDiscovered(devices) }
            )
        )
    )
    private let localIntentParser = LocalIntentParser()
    private let networkMonitor = NetworkMonitor()
    private lazy var conversation = ConversationManager(maximumTurns: preferences.maxConversationTurns)
    private var lastRequest: String?
    private var lastResponse: String?
    private var deviceCount: Int?
    private var handsFreeEnabled = false
    private var started = false
    private var errorRecoveryWorkItem: DispatchWorkItem?

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
    }

    func start() {
        guard !started else {
            windowController.present()
            return
        }
        started = true
        configureActions()
        microphone.onConfigurationChange = { [weak self] in
            self?.handleError(MicrophoneError.unavailable)
        }
        menuBarController.updateLaunchAtLogin(preferences.launchAtLogin)
        publishState()
        windowController.present()
        if preferences.startListeningAutomatically {
            requestHandsFreeStart()
        }
        JarvisLog.info("Jarvis application started")
    }

    func shutdown() {
        speechRecognition.stop()
        wakeDetector.stop()
        speechSynthesis.stop()
        microphone.stop()
        JarvisLog.info("Jarvis application is shutting down")
    }

    private func configureActions() {
        let content = windowController.contentController
        content.onTalk = { [weak self] in self?.manualTalk() }
        content.onStop = { [weak self] in self?.stopListening() }
        content.onOpenSettings = { [weak self] in self?.settingsWindowController.present() }

        menuBarController.onTalk = { [weak self] in self?.manualTalk() }
        menuBarController.onStopListening = { [weak self] in self?.stopListening() }
        menuBarController.onOpenJarvis = { [weak self] in self?.windowController.present() }
        menuBarController.onOpenSettings = { [weak self] in self?.settingsWindowController.present() }
        menuBarController.onClearConversation = { [weak self] in self?.clearConversation() }
        menuBarController.onToggleListening = { [weak self] enabled in self?.setHandsFree(enabled) }
        menuBarController.onToggleLaunchAtLogin = { [weak self] enabled in
            self?.setLaunchAtLogin(enabled)
        }
        menuBarController.onQuit = { NSApp.terminate(nil) }
    }

    private func manualTalk() {
        guard stateMachine.state != .listening else {
            stopListening()
            return
        }
        AudioPermissions.request { [weak self] status in
            guard let self = self else { return }
            switch status {
            case .authorized:
                self.beginCommandRecognition()
            case .denied(let message):
                self.handleErrorMessage(message)
            }
        }
    }

    private func stopListening() {
        speechRecognition.stop()
        _ = stateMachine.transition(to: .idle)
        publishState()
    }

    private func clearConversation() {
        lastRequest = nil
        lastResponse = nil
        conversation.clear()
        gemini.clearConversation()
        windowController.contentController.clearConversation()
        publishState()
    }

    private func publishState(detail: String? = nil) {
        let state = stateMachine.state
        windowController.contentController.update(state: state, userText: nil, jarvisText: nil, detail: detail)
        menuBarController.update(state: state, lastRequest: lastRequest, deviceCount: deviceCount)
    }

    private func beginCommandRecognition() {
        wakeDetector.stop()
        guard stateMachine.transition(to: .listening) else { return }
        publishState()
        speechRecognition.start(
            onPartial: { [weak self] transcript in
                guard let self = self else { return }
                self.windowController.contentController.update(
                    state: .listening,
                    userText: transcript,
                    jarvisText: nil,
                    detail: "Listening…"
                )
            },
            onFinal: { [weak self] transcript in
                guard let self = self else { return }
                self.lastRequest = transcript
                self.process(transcript)
            },
            onError: { [weak self] error in self?.handleError(error) }
        )
    }

    private func handleError(_ error: Error) {
        handleErrorMessage(error.localizedDescription)
    }

    private func handleErrorMessage(_ message: String) {
        wakeDetector.stop()
        speechRecognition.stop()
        _ = stateMachine.transition(to: .error)
        windowController.contentController.update(state: .error, userText: nil, jarvisText: message, detail: "Needs attention")
        menuBarController.update(state: .error, lastRequest: lastRequest, deviceCount: nil)
        JarvisLog.error(message)
        errorRecoveryWorkItem?.cancel()
        let recovery = DispatchWorkItem { [weak self] in
            guard let self = self, self.stateMachine.state == .error else { return }
            _ = self.stateMachine.transition(to: .idle)
            self.publishState()
            if self.handsFreeEnabled { self.startWakeDetection() }
        }
        errorRecoveryWorkItem = recovery
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: recovery)
    }

    private func process(_ transcript: String) {
        wakeDetector.stop()
        speechRecognition.stop(cancelled: false)
        conversation.append(role: .user, text: transcript)

        if toolRouter.hasPendingConfirmation, let confirmation = confirmationValue(from: transcript) {
            _ = stateMachine.transition(to: .processing)
            publishState(detail: confirmation ? "Confirming action…" : "Cancelling action…")
            Task { [weak self] in
                guard let self = self, let result = await self.toolRouter.confirmPendingAction(confirmed: confirmation) else { return }
                await MainActor.run { self.deliver(result.message) }
            }
            return
        }
        if toolRouter.hasPendingConfirmation {
            toolRouter.cancelPendingAction()
        }

        _ = stateMachine.transition(to: .processing)
        windowController.contentController.update(state: .processing, userText: transcript, jarvisText: nil, detail: "Thinking…")
        menuBarController.update(state: .processing, lastRequest: transcript, deviceCount: deviceCount)

        Task { [weak self] in
            guard let self = self else { return }
            do {
                if !self.networkMonitor.isInternetLikelyAvailable {
                    let response = try await self.toolRouter.executeLocal(self.localIntentParser.parse(transcript))
                    await MainActor.run { self.deliver(response) }
                    return
                }
                let response = try await self.gemini.respond(
                    to: transcript,
                    tools: self.toolRouter.tools,
                    onToolsRequested: { [weak self] calls in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            _ = self.stateMachine.transition(to: .executing)
                            self.publishState(detail: Self.toolActivityDescription(calls))
                        }
                    },
                    execute: { [weak self] call in
                        guard let self = self else { return .init(success: false, message: "Jarvis stopped.") }
                        return await self.toolRouter.execute(call)
                    }
                )
                await MainActor.run { self.deliver(response.text) }
            } catch let primaryError {
                do {
                    let fallback = try await self.toolRouter.executeLocal(self.localIntentParser.parse(transcript))
                    await MainActor.run { self.deliver(fallback) }
                } catch {
                    await MainActor.run { self.handleError(primaryError) }
                }
            }
        }
    }

    private func deliver(_ response: String) {
        lastResponse = response
        conversation.append(role: .jarvis, text: response)
        _ = stateMachine.transition(to: .speaking)
        windowController.contentController.update(state: .speaking, userText: lastRequest, jarvisText: response, detail: "Speaking…")
        menuBarController.update(state: .speaking, lastRequest: lastRequest, deviceCount: deviceCount)

        guard preferences.voiceEnabled else {
            finishSpeaking()
            return
        }
        speechSynthesis.speak(
            response,
            voiceIdentifier: preferences.voiceIdentifier,
            rate: preferences.speakingRate
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { self?.finishSpeaking() }
        }
    }

    private func finishSpeaking() {
        _ = stateMachine.transition(to: .idle)
        publishState()
        if handsFreeEnabled { startWakeDetection() }
    }

    private func requestHandsFreeStart() {
        AudioPermissions.request { [weak self] status in
            guard let self = self else { return }
            switch status {
            case .authorized:
                self.handsFreeEnabled = true
                self.menuBarController.updateHandsFree(true)
                self.startWakeDetection()
            case .denied(let message):
                self.handsFreeEnabled = false
                self.menuBarController.updateHandsFree(false)
                self.handleErrorMessage(message)
            }
        }
    }

    private func startWakeDetection() {
        guard handsFreeEnabled, stateMachine.state == .idle else { return }
        wakeDetector.start(
            onWake: { [weak self] match in
                guard let self = self else { return }
                _ = self.stateMachine.transition(to: .wakeDetected)
                self.publishState()
                if self.preferences.activationSoundsEnabled { self.speechSynthesis.playActivationSound() }
                if let command = match.trailingCommand, !command.isEmpty {
                    self.lastRequest = command
                    _ = self.stateMachine.transition(to: .listening)
                    self.process(command)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self.beginCommandRecognition() }
                }
            },
            onError: { [weak self] error in
                self?.handsFreeEnabled = false
                self?.menuBarController.updateHandsFree(false)
                self?.handleError(error)
            }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLogin.setEnabled(enabled)
            preferences.launchAtLogin = enabled
            menuBarController.updateLaunchAtLogin(enabled)
        } catch {
            preferences.launchAtLogin = launchAtLogin.isEnabled
            menuBarController.updateLaunchAtLogin(preferences.launchAtLogin)
            handleError(error)
        }
    }

    private func setHandsFree(_ enabled: Bool) {
        preferences.startListeningAutomatically = enabled
        if enabled {
            requestHandsFreeStart()
        } else {
            handsFreeEnabled = false
            wakeDetector.stop()
            menuBarController.updateHandsFree(false)
            if stateMachine.state == .listening { stopListening() }
        }
    }

    private func applySettings(_ snapshot: JarvisSettingsSnapshot) {
        menuBarController.updateLaunchAtLogin(snapshot.launchAtLogin)
        if snapshot.startListeningAutomatically && !handsFreeEnabled {
            requestHandsFreeStart()
        } else if !snapshot.startListeningAutomatically {
            handsFreeEnabled = false
            wakeDetector.stop()
            menuBarController.updateHandsFree(false)
        }
        publishState()
    }

    private func credentialsCleared() {
        gemini.clearConversation()
        deviceCount = nil
        publishState(detail: "Credentials cleared")
    }

    private func devicesDiscovered(_ devices: [SmartDevice]) {
        deviceCount = devices.count
        publishState()
    }

    private func confirmationValue(from transcript: String) -> Bool? {
        let normalized = transcript.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if ["yes", "yes please", "confirm", "do it", "go ahead"].contains(normalized) { return true }
        if ["no", "cancel", "never mind", "don't", "do not"].contains(normalized) { return false }
        return nil
    }

    private static func toolActivityDescription(_ calls: [GeminiFunctionCall]) -> String {
        if calls.count > 1 { return "Running \(calls.count) actions…" }
        return calls.first.map { "Running \($0.name.replacingOccurrences(of: "_", with: " "))…" } ?? "Working…"
    }
}
