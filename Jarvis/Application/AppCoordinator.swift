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
        maximumTurnsProvider: { [weak self] in self?.preferences.maxConversationTurns ?? 12 },
        locationProvider: { [weak self] in self?.preferences.defaultLocation ?? "" }
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
    private var wakeRetryWorkItem: DispatchWorkItem?
    private var wakeRetryAttempt = 0
    private var conversationGeneration = 0

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
    }

    func start(presentWindow: Bool = true) {
        guard !started else {
            if presentWindow { windowController.present() }
            return
        }
        started = true
        configureActions()
        microphone.onConfigurationChange = { [weak self] in
            self?.handleError(MicrophoneError.unavailable)
        }
        menuBarController.updateLaunchAtLogin(launchAtLogin.isEnabled)
        publishState()
        if presentWindow { windowController.present() }
        discoverDevicesAtStartup()
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
        wakeRetryWorkItem?.cancel()
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
        if stateMachine.state == .listening {
            stopListening()
            return
        }
        if stateMachine.state == .speaking {
            speechSynthesis.stop()
            _ = stateMachine.transition(to: .idle)
        }
        guard stateMachine.state == .idle || stateMachine.state == .error else { return }
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
        speechRecognition.stop { [weak self] in
            guard let self = self, self.handsFreeEnabled, self.stateMachine.state == .idle else { return }
            self.startWakeDetection()
        }
        _ = stateMachine.transition(to: .idle)
        publishState()
    }

    private func clearConversation() {
        conversationGeneration &+= 1
        let generation = conversationGeneration
        speechRecognition.stop { [weak self] in
            guard let self = self,
                  self.conversationGeneration == generation,
                  self.handsFreeEnabled,
                  self.stateMachine.state == .idle else { return }
            self.startWakeDetection()
        }
        speechSynthesis.stop()
        wakeDetector.stop()
        lastRequest = nil
        lastResponse = nil
        conversation.clear()
        gemini.clearConversation()
        toolRouter.clearContext()
        windowController.contentController.clearConversation()
        _ = stateMachine.transition(to: .idle)
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
        wakeRetryWorkItem?.cancel()
        wakeDetector.stop()
        speechRecognition.stop()
        _ = stateMachine.transition(to: .error)
        windowController.contentController.update(state: .error, userText: nil, jarvisText: message, detail: "Needs attention")
        menuBarController.update(state: .error, lastRequest: lastRequest, deviceCount: nil)
        JarvisLog.error("Jarvis entered a recoverable error state")
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
        let requestGeneration = conversationGeneration

        if toolRouter.hasPendingConfirmation, let confirmation = confirmationValue(from: transcript) {
            _ = stateMachine.transition(to: .processing)
            publishState(detail: confirmation ? "Confirming action…" : "Cancelling action…")
            Task { [weak self] in
                guard let self = self else { return }
                let result = await self.toolRouter.confirmPendingAction(confirmed: confirmation)
                let message = result?.message ?? "That confirmation expired. Please ask me again if you still want the action."
                await MainActor.run {
                    guard self.conversationGeneration == requestGeneration else { return }
                    self.gemini.appendLocalTurn(user: transcript, assistant: message)
                    self.deliver(message)
                }
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
            let localParse = self.localIntentParser.parseResult(transcript)

            if localParse.isFullyRecognized {
                await self.executeLocal(
                    intents: localParse.intents,
                    transcript: transcript,
                    hasUnrecognizedRemainder: false,
                    generation: requestGeneration
                )
                return
            }

            if !self.networkMonitor.isInternetLikelyAvailable {
                await self.executeLocal(
                    intents: localParse.intents,
                    transcript: transcript,
                    hasUnrecognizedRemainder: !localParse.unrecognizedFragments.isEmpty,
                    generation: requestGeneration
                )
                return
            }

            var toolResults: [GeminiToolExecutionResult] = []
            do {
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
                        let result = await self.toolRouter.execute(call)
                        toolResults.append(result)
                        return result
                    }
                )
                await MainActor.run {
                    guard self.conversationGeneration == requestGeneration else { return }
                    self.deliver(response.text)
                }
            } catch let primaryError {
                if !toolResults.isEmpty {
                    let details = toolResults.map(\.message).joined(separator: " ")
                    let message = details + " I couldn't complete the final Gemini response."
                    await MainActor.run {
                        guard self.conversationGeneration == requestGeneration else { return }
                        self.gemini.appendLocalTurn(user: transcript, assistant: message)
                        self.deliver(message)
                    }
                } else if !localParse.intents.isEmpty {
                    await self.executeLocal(
                        intents: localParse.intents,
                        transcript: transcript,
                        hasUnrecognizedRemainder: !localParse.unrecognizedFragments.isEmpty,
                        generation: requestGeneration
                    )
                } else {
                    await MainActor.run {
                        guard self.conversationGeneration == requestGeneration else { return }
                        self.handleError(primaryError)
                    }
                }
            }
        }
    }

    private func executeLocal(
        intents: [LocalIntent],
        transcript: String,
        hasUnrecognizedRemainder: Bool,
        generation: Int
    ) async {
        do {
            var response = try await toolRouter.executeLocal(intents)
            if hasUnrecognizedRemainder {
                response += " I completed the local part, but I couldn't reach Gemini for the rest."
            }
            await MainActor.run {
                guard conversationGeneration == generation else { return }
                gemini.appendLocalTurn(user: transcript, assistant: response)
                deliver(response)
            }
        } catch {
            await MainActor.run {
                guard conversationGeneration == generation else { return }
                handleError(error)
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
        guard !speechSynthesis.isSpeaking else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.finishSpeaking() }
            return
        }
        _ = stateMachine.transition(to: .idle)
        publishState()
        if toolRouter.hasPendingConfirmation {
            toolRouter.armPendingConfirmationTimeout(seconds: 45)
        }
        if handsFreeEnabled { startWakeDetection() }
    }

    private func requestHandsFreeStart() {
        AudioPermissions.request { [weak self] status in
            guard let self = self else { return }
            switch status {
            case .authorized:
                self.handsFreeEnabled = true
                self.wakeRetryAttempt = 0
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
        publishState(detail: "Listening for “\(preferences.wakePhrase)”…")
        wakeDetector.start(
            onWake: { [weak self] match in
                guard let self = self else { return }
                self.wakeRetryAttempt = 0
                self.wakeRetryWorkItem?.cancel()
                _ = self.stateMachine.transition(to: .wakeDetected)
                self.publishState()
                let cueDuration = self.preferences.activationSoundsEnabled
                    ? self.speechSynthesis.playActivationSound()
                    : 0
                if let command = match.trailingCommand, !command.isEmpty {
                    self.lastRequest = command
                    _ = self.stateMachine.transition(to: .listening)
                    self.process(command)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0.08, cueDuration + 0.12)) {
                        self.beginCommandRecognition()
                    }
                }
            },
            onError: { [weak self] error in
                self?.handleWakeError(error)
            }
        )
    }

    private func handleWakeError(_ error: Error) {
        if let wakeError = error as? WakeWordError,
           case .onDeviceRecognitionUnavailable = wakeError {
            handsFreeEnabled = false
            menuBarController.updateHandsFree(false)
            handleError(error)
            return
        }

        guard handsFreeEnabled else { return }
        wakeRetryAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(5, wakeRetryAttempt - 1))))
        _ = stateMachine.transition(to: .idle)
        publishState(detail: "Wake listener retrying in \(Int(delay))s…")
        JarvisLog.error("Wake listener stopped; a bounded retry was scheduled")
        wakeRetryWorkItem?.cancel()
        let retry = DispatchWorkItem { [weak self] in self?.startWakeDetection() }
        wakeRetryWorkItem = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
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
            wakeRetryWorkItem?.cancel()
            menuBarController.updateHandsFree(false)
            if stateMachine.state == .listening { stopListening() }
        }
    }

    private func applySettings(_ snapshot: JarvisSettingsSnapshot) {
        menuBarController.updateLaunchAtLogin(snapshot.launchAtLogin)
        if snapshot.startListeningAutomatically && !handsFreeEnabled {
            requestHandsFreeStart()
        } else if snapshot.startListeningAutomatically && handsFreeEnabled {
            wakeDetector.stop()
            if stateMachine.state == .idle { startWakeDetection() }
        } else if !snapshot.startListeningAutomatically {
            handsFreeEnabled = false
            wakeDetector.stop()
            wakeRetryWorkItem?.cancel()
            menuBarController.updateHandsFree(false)
        }
        publishState()
    }

    private func credentialsCleared() {
        gemini.clearConversation()
        toolRouter.clearContext()
        deviceCount = nil
        publishState(detail: "Credentials cleared")
    }

    private func devicesDiscovered(_ devices: [SmartDevice]) {
        deviceCount = devices.count
        publishState()
    }

    private func discoverDevicesAtStartup() {
        let storedToken = try? keychain.string(for: .homeAssistantAccessToken)
        guard !preferences.homeAssistantURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let token = storedToken, !token.isEmpty else { return }
        Task { [weak self] in
            guard let self = self, let devices = try? await self.homeProvider.listDevices() else { return }
            await MainActor.run { self.devicesDiscovered(devices) }
        }
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
