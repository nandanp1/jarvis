# Jarvis Development Guide

Jarvis is a native AppKit application with a hard macOS 11.0 deployment target.
This guide covers reproducible project generation, local builds, automated
checks, and the hardware tests that CI cannot perform.

## Prerequisites

- macOS 11.0 Big Sur or newer
- Xcode with the macOS SDK and command-line tools
- Swift supplied by Xcode
- Git
- Node.js only when regenerating the checked-in Xcode project

Xcode 13.2.x is the practical last-era toolchain for development on Big Sur.
The project file retains Xcode 12 compatibility metadata. CI also compiles with
a newer pinned Xcode to catch forward-compiler issues; that does not permit use
of APIs newer than macOS 11.

Before diagnosing a toolchain issue, record the host:

```bash
sw_vers
uname -m
xcodebuild -version
swift --version
git --version
gh --version
```

Both `x86_64` and `arm64` are supported. Prefer native Apple frameworks and
source dependencies. Do not add a prebuilt library unless it explicitly
supports both architectures and macOS 11.

## Repository setup

The canonical repository and branch are:

```text
https://github.com/nandanp1/jarvis
main
```

Clone it at `~/jarvis` when possible:

```bash
cd ~
git clone https://github.com/nandanp1/jarvis.git
cd jarvis
git remote -v
git branch --show-current
```

If a working copy already exists, inspect it before updating. Do not overwrite
unrelated local work:

```bash
git status
git remote -v
git branch --show-current
git pull --rebase origin main
```

`origin` must resolve to `https://github.com/nandanp1/jarvis.git` (or the
equivalent authenticated GitHub URL for that repository).

## Project structure

```text
Jarvis/
  Application/     app lifetime, coordinator, menu bar, logging
  Assistant/       state, request orchestration, intent routing, conversation
  Audio/           capture, recognition, VAD, wake word, synthesis
  AI/              Gemini transport/models and tool routing
  SmartHome/       provider abstraction and Home Assistant implementation
  Mac/             typed, allowlisted Mac controls and status
  Security/        Keychain access
  Routines/        routine models and execution
  UI/              ambient window, settings, reusable AppKit views
  Persistence/     non-secret preferences
  Resources/       Info.plist and entitlements
JarvisTests/        deterministic unit and integration-boundary tests
docs/               design and operations documentation
scripts/            project generation and static validation
```

Keep services focused. Audio capture, HTTP transport, intent parsing, device
resolution, and UI state should remain independently testable.

## Generate the Xcode project

`Jarvis.xcodeproj` is checked in so building Jarvis does not require Node.js.
When adding, removing, or moving Swift files, regenerate it from the source tree:

```bash
node scripts/generate-xcode-project.js
```

The generator is deterministic and has no third-party packages. Review the
result before committing:

```bash
git diff -- Jarvis.xcodeproj
```

Do not hand-edit the project and forget the generator. A later regeneration
would erase that change. Project settings that must remain fixed include:

```text
Project / scheme / product: Jarvis
Bundle identifier:          com.nandan.jarvis
Deployment target:          11.0
Shared scheme:              Jarvis
```

## Validate and build

Run repository invariants first:

```bash
./scripts/validate-project.sh
```

Build without requiring a personal signing identity:

```bash
xcodebuild \
  -project Jarvis.xcodeproj \
  -scheme Jarvis \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/JarvisDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run tests:

```bash
xcodebuild \
  -project Jarvis.xcodeproj \
  -scheme Jarvis \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/JarvisDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

For an architecture-neutral compile check on a capable modern toolchain:

```bash
xcodebuild \
  -project Jarvis.xcodeproj \
  -scheme Jarvis \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/JarvisUniversalDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS='x86_64 arm64' \
  build
```

Use a task-specific DerivedData path. Never commit DerivedData or build output.

## Continuous integration

`.github/workflows/build.yml` runs static validation, a universal Debug build,
and unit tests for pushes and pull requests targeting `main`. It selects an
explicit Xcode installation on an explicit macOS runner image instead of using
`macos-latest` and whatever Xcode happens to be selected that week.

The CI runner is newer than Big Sur. It proves the source can compile *for* the
11.0 deployment target; it cannot prove every path works *on* macOS 11. The
release checklist therefore includes a real Big Sur smoke test.

When GitHub retires a runner image or removes an Xcode installation, update the
pin deliberately. In that pull request, keep `MACOSX_DEPLOYMENT_TARGET = 11.0`,
run the compatibility checks, and document why the CI host changed.

## Permissions and local configuration

Jarvis needs these macOS privacy grants:

- **System Preferences > Security & Privacy > Privacy > Microphone**
- **System Preferences > Security & Privacy > Privacy > Speech Recognition**

The usage descriptions live in `Jarvis/Resources/Info.plist`. If permission is
denied, the app must remain running, show a useful error, and allow the user to
open settings or retry later.

Enter credentials through Jarvis Settings. Gemini API keys and Home Assistant
tokens belong in Keychain, never in source, schemes, environment files,
`UserDefaults`, screenshots, logs, or test fixtures.

The Home Assistant URL itself is non-secret, but Jarvis rejects embedded URL
credentials, query strings, and fragments so tokens cannot accidentally escape
Keychain. Plain HTTP is appropriate only on a trusted local network; use HTTPS
when traffic crosses an untrusted boundary.

For local Home Assistant setup and physical verification, see
[SMART_HOME.md](SMART_HOME.md).

## Testing strategy

### Deterministic automated tests

Prefer protocols and injected fakes for tests. Automated coverage should include:

- every valid and invalid assistant-state transition
- conversation-history trimming and Clear Conversation
- local command parsing, ambiguity, and numeric range validation
- natural device-name resolution
- Home Assistant JSON decoding and domain/service payloads
- HTTP status, timeout, malformed-response, and authentication errors
- Gemini response decoding, tool validation, iteration limits, and multi-call
  behavior
- Keychain error propagation without revealing values
- routine ordering and partial failure
- sensitive-action confirmation expiry
- wake/synthesis mutual exclusion and cooldown scheduling

Tests must not contact a personal Gemini account, Home Assistant server, or
physical device. Network transports, clocks, audio sources, and speech output
should be injectable at their boundaries.

### Manual voice acceptance

Run on the intended Big Sur Mac with its actual microphone and speakers:

1. Press **Talk to Jarvis**, speak naturally, pause, and confirm VAD finalizes
   without an arbitrary fixed recording period.
2. Confirm the transcript, Gemini response, and spoken output.
3. Say “Hey Jarvis,” then a command, and verify the state sequence.
4. While Jarvis speaks, say the wake phrase and confirm it is ignored.
5. Confirm wake listening resumes after the cooldown.
6. Ask “Who is Tim Cook?” followed by “How old is he?” to verify bounded context.
7. Deny each permission in turn and verify a graceful, recoverable error.

Apple Speech on Big Sur does not guarantee local recognition for every locale or
machine. Hands-free idle recognition must only run when the recognizer supports
required on-device recognition. If it cannot, verify Jarvis clearly disables
hands-free mode and leaves manual Talk functional; do not accept a silent
server-assisted idle fallback.

### Smart-home acceptance

Mock-provider tests verify code behavior. Only a test against the user's Home
Assistant instance and physical devices establishes working smart-home control.
Run the command and failure matrix in [SMART_HOME.md](SMART_HOME.md), including
multi-action and partial-failure cases.

### Failure and endurance checks

Exercise these independently:

- no microphone or the active input device disconnects
- microphone or Speech permission denied
- no internet, DNS failure, Gemini timeout, wrong Gemini key
- Home Assistant offline, invalid token, entity unavailable
- speech synthesis disabled or interrupted
- sleep/wake and audio-route changes
- repeated wake/command/speak cycles over several hours

Watch memory, CPU, open audio taps, recognition tasks, and request counts.
Histories and caches must remain bounded, and errors must not trigger rapid retry
loops.

## Logging and diagnostics

Jarvis uses unified logging. Inspect development messages in Console.app by the
`com.nandan.jarvis` subsystem, or from Terminal:

```bash
log stream --predicate 'subsystem == "com.nandan.jarvis"' --level info
```

Never add secrets to an interpolated log message. Redaction is defense in depth,
not permission to pass keys, tokens, authorization headers, full Gemini request
bodies, or captured audio to the logger.

## Git workflow

Keep commits small enough to build and review. Before every commit:

```bash
git status
git diff
./scripts/validate-project.sh
```

Then build and run relevant tests. Push completed milestones to `main` when
repository policy allows it. If branch protection rejects a direct push, create
a `codex/<descriptive-feature>` branch and a pull request into `main`. Never
force-push or rewrite published history as part of routine development.

Before handing off:

```bash
git status
git log -5 --oneline
git remote -v
git branch --show-current
```

The worktree should contain no accidental source changes and no credentials,
captured audio, DerivedData, or user-specific Xcode state.

## Big Sur compatibility review

For every Apple API introduced in a change:

1. Check availability in Apple documentation and the SDK interface.
2. Avoid APIs introduced after macOS 11 unless a guarded Big Sur path is tested.
3. Prefer AppKit, AVFoundation, Speech, Security, Foundation, Network, IOKit,
   and QuartzCore APIs already available on Big Sur.
4. Use `NSStatusItem`, not `MenuBarExtra`.
5. Test both Intel and Apple-silicon compilation.
6. Run the app on macOS 11 before declaring the feature working there.
