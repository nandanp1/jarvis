import Foundation

/// Google's current native Home APIs do not offer a macOS 11 control client.
/// This provider is intentionally honest instead of simulating success; devices
/// shared with Home Assistant remain controllable through HomeAssistantProvider.
final class GoogleAssistantProvider: HomeControlProvider {
    static let unavailableReason = "Direct Google Home control is unavailable on macOS 11. Connect the same devices to Home Assistant and use the Home Assistant bridge."

    var isAvailable: Bool { false }
    var statusDescription: String { Self.unavailableReason }

    func listDevices() async throws -> [SmartDevice] {
        throw HomeControlError.providerUnavailable(Self.unavailableReason)
    }

    func getState(deviceID: String) async throws -> DeviceState {
        throw HomeControlError.providerUnavailable(Self.unavailableReason)
    }

    func execute(command: HomeCommand) async throws {
        throw HomeControlError.providerUnavailable(Self.unavailableReason)
    }
}
