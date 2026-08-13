import AppKit
import Darwin
import Foundation
import IOKit.ps

enum HardwareArchitecture: String {
    case arm64
    case x86_64
    case unknown
}

enum PowerSource: String {
    case acPower = "AC Power"
    case battery = "Battery Power"
    case unknown = "Unknown"
}

struct BatteryStatus {
    let percentage: Int
    let isCharging: Bool
    let powerSource: PowerSource
    let timeRemainingMinutes: Int?
}

struct AudioOutputStatus {
    let volumePercent: Int
    let isMuted: Bool
}

struct SystemStatus {
    let hardwareArchitecture: HardwareArchitecture
    let executableArchitecture: HardwareArchitecture
    let isRunningUnderRosetta: Bool
    let operatingSystem: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let systemUptime: TimeInterval
    let battery: BatteryStatus?
    let audioOutput: AudioOutputStatus?
}

enum SystemStatusError: LocalizedError {
    case automationUnavailable
    case audioStatusUnavailable

    var errorDescription: String? {
        switch self {
        case .automationUnavailable:
            return "macOS automation is unavailable."
        case .audioStatusUnavailable:
            return "The Mac audio status is unavailable."
        }
    }
}

/// Provides read-only Mac state for Jarvis responses. It uses native power-source
/// APIs and the built-in `get volume settings` command, with no polling of its own.
final class SystemStatusService {
    @MainActor
    func currentStatus() -> SystemStatus {
        let processInfo = ProcessInfo.processInfo
        return SystemStatus(
            hardwareArchitecture: hardwareArchitecture(),
            executableArchitecture: executableArchitecture(),
            isRunningUnderRosetta: sysctlFlag(named: "sysctl.proc_translated"),
            operatingSystem: processInfo.operatingSystemVersionString,
            processorCount: processInfo.processorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            systemUptime: processInfo.systemUptime,
            battery: batteryStatus(),
            audioOutput: try? audioOutputStatus()
        )
    }

    @MainActor
    func currentVolume() throws -> Int {
        try audioOutputStatus().volumePercent
    }

    func currentBatteryLevel() -> Int? {
        batteryStatus()?.percentage
    }

    @MainActor
    func audioOutputStatus() throws -> AudioOutputStatus {
        let volume = try executeAppleScript("output volume of (get volume settings)")
        let muted = try executeAppleScript("output muted of (get volume settings)")
        let percent = Int(volume.int32Value)
        guard (0...100).contains(percent) else {
            throw SystemStatusError.audioStatusUnavailable
        }
        return AudioOutputStatus(volumePercent: percent, isMuted: muted.booleanValue)
    }

    func batteryStatus() -> BatteryStatus? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceList = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [AnyObject] else {
            return nil
        }

        for source in sourceList {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let currentCapacity = number(for: kIOPSCurrentCapacityKey, in: description),
                  let maximumCapacity = number(for: kIOPSMaxCapacityKey, in: description),
                  maximumCapacity.doubleValue > 0 else {
                continue
            }

            let percentage = Int((currentCapacity.doubleValue / maximumCapacity.doubleValue * 100).rounded())
            let charging = number(for: kIOPSIsChargingKey, in: description)?.boolValue ?? false
            let timeRemaining = number(for: kIOPSTimeToEmptyKey, in: description)?.intValue
            let usableTimeRemaining = timeRemaining.flatMap { $0 >= 0 ? $0 : nil }
            let state = string(for: kIOPSPowerSourceStateKey, in: description)
            let powerSource: PowerSource
            if state == kIOPSACPowerValue {
                powerSource = .acPower
            } else if state == kIOPSBatteryPowerValue {
                powerSource = .battery
            } else {
                powerSource = .unknown
            }

            return BatteryStatus(
                percentage: max(0, min(100, percentage)),
                isCharging: charging,
                powerSource: powerSource,
                timeRemainingMinutes: usableTimeRemaining
            )
        }
        return nil
    }

    private func hardwareArchitecture() -> HardwareArchitecture {
        if sysctlFlag(named: "hw.optional.arm64") { return .arm64 }

        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.x86_64", &value, &size, nil, 0) == 0, value == 1 {
            return .x86_64
        }
        return executableArchitecture()
    }

    private func executableArchitecture() -> HardwareArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .unknown
        #endif
    }

    private func sysctlFlag(named name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && value == 1
    }

    private func number(for key: String, in description: [String: Any]) -> NSNumber? {
        description[key] as? NSNumber
    }

    private func string(for key: String, in description: [String: Any]) -> String? {
        description[key] as? String
    }

    private func executeAppleScript(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw SystemStatusError.automationUnavailable
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { throw SystemStatusError.audioStatusUnavailable }
        return result
    }
}
