import Darwin
import Foundation

enum LaunchAtLoginError: LocalizedError {
    case applicationMustBeInstalled
    case executableMissing
    case conflictingLaunchAgent
    case invalidPropertyList
    case launchctlFailed(action: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .applicationMustBeInstalled:
            return "Move Jarvis to /Applications or ~/Applications before enabling launch at login."
        case .executableMissing:
            return "The Jarvis executable could not be found inside the application bundle."
        case .conflictingLaunchAgent:
            return "A different launch agent is using Jarvis's launch-at-login file."
        case .invalidPropertyList:
            return "Jarvis could not create a valid launch-at-login property list."
        case .launchctlFailed(let action, let status):
            return "launchctl could not \(action) Jarvis (status \(status))."
        }
    }
}

/// Big Sur-compatible launch-at-login registration. The LaunchAgent executes the
/// installed Jarvis binary directly and restarts it only after abnormal exits.
/// A one-minute throttle prevents a rapid crash/relaunch loop. Enabling writes
/// the agent for the next login without starting a second copy of Jarvis now.
final class LaunchAtLoginService {
    static let label = "com.nandan.jarvis.launch-agent"
    static let throttleInterval = 60

    private let fileManager: FileManager
    private let bundleURL: URL
    private let executableURL: URL?
    private let userHomeURL: URL

    init(
        fileManager: FileManager = .default,
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.bundleURL = bundleURL
        self.executableURL = executableURL
        self.userHomeURL = userHomeURL
    }

    var launchAgentURL: URL {
        userHomeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist", isDirectory: false)
    }

    var isEnabled: Bool {
        guard let data = try? Data(contentsOf: launchAgentURL),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = propertyList as? [String: Any],
              dictionary["Label"] as? String == Self.label,
              let configuredProgram = dictionary["Program"] as? String,
              let executableURL = executableURL?.resolvingSymlinksInPath().standardizedFileURL else {
            return false
        }
        return configuredProgram == executableURL.path
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
    }

    func enable() throws {
        let executable = try validatedExecutableURL()
        try validateExistingFileOwnership()

        let launchAgentsDirectory = launchAgentURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: launchAgentsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let data = try launchAgentData(executable: executable)
        try data.write(to: launchAgentURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: launchAgentURL.path)
    }

    func disable() throws {
        // Remove the durable registration before asking launchd to unload it.
        // If Jarvis is the managed process, bootout may terminate this process;
        // deleting first guarantees it will not return at the next login.
        if fileManager.fileExists(atPath: launchAgentURL.path) {
            try validateExistingFileOwnership()
            try fileManager.removeItem(at: launchAgentURL)
        }

        if isJobLoaded {
            try runLaunchctl(arguments: ["bootout", jobTarget])
        }
    }

    private var sessionTarget: String {
        "gui/\(getuid())"
    }

    private var jobTarget: String {
        "\(sessionTarget)/\(Self.label)"
    }

    private var isJobLoaded: Bool {
        (try? runLaunchctl(arguments: ["print", jobTarget])) != nil
    }

    private func validatedExecutableURL() throws -> URL {
        let resolvedBundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedBundle.pathExtension.lowercased() == "app" else {
            throw LaunchAtLoginError.applicationMustBeInstalled
        }

        let allowedRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL,
            userHomeURL.appendingPathComponent("Applications", isDirectory: true).standardizedFileURL
        ]
        guard allowedRoots.contains(where: { isDescendant(resolvedBundle, of: $0) }) else {
            throw LaunchAtLoginError.applicationMustBeInstalled
        }

        guard let executableURL = executableURL?.resolvingSymlinksInPath().standardizedFileURL else {
            throw LaunchAtLoginError.executableMissing
        }
        let expectedExecutableDirectory = resolvedBundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        guard isDescendant(executableURL, of: expectedExecutableDirectory),
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw LaunchAtLoginError.executableMissing
        }
        return executableURL
    }

    private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath.hasPrefix(directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/")
    }

    private func validateExistingFileOwnership() throws {
        guard fileManager.fileExists(atPath: launchAgentURL.path) else { return }
        guard let data = try? Data(contentsOf: launchAgentURL),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = propertyList as? [String: Any],
              dictionary["Label"] as? String == Self.label,
              let program = dictionary["Program"] as? String,
              let arguments = dictionary["ProgramArguments"] as? [String],
              arguments.first == program,
              arguments.dropFirst().contains("--launch-at-login"),
              dictionary["RunAtLoad"] as? Bool == true,
              let keepAlive = dictionary["KeepAlive"] as? [String: Any],
              keepAlive["SuccessfulExit"] as? Bool == false else {
            throw LaunchAtLoginError.conflictingLaunchAgent
        }
    }

    private func launchAgentData(executable: URL) throws -> Data {
        let propertyList: [String: Any] = [
            "Label": Self.label,
            "Program": executable.path,
            "ProgramArguments": [executable.path, "--launch-at-login"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": Self.throttleInterval,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null"
        ]
        guard PropertyListSerialization.propertyList(propertyList, isValidFor: .xml) else {
            throw LaunchAtLoginError.invalidPropertyList
        }
        return try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
    }

    /// Executes launchctl directly. Callers cannot supply a program path and no
    /// shell performs expansion or interpolation of these argument arrays.
    private func runLaunchctl(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let action = arguments.first ?? "update"
            throw LaunchAtLoginError.launchctlFailed(action: action, status: process.terminationStatus)
        }
    }
}
