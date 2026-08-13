import Foundation

enum RoutineName: String, CaseIterable, Codable {
    case goodnight
    case gaming
    case movie
    case study
    case wakeUp = "wake_up"
    case away

    var displayName: String {
        switch self {
        case .goodnight: return "Goodnight"
        case .gaming: return "Gaming"
        case .movie: return "Movie"
        case .study: return "Study"
        case .wakeUp: return "Wake Up"
        case .away: return "Away"
        }
    }
}

enum RoutineAction: Hashable {
    case home(HomeCommand)
    case mac(MacCommand)
    case delay(seconds: TimeInterval)

    var description: String {
        switch self {
        case .home(let command):
            return "Smart home: \(command.deviceID)"
        case .mac(let command):
            return command.safeDescription
        case .delay(let seconds):
            return "Wait \(seconds) seconds"
        }
    }
}

struct Routine: Hashable {
    let id: String
    var name: String
    var invocationPhrases: [String]
    var actions: [RoutineAction]
    var completionMessage: String

    init(
        id: String,
        name: String,
        invocationPhrases: [String] = [],
        actions: [RoutineAction],
        completionMessage: String
    ) {
        self.id = id
        self.name = name
        self.invocationPhrases = invocationPhrases
        self.actions = actions
        self.completionMessage = completionMessage
    }

    var requiresConfirmation: Bool {
        actions.contains { action in
            guard case .home(let command) = action else { return false }
            return command.requiresConfirmation
        }
    }

    var confirmationPrompt: String? {
        actions.compactMap { action -> String? in
            guard case .home(let command) = action else { return nil }
            return command.confirmationPrompt
        }.first
    }
}

/// Starter routines map to Home Assistant scene/script entity IDs. They become
/// immediately useful when the matching scene or script exists, and remain easy
/// to replace with per-device actions in the settings UI later.
enum DefaultRoutines {
    static let all: [Routine] = [
        Routine(
            id: RoutineName.goodnight.rawValue,
            name: RoutineName.goodnight.displayName,
            invocationPhrases: ["goodnight", "good night", "bedtime"],
            actions: [
                .home(.activateScene(deviceID: "scene.goodnight")),
                .mac(.setVolume(percent: 20))
            ],
            completionMessage: "Goodnight."
        ),
        Routine(
            id: RoutineName.gaming.rawValue,
            name: RoutineName.gaming.displayName,
            invocationPhrases: ["gaming mode", "start gaming"],
            actions: [
                .home(.activateScene(deviceID: "scene.gaming")),
                .mac(.setVolume(percent: 45))
            ],
            completionMessage: "Gaming mode is ready."
        ),
        Routine(
            id: RoutineName.movie.rawValue,
            name: RoutineName.movie.displayName,
            invocationPhrases: ["movie mode", "start movie mode"],
            actions: [
                .home(.activateScene(deviceID: "scene.movie")),
                .mac(.setVolume(percent: 35))
            ],
            completionMessage: "Movie mode is ready."
        ),
        Routine(
            id: RoutineName.study.rawValue,
            name: RoutineName.study.displayName,
            invocationPhrases: ["study mode", "focus mode"],
            actions: [
                .home(.activateScene(deviceID: "scene.study")),
                .mac(.pauseMusic),
                .mac(.setVolume(percent: 20))
            ],
            completionMessage: "Study mode is ready."
        ),
        Routine(
            id: RoutineName.wakeUp.rawValue,
            name: RoutineName.wakeUp.displayName,
            invocationPhrases: ["wake up", "good morning", "morning routine"],
            actions: [
                .home(.activateScene(deviceID: "scene.wake_up")),
                .mac(.setVolume(percent: 30))
            ],
            completionMessage: "Good morning."
        ),
        Routine(
            id: RoutineName.away.rawValue,
            name: RoutineName.away.displayName,
            invocationPhrases: ["away mode", "I'm leaving", "leaving home"],
            actions: [
                .home(.activateScene(deviceID: "scene.away")),
                .mac(.pauseMusic)
            ],
            completionMessage: "Away mode is active."
        )
    ]

    static func routine(named name: RoutineName) -> Routine {
        // `all` is exhaustively built from RoutineName; retain a defensive
        // fallback so this API never traps if a future case is added incorrectly.
        all.first { $0.id == name.rawValue } ?? Routine(
            id: name.rawValue,
            name: name.displayName,
            actions: [],
            completionMessage: "\(name.displayName) is ready."
        )
    }
}
