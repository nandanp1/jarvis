import AppKit
import Foundation

/// Applications Jarvis is permitted to launch or politely terminate. Keeping
/// this list closed prevents an AI tool call from becoming arbitrary process
/// execution.
enum MacApplication: String, CaseIterable, Hashable {
    case calendar = "com.apple.iCal"
    case facetime = "com.apple.FaceTime"
    case mail = "com.apple.mail"
    case maps = "com.apple.Maps"
    case messages = "com.apple.iChat"
    case music = "com.apple.Music"
    case notes = "com.apple.Notes"
    case photos = "com.apple.Photos"
    case preview = "com.apple.Preview"
    case safari = "com.apple.Safari"
    case spotify = "com.spotify.client"
    case systemPreferences = "com.apple.systempreferences"

    var displayName: String {
        switch self {
        case .calendar: return "Calendar"
        case .facetime: return "FaceTime"
        case .mail: return "Mail"
        case .maps: return "Maps"
        case .messages: return "Messages"
        case .music: return "Music"
        case .notes: return "Notes"
        case .photos: return "Photos"
        case .preview: return "Preview"
        case .safari: return "Safari"
        case .spotify: return "Spotify"
        case .systemPreferences: return "System Preferences"
        }
    }
}

enum MacCommand: Hashable {
    case setVolume(percent: Int)
    case volumeUp(step: Int)
    case volumeDown(step: Int)
    case mute
    case unmute
    case toggleMute
    case openApplication(MacApplication)
    case closeApplication(MacApplication)
    case sleepDisplay
    case startMusic
    case pauseMusic

    var safeDescription: String {
        switch self {
        case .setVolume: return "Set Mac volume"
        case .volumeUp: return "Increase Mac volume"
        case .volumeDown: return "Decrease Mac volume"
        case .mute: return "Mute Mac audio"
        case .unmute: return "Unmute Mac audio"
        case .toggleMute: return "Toggle Mac mute"
        case .openApplication(let application): return "Open \(application.displayName)"
        case .closeApplication(let application): return "Close \(application.displayName)"
        case .sleepDisplay: return "Sleep the display"
        case .startMusic: return "Start Music playback"
        case .pauseMusic: return "Pause Music playback"
        }
    }
}

struct MacCommandResult {
    let command: MacCommand
    let message: String
}

enum MacCommandError: LocalizedError {
    case invalidVolume(Int)
    case invalidVolumeStep(Int)
    case applicationNotInstalled(String)
    case applicationWouldNotClose(String)
    case automationUnavailable
    case automationFailed
    case processFailed(command: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidVolume(let value):
            return "Volume must be between 0 and 100 percent, not \(value)."
        case .invalidVolumeStep(let value):
            return "A volume adjustment must be between 1 and 25 percent, not \(value)."
        case .applicationNotInstalled(let name):
            return "\(name) is not installed on this Mac."
        case .applicationWouldNotClose(let name):
            return "\(name) did not accept the request to close."
        case .automationUnavailable:
            return "macOS automation is unavailable."
        case .automationFailed:
            return "macOS did not complete the requested automation."
        case .processFailed(let command, let status):
            return "\(command) failed with status \(status)."
        }
    }
}

/// Executes a deliberately small set of Mac actions. There is no shell or raw
/// command entry point: every process, bundle identifier, argument, and AppleScript
/// source is selected by Jarvis code.
final class MacCommandService {
    @MainActor
    func execute(_ command: MacCommand) async throws -> MacCommandResult {
        switch command {
        case .setVolume(let percent):
            try setVolume(percent)
            return MacCommandResult(command: command, message: "Mac volume is at \(percent) percent.")

        case .volumeUp(let step):
            try validate(step: step)
            let updated = min(100, try currentVolume() + step)
            try setVolume(updated)
            return MacCommandResult(command: command, message: "Mac volume is at \(updated) percent.")

        case .volumeDown(let step):
            try validate(step: step)
            let updated = max(0, try currentVolume() - step)
            try setVolume(updated)
            return MacCommandResult(command: command, message: "Mac volume is at \(updated) percent.")

        case .mute:
            try executeAppleScript("set volume with output muted")
            return MacCommandResult(command: command, message: "Mac audio is muted.")

        case .unmute:
            try executeAppleScript("set volume without output muted")
            return MacCommandResult(command: command, message: "Mac audio is unmuted.")

        case .toggleMute:
            let willMute = try !isMuted()
            try executeAppleScript(willMute ? "set volume with output muted" : "set volume without output muted")
            return MacCommandResult(command: command, message: willMute ? "Mac audio is muted." : "Mac audio is unmuted.")

        case .openApplication(let application):
            _ = try await open(application)
            return MacCommandResult(command: command, message: "Opened \(application.displayName).")

        case .closeApplication(let application):
            try close(application)
            return MacCommandResult(command: command, message: "Closed \(application.displayName).")

        case .sleepDisplay:
            try await runDisplaySleepCommand()
            return MacCommandResult(command: command, message: "The display is asleep.")

        case .startMusic:
            _ = try await open(.music)
            try executeAppleScript("tell application id \"com.apple.Music\" to play")
            return MacCommandResult(command: command, message: "Music is playing.")

        case .pauseMusic:
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: MacApplication.music.rawValue).isEmpty else {
                return MacCommandResult(command: command, message: "Music is already paused.")
            }
            try executeAppleScript("tell application id \"com.apple.Music\" to pause")
            return MacCommandResult(command: command, message: "Music is paused.")
        }
    }

    private func validate(step: Int) throws {
        guard (1...25).contains(step) else {
            throw MacCommandError.invalidVolumeStep(step)
        }
    }

    private func setVolume(_ percent: Int) throws {
        guard (0...100).contains(percent) else {
            throw MacCommandError.invalidVolume(percent)
        }
        try executeAppleScript("set volume output volume \(percent)")
    }

    private func currentVolume() throws -> Int {
        let descriptor = try executeAppleScript("output volume of (get volume settings)")
        return Int(descriptor.int32Value)
    }

    private func isMuted() throws -> Bool {
        let descriptor = try executeAppleScript("output muted of (get volume settings)")
        return descriptor.booleanValue
    }

    @discardableResult
    private func executeAppleScript(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw MacCommandError.automationUnavailable
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { throw MacCommandError.automationFailed }
        return result
    }

    private func open(_ application: MacApplication) async throws -> NSRunningApplication {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: application.rawValue) else {
            throw MacCommandError.applicationNotInstalled(application.displayName)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { runningApplication, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let runningApplication = runningApplication {
                    continuation.resume(returning: runningApplication)
                } else {
                    continuation.resume(throwing: MacCommandError.automationFailed)
                }
            }
        }
    }

    private func close(_ application: MacApplication) throws {
        let runningApplications = NSRunningApplication.runningApplications(withBundleIdentifier: application.rawValue)
        guard !runningApplications.isEmpty else { return }
        guard runningApplications.allSatisfy({ $0.terminate() }) else {
            throw MacCommandError.applicationWouldNotClose(application.displayName)
        }
    }

    private func runDisplaySleepCommand() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: MacCommandError.processFailed(
                        command: "Display sleep",
                        status: process.terminationStatus
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
