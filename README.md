# Jarvis

Jarvis is an always-on, menu-bar room assistant for macOS 11 Big Sur. It is being built with AppKit and native Apple audio frameworks so an older Mac can act like a dedicated voice appliance while Gemini handles reasoning and Home Assistant bridges smart-home control.

The application is under active implementation. See `docs/` for architecture and setup details as each subsystem lands.

## Requirements

- macOS 11.0 Big Sur or newer
- Xcode 13.2 or newer
- A microphone and Speech Recognition permission
- A Gemini API key for cloud reasoning
- Home Assistant plus a long-lived access token for smart-home control

Open `Jarvis.xcodeproj`, select the `Jarvis` scheme, and run the Debug configuration.

