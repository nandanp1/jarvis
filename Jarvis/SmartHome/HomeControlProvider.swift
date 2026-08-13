import Foundation

protocol HomeControlProvider {
    func listDevices() async throws -> [SmartDevice]

    func getState(
        deviceID: String
    ) async throws -> DeviceState

    func execute(
        command: HomeCommand
    ) async throws
}

enum HomeControlError: LocalizedError {
    case providerUnavailable(String)
    case invalidConfiguration(String)
    case authenticationFailed
    case permissionDenied
    case deviceNotFound(String)
    case unsupportedDevice(String)
    case unsupportedCommand(String)
    case invalidValue(String)
    case confirmationRequired(String)
    case actionNotConfirmed(String)
    case invalidResponse
    case serverError(statusCode: Int)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let reason): return reason
        case .invalidConfiguration(let reason): return reason
        case .authenticationFailed: return "Home Assistant rejected the access token."
        case .permissionDenied: return "Home Assistant denied this action."
        case .deviceNotFound(let id): return "The smart-home device \(id) was not found."
        case .unsupportedDevice(let id): return "Jarvis cannot control the device \(id)."
        case .unsupportedCommand(let reason): return reason
        case .invalidValue(let reason): return reason
        case .confirmationRequired(let prompt): return prompt
        case .actionNotConfirmed(let reason): return reason
        case .invalidResponse: return "The smart-home server returned an invalid response."
        case .serverError(let statusCode): return "The smart-home server returned HTTP \(statusCode)."
        case .transport(let error): return "Could not reach the smart-home server: \(error.localizedDescription)"
        }
    }
}
