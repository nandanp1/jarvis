# Jarvis

Jarvis turns a continuously running Mac into a voice-first room assistant:

```text
"Hey Jarvis" → speech → Gemini reasoning → real tools → spoken response
```

It is a native AppKit menu-bar app with an ambient interface, manual Talk mode, on-device wake-phrase detection where Apple supports it, bounded conversation memory, Gemini tool calling, actual Home Assistant control, routines, safe Mac automation, native text-to-speech, and Big Sur-compatible launch at login.

The hard deployment target is **macOS 11.0 Big Sur**. Jarvis uses no `MenuBarExtra`, `SMAppService`, or other newer-only convenience APIs. The checked-in project builds the `Jarvis` product and scheme with bundle identifier `com.nandan.jarvis` for both Intel (`x86_64`) and Apple silicon (`arm64`).

## How Jarvis works

While idle, Jarvis permits hands-free wake listening only when `SFSpeechRecognizer` reports that required on-device recognition is available. It never silently uploads continuous room audio. If that capability is unavailable on a particular Big Sur Mac or language pack, manual Talk remains available and Settings explains why hands-free mode cannot start.

After activation, one `AVAudioEngine` microphone owner supplies Speech.framework and adaptive voice activity detection. Roughly 1.25 seconds of silence finalizes the command, with separate no-speech and maximum-duration safeguards. The recognized text—not idle audio—is sent to Gemini. Jarvis suspends both wake and command recognition while `NSSpeechSynthesizer` speaks, waits through an acoustic cooldown, and only then resumes wake listening.

Gemini receives explicit, allowlisted tools. Home and Mac actions are executed locally, verified against refreshed state where the target exposes it, and returned to Gemini before Jarvis reports the outcome. Independent calls in one Gemini turn support requests such as “turn off the desk light, turn on the fan, and tell me tomorrow’s weather.” Gemini 3 models can combine Jarvis functions with Google Search for current questions.

## Requirements

- macOS 11.0 Big Sur or newer
- Xcode 13.2 or newer to build Swift concurrency back-deployed to macOS 11
- A microphone plus macOS Microphone and Speech Recognition permission
- A [Gemini API key](https://aistudio.google.com/apikey) for cloud reasoning and current information
- Home Assistant plus a long-lived access token for smart-home control

Xcode 13.2.x itself requires a sufficiently updated Big Sur development host, while the built app’s deployment target remains 11.0.

## Build

The latest downloadable universal app is available from
[GitHub Releases](https://github.com/nandanp1/jarvis/releases). Automated release
builds are ad-hoc signed rather than Developer ID signed/notarized; on first
launch, Control-click `Jarvis.app`, choose **Open**, and approve the macOS prompt.
To install, unzip the download and move `Jarvis.app` into `/Applications` or
`~/Applications` before enabling launch at login.

```bash
git clone https://github.com/nandanp1/jarvis.git ~/jarvis
cd ~/jarvis
./scripts/validate-project.sh
xcodebuild \
  -project Jarvis.xcodeproj \
  -scheme Jarvis \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/JarvisDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Or open `Jarvis.xcodeproj`, select the shared `Jarvis` scheme, and Run. When adding or removing Swift source files, regenerate the deterministic project before building:

```bash
node scripts/generate-xcode-project.js
```

## Configure Gemini

1. Open **Jarvis Settings → AI**.
2. Paste a Gemini API key.
3. Keep the current default model (`gemini-3.6-flash`) or enter another supported model ID.
4. Enter a home location for weather questions that do not name a place.
5. Choose **Test Connection**, then **Save Settings**.

Jarvis keeps custom function calling available for other compatible model IDs. The combined Google Search plus function-tool path requires a Gemini 3 model, so older models will not receive the built-in Search tool.

The API key is stored only as a macOS Keychain generic-password item. Jarvis sends it in the `x-goog-api-key` header, never in a URL, preference, source file, or log. Gemini requests use the current Interactions API with `store: false`; Jarvis keeps only a bounded in-memory history. **Clear Conversation** removes that context.

## Microphone and speech permissions

Jarvis requests permissions the first time Talk or automatic listening is enabled. If access was denied, open:

```text
System Preferences → Security & Privacy → Privacy → Microphone
System Preferences → Security & Privacy → Privacy → Speech Recognition
```

Enable Jarvis in both lists and relaunch it. Removing or disconnecting the active microphone stops the current session gracefully rather than crashing the app.

## Configure Home Assistant

1. Verify the desired lights, switches, fans, thermostats, scenes, scripts, media players, and covers already work in Home Assistant.
2. In the Home Assistant user profile, create a long-lived access token.
3. Open **Jarvis Settings → Smart Home**.
4. Enter the URL, for example `http://homeassistant.local:8123`, and paste the token.
5. Choose **Test Connection** or **Refresh Devices**, confirm the real inventory, then save.

The URL is a normal preference; the bearer token is stored only in Keychain. Jarvis uses real `/api/states` discovery, the fixed `/api/template` area lookup, and `/api/services/<domain>/<service>` calls, then refreshes affected entity state before reporting a verifiable change. Unlocking, moving an access cover/garage, disabling or triggering an alarm, and invoking an opaque scene or script require an explicit spoken confirmation.

Supported controls include power, brightness, RGB color, color temperature, fan percentage, thermostat target/mode, scenes, scripts, media playback/volume, and covers. The local fallback grammar handles common power, brightness, fan, routine, volume, and mute commands without Gemini when Home Assistant remains reachable on the LAN.

## Google Home compatibility

Google’s current Home APIs do not support a native macOS 11 AppKit client. Jarvis therefore uses the honest working compatibility path:

```text
Google Home ecosystem ↔ device/vendor/Matter integration ↔ Home Assistant ↔ Jarvis
```

A device merely visible in the Google Home app is not automatically imported into Home Assistant. Add it through a supported vendor, Matter multi-admin, Nest, Hue, Tuya, or other Home Assistant integration first. Jarvis Settings reports **Google Home via Home Assistant** and does not pretend a direct Google SDK is connected.

See [Smart Home](docs/SMART_HOME.md) for supported domains, device resolution, multi-action behavior, and physical acceptance tests.

## Run Jarvis and launch at login

Jarvis lives under **◆ Jarvis** in the menu bar. Use **Talk to Jarvis** to validate the complete voice pipeline before enabling **Start listening automatically**. The main window shows idle, wake, listening, thinking, executing, speaking, and error states.

On Big Sur, launch at login is implemented with a user LaunchAgent. Jarvis must first be placed in `/Applications` or `~/Applications`. The generated agent:

- launches the app’s executable directly;
- starts at login;
- restarts only after an abnormal exit;
- waits at least 60 seconds between restarts;
- does not grow stdout/stderr logs.

Enabling installs the agent atomically for the **next login**; it deliberately does not start a second copy of an already-running Jarvis. A normal **Quit Jarvis** exits successfully and is not restarted. Disabling removes the owned registration before unloading it; if the current Jarvis process is launchd-managed, that unload may also close the app.

## Architecture

```text
AppKit UI / NSStatusItem
        ↓
serialized AssistantStateMachine
        ↓
Microphone → Speech + VAD → Gemini Interactions
                               ↓ explicit tools
                HomeControlProvider / Routines / Mac allowlist
                               ↓ verified results
                      NSSpeechSynthesizer
```

Detailed design and contributor guidance live in:

- [Architecture](docs/ARCHITECTURE.md)
- [Smart Home](docs/SMART_HOME.md)
- [Development](docs/DEVELOPMENT.md)

## Troubleshooting

- **Opening Jarvis appears to do nothing:** Jarvis has no Dock icon. Look for **◆ Jarvis** in the menu bar and choose **Open Jarvis**. Quit any older Jarvis copy before replacing the app. For an automated release, first Control-click `Jarvis.app`, choose **Open**, and approve the Gatekeeper prompt.
- **Talk does nothing:** check both privacy permissions and the selected input device.
- **Hands-free mode is unavailable:** install/enable the macOS on-device dictation language if offered, or use Talk. Jarvis will not use server-assisted recognition continuously while idle.
- **Gemini rejects the key/model:** test the key in Settings and choose a currently supported model ID.
- **Home Assistant connection fails:** test `http://host:8123/api/` from the same Mac, check the token, and prefer a stable LAN hostname or reserved address.
- **A Google Home device is missing:** ensure the entity actually appears and works in Home Assistant; Google Home alone is not an import source.
- **Launch at login cannot be enabled:** move `Jarvis.app` to `/Applications` or `~/Applications` first.
- **Launch at login did not change immediately:** log out and back in once after enabling it; the agent is intentionally activated at the next login.
- **Mac automation is denied:** allow Jarvis under **Security & Privacy → Automation** when macOS prompts.

## Privacy and security

- Idle audio is processed only by an on-device wake path, or hands-free mode stays disabled.
- Command audio is not written to disk or retained.
- Only transcribed commands are sent to Gemini.
- Gemini interaction storage is disabled and history is bounded in memory.
- Gemini and Home Assistant credentials live in Keychain; **Clear Credentials** deletes all Jarvis-owned entries.
- Home Assistant authorization headers and all recognized secret markers are redacted from logs.
- Gemini cannot execute a shell. Mac operations are compiled, typed, and allowlisted.
- Security-sensitive home commands require confirmation and retain only a bounded queue of pending typed actions.

The automated suite validates parsing, state transitions, device mapping/resolution, and project invariants. Microphone behavior, Apple permission prompts, wake reliability, speaker feedback, LaunchAgent recovery, and physical smart-device state must still be tested on the intended Big Sur Mac before calling an installation production-ready.
