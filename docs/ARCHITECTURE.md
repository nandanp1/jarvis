# Jarvis Architecture

Jarvis is a native, always-on macOS room assistant. Its deployment target is
macOS 11.0 Big Sur, and that compatibility requirement is an architectural
constraint rather than a packaging detail. The app uses AppKit for its window
and menu-bar presence, Apple audio and speech frameworks for voice input, HTTPS
services for Gemini and Home Assistant, and Keychain for credentials.

This document describes the intended production boundaries and the invariants
new code must preserve.

## Design goals

- Feel like a quiet appliance instead of a desktop chat client.
- Keep idle resource use low enough for continuous operation.
- Never send idle room audio to Gemini.
- Perform actions through explicit, auditable tools; a model response alone is
  never evidence that a device changed.
- Keep basic local smart-home commands useful when Gemini is unavailable.
- Build for both Intel (`x86_64`) and Apple silicon (`arm64`) without
  architecture-specific binary dependencies.
- Remain buildable with a macOS 11.0 deployment target. Newer APIs require an
  availability check and a real Big Sur fallback.

## System overview

```text
microphone
    |
    +--> WakeWordDetector while idle
    |        |
    |        +--> wake phrase accepted
    |
    +--> SpeechRecognitionService + voice activity detection
             |
             v
       AssistantController
             |
             +--> LocalIntentParser --------------------+
             |                                           |
             +--> ConversationManager --> GeminiService  |
                                      |       |           |
                                      |       v           |
                                      |  ToolCallRouter --+
                                      |                   |
                                      +<-- tool result <--+
                                                          |
                       +----------------------------------+
                       |
             +---------+----------+----------------+
             |                    |                |
     HomeControlProvider  MacCommandService  RoutineExecutor
             |
     HomeAssistantService
             |
       Home Assistant
             |
    room devices / services

final spoken text --> SpeechSynthesisService --> Mac speakers
```

The UI observes state and presentation data. It does not call Gemini or a home
automation endpoint directly.

## Application layer

`AppDelegate` owns the application lifetime. `AppCoordinator` constructs the
long-lived services, connects their callbacks, restores preferences, and shuts
audio work down cleanly on termination. `MenuBarController` uses
`NSStatusBar`, `NSStatusItem`, and `NSMenu`; `MenuBarExtra` is unavailable on
Big Sur and must not be introduced.

AppKit mutations happen on the main thread. Audio processing, HTTP requests,
device discovery, and tool execution happen away from the main thread and
publish small state updates back to it.

The product identifiers are fixed:

```text
Product / executable / scheme: Jarvis
Bundle identifier:             com.nandan.jarvis
Deployment target:             macOS 11.0
```

## Assistant state machine

`AssistantState` is the source of truth for the visible and audible lifecycle:

```swift
enum AssistantState {
    case idle
    case wakeDetected
    case listening
    case processing
    case executing
    case speaking
    case error
}
```

The normal hands-free transition is:

```text
idle -> wakeDetected -> listening -> processing
                                      |
                                      +-> executing -> processing (tool loop)
                                      |
                                      +-> speaking -> cooldown -> idle
```

Manual Talk enters `listening` directly. Cancellation, permission denial,
timeouts, audio-device loss, and network failures take a controlled error path
and then return to `idle` when recovery is safe. A state transition should be
made by the assistant controller, not independently by a view or service.

While `speaking`, Jarvis stops command recognition and wake detection. It only
restarts wake detection after synthesis completion and a short cooldown. This
prevents Jarvis from treating its own output as a new request.

## Voice pipeline

### Capture and transcription

`MicrophoneService` owns `AVAudioEngine`, the input-node tap, audio-format
changes, and device-loss cleanup. `SpeechRecognitionService` owns
`SFSpeechAudioBufferRecognitionRequest`, `SFSpeechRecognitionTask`, permission
checks, partial transcripts, and finalization. Neither service may assume an
input device exists.

Voice activity detection observes audio levels and speech-recognition progress.
After speech begins, about 1 to 1.5 seconds of silence finalizes the request. A
maximum command duration is still required as a failsafe. Audio buffers are
ephemeral and are not written to disk during the normal command path.

### Wake-word privacy boundary

`WakeWordDetector` is a protocol so the wake engine can be replaced without
changing the assistant controller. The first-party implementation may use
Apple Speech to recognize `Hey Jarvis` or `Jarvis`, but Big Sur does not
guarantee on-device speech recognition for every locale, language pack, or Mac.

That limitation has a strict consequence: native wake listening is allowed
only when `supportsOnDeviceRecognition` is true and the request can require
on-device recognition. If that mode is unavailable, Jarvis must not quietly
fall back to server-assisted continuous recognition. It should report that
hands-free wake detection is unavailable and retain the manual Talk path. A
future dedicated offline detector can satisfy the same `WakeWordDetector`
contract.

After a wake phrase, command transcription may use the user's configured Apple
Speech behavior. Only the finalized command, never the idle audio stream, is
sent to Gemini.

### Speech output

`SpeechSynthesisService` wraps the Big Sur-compatible
`NSSpeechSynthesizer`. It applies the selected system voice and rate, reports
completion, and supports cancellation. Voice output is optional; state still
returns to idle when speech is disabled or cannot start.

## Reasoning and conversation

`GeminiService` talks to Google's Gemini Interactions API over `URLSession`.
The shipped default model is `gemini-3.6-flash`, but the model identifier is a
setting because model availability changes independently of the app. Requests
use `store: false` by default so conversation retention stays under Jarvis's
bounded local policy instead of implicitly enabling server-side interaction
storage. The API key is retrieved from Keychain at request time and is never
placed in preferences, source files, URLs, or logs.

`GeminiService` owns the exact bounded API-step history required for stateless
Interactions requests, including tool-call signatures and results.
`ConversationManager` maintains the UI-friendly user/Jarvis transcript. Both
evict old turns before memory and token usage become unbounded. **Clear
Conversation** removes this in-memory context; it does not delete credentials.

Gemini receives explicit tool declarations. A tool-capable response is handled
as a loop:

1. Send the user request and bounded context.
2. Validate every returned tool name and argument.
3. Execute allowed calls, including multiple calls in one user turn.
4. Return structured success or failure results to Gemini.
5. Ask Gemini for the concise spoken response.

Jarvis never announces success before step 3 succeeds. The router caps tool
iterations and rejects unknown tools, invalid arguments, and recursive or
unbounded plans.

## Smart-home boundary

Gemini and the UI depend on `HomeControlProvider`, not on Home Assistant
transport details:

```swift
protocol HomeControlProvider {
    func listDevices() async throws -> [SmartDevice]
    func getState(deviceID: String) async throws -> DeviceState
    func execute(command: HomeCommand) async throws
}
```

`HomeAssistantService` is the production provider for Big Sur. It discovers
entities, maps Home Assistant attributes into device capabilities, and invokes
domain services. The Home Assistant URL is a normal preference; its long-lived
access token is a Keychain secret.

Home Assistant is also the practical Google Home compatibility path. Jarvis
controls devices that Home Assistant can see; it does not scrape the Google
Home app or pretend an unsupported native macOS Google Home SDK exists. See
[SMART_HOME.md](SMART_HOME.md) for the important ecosystem caveat and setup
options.

## Local execution

The local intent parser handles a deliberately small grammar for device on/off,
brightness, fans, and named routines. When Gemini or the wider internet is
unavailable, it can still call a Home Assistant instance on the local network.
Ambiguous commands fail safely instead of guessing.

`RoutineExecutor` combines typed home commands, allowlisted Mac commands, and a
final phrase. Routine steps return individual results so partial failure is
visible. Sensitive actions such as unlocking a lock, opening a garage door, or
disabling security require an explicit confirmation turn before execution.

`MacCommandService` exposes typed operations such as volume, mute, opening a
known application, display sleep, and status queries. Model output never
becomes an arbitrary shell command or AppleScript program.

## Persistence and secrets

Non-secret settings use `UserDefaults` through `Preferences`. Credentials use a
single `KeychainService` namespace and are referenced by stable account keys.
The following must never enter `UserDefaults`, logs, crash messages, or Git:

- Gemini API keys
- Home Assistant access tokens
- Google OAuth credentials
- authorization headers
- captured room audio

Logs use `os_log`, redact credential markers, and describe outcomes rather than
raw request bodies. User-facing errors should identify the failing subsystem
without exposing server responses that may contain secrets.

## Reliability model

- Exactly one owner starts and stops each audio engine or recognition task.
- Network requests have finite timeouts and cancellation paths.
- Conversation history, tool iterations, device caches, and diagnostic data are
  bounded.
- Home Assistant discovery is event-driven or refreshed sparingly, not polled
  continuously.
- Wake detection is paused during speaking and while command recognition owns
  the microphone.
- Recoverable failures use backoff; launch-at-login must not create a rapid
  crash/restart loop.
- Service callbacks capture long-lived owners weakly where appropriate.

## Compatibility review checklist

Before merging a platform-facing change:

1. Confirm the API exists on macOS 11 in Apple's documentation or SDK headers.
2. If the API is newer, guard it with `#available(macOS ..., *)` and exercise a
   real Big Sur fallback.
3. Build with `MACOSX_DEPLOYMENT_TARGET=11.0` for both `x86_64` and `arm64`.
4. Avoid binary dependencies unless both architectures and Big Sur are
   explicitly supported.
5. Run `scripts/validate-project.sh` and the unit tests.
6. Manually verify permissions and voice behavior on a Big Sur Mac; compiling
   against a newer SDK is not a Big Sur runtime test.

Relevant upstream references:

- [Gemini Interactions API](https://ai.google.dev/gemini-api/docs/interactions-overview)
- [Gemini 3.6 Flash](https://ai.google.dev/gemini-api/docs/models/gemini-3.6-flash)
- [Apple Speech framework](https://developer.apple.com/documentation/speech)
