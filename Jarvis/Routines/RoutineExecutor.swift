import Foundation

enum RoutineExecutionPolicy {
    /// Stop immediately after the first failure. This is appropriate for voice
    /// commands because Jarvis must not report a routine as fully successful.
    case stopOnFailure

    /// Attempt independent remaining actions and return every failure. Useful for
    /// shutdown-oriented routines such as Goodnight or Away.
    case continueAfterFailure
}

struct RoutineActionFailure {
    let action: RoutineAction
    let message: String
}

struct RoutineExecutionResult {
    let routine: Routine
    let successfulActions: Int
    let failures: [RoutineActionFailure]

    var succeeded: Bool { failures.isEmpty }

    var spokenMessage: String {
        if succeeded { return routine.completionMessage }
        if successfulActions == 0 {
            return "I couldn't run \(routine.name). \(failures.first?.message ?? "Please try again.")"
        }
        return "I completed part of \(routine.name), but \(failures.count) action\(failures.count == 1 ? "" : "s") failed."
    }
}

enum RoutineExecutionError: LocalizedError {
    case alreadyRunning
    case confirmationRequired(String)
    case invalidDelay

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Another Jarvis routine is already running."
        case .confirmationRequired(let prompt):
            return prompt
        case .invalidDelay:
            return "A routine contains an invalid delay."
        }
    }
}

/// Runs routine actions sequentially to preserve their intended ordering. A
/// single executor never overlaps two routines, which prevents contradictory
/// device or Mac commands from racing each other.
actor RoutineExecutor {
    private let homeProvider: HomeControlProvider
    private let macCommandService: MacCommandService
    private var isExecuting = false

    init(
        homeProvider: HomeControlProvider,
        macCommandService: MacCommandService = MacCommandService()
    ) {
        self.homeProvider = homeProvider
        self.macCommandService = macCommandService
    }

    func execute(
        _ routine: Routine,
        confirmedByUser: Bool = false,
        policy: RoutineExecutionPolicy = .stopOnFailure,
        onProgress: ((Int, Int, RoutineAction) -> Void)? = nil
    ) async throws -> RoutineExecutionResult {
        guard !isExecuting else { throw RoutineExecutionError.alreadyRunning }
        if routine.requiresConfirmation && !confirmedByUser {
            throw RoutineExecutionError.confirmationRequired(
                routine.confirmationPrompt ?? "Are you sure you want me to run this routine?"
            )
        }

        isExecuting = true
        defer { isExecuting = false }

        var successfulActions = 0
        var failures: [RoutineActionFailure] = []

        for (index, action) in routine.actions.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            onProgress?(index + 1, routine.actions.count, action)

            do {
                try await execute(action, confirmedByUser: confirmedByUser)
                successfulActions += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(RoutineActionFailure(
                    action: action,
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ))
                if case .stopOnFailure = policy { break }
            }
        }

        return RoutineExecutionResult(
            routine: routine,
            successfulActions: successfulActions,
            failures: failures
        )
    }

    private func execute(_ action: RoutineAction, confirmedByUser: Bool) async throws {
        switch action {
        case .home(let command):
            let executableCommand = confirmedByUser ? command.confirmedByUser() : command
            try await homeProvider.execute(command: executableCommand)

        case .mac(let command):
            _ = try await macCommandService.execute(command)

        case .delay(let seconds):
            guard seconds.isFinite, seconds >= 0, seconds <= 300 else {
                throw RoutineExecutionError.invalidDelay
            }
            let nanoseconds = UInt64((seconds * 1_000_000_000).rounded())
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    }
}
