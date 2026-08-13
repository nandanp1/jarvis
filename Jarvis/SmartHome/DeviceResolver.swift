import Foundation

struct DeviceMatch: Hashable {
    let device: SmartDevice
    let score: Int
}

/// Resolves spoken names without leaking Home Assistant entity IDs into the
/// conversation. Recent usage is deliberately in-memory and bounded.
final class DeviceResolver {
    private let lock = NSLock()
    private let maximumRecentDevices: Int
    private var recentDeviceIDs: [String] = []

    init(maximumRecentDevices: Int = 8) {
        self.maximumRecentDevices = max(1, maximumRecentDevices)
    }

    func resolve(
        _ reference: String,
        among devices: [SmartDevice],
        preferredRoom: String? = nil
    ) -> SmartDevice? {
        let normalizedReference = Self.normalize(reference)
        if Self.isRecentReference(normalizedReference),
           let recent = mostRecentDevice(among: devices) {
            return recent
        }

        let matches = rankedMatches(reference, among: devices, preferredRoom: preferredRoom)
        guard let best = matches.first, best.score >= 18 else { return nil }
        if matches.count > 1, matches[1].score == best.score {
            let recents = recentIDsSnapshot()
            let bestRecent = recents.firstIndex(of: best.device.id)
            let secondRecent = recents.firstIndex(of: matches[1].device.id)
            if bestRecent == nil && secondRecent == nil { return nil }
        }
        return best.device
    }

    func resolveAll(
        _ reference: String,
        among devices: [SmartDevice],
        preferredRoom: String? = nil
    ) -> [SmartDevice] {
        let normalized = Self.normalize(reference)
        let queryTokens = Self.significantTokens(in: normalized)
        let requestedType = Self.deviceTypeToken(in: queryTokens)
        let room = preferredRoom.map(Self.normalize) ?? Self.roomReference(in: normalized, devices: devices)
        var unresolvedQualifiers = queryTokens
        unresolvedQualifiers.subtract(["all", "everything"])
        if let requestedType = requestedType { unresolvedQualifiers.remove(requestedType) }
        if let room = room {
            unresolvedQualifiers.subtract(Self.significantTokens(in: room))
        }
        guard unresolvedQualifiers.isEmpty else { return [] }

        return devices.filter { device in
            if let requestedType = requestedType,
               !Self.typeTokens(for: device.type).contains(requestedType) {
                return false
            }
            if let room = room {
                guard let deviceRoom = device.room else { return false }
                let normalizedDeviceRoom = Self.normalize(deviceRoom)
                if !normalizedDeviceRoom.contains(room), !room.contains(normalizedDeviceRoom) {
                    return false
                }
            }
            return true
        }
    }

    func rankedMatches(
        _ reference: String,
        among devices: [SmartDevice],
        preferredRoom: String? = nil
    ) -> [DeviceMatch] {
        let normalizedReference = Self.normalize(reference)
        let queryTokens = Self.significantTokens(in: normalizedReference)
        guard !queryTokens.isEmpty else { return [] }
        let recents = recentIDsSnapshot()
        let preferred = preferredRoom.map(Self.normalize)

        return devices.map { device in
            let name = Self.normalize(device.name)
            let entityName = Self.normalize(
                device.id.split(separator: ".", maxSplits: 1).last.map(String.init) ?? device.id
            )
            let room = device.room.map(Self.normalize)
            var candidateTokens = Self.significantTokens(in: name + " " + entityName)
            candidateTokens.formUnion(Self.typeTokens(for: device.type))
            if let room = room { candidateTokens.formUnion(Self.significantTokens(in: room)) }

            var score = 0
            if normalizedReference == name { score += 120 }
            if normalizedReference == entityName { score += 105 }
            if name.contains(normalizedReference) || entityName.contains(normalizedReference) { score += 48 }
            if normalizedReference.contains(name), name.count > 2 { score += 35 }

            let overlap = queryTokens.intersection(candidateTokens)
            score += overlap.reduce(0) { total, token in
                total + (Self.genericTypeTokens.contains(token) ? 6 : 13)
            }
            if queryTokens.isSubset(of: candidateTokens) { score += 24 }

            if let preferred = preferred {
                if room == preferred || room?.contains(preferred) == true { score += 22 }
                else if room != nil { score -= 8 }
            }
            if let index = recents.firstIndex(of: device.id) {
                score += max(2, 14 - index * 2)
            }
            return DeviceMatch(device: device, score: score)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let leftRecent = recents.firstIndex(of: $0.device.id) ?? Int.max
            let rightRecent = recents.firstIndex(of: $1.device.id) ?? Int.max
            if leftRecent != rightRecent { return leftRecent < rightRecent }
            return $0.device.name.localizedCaseInsensitiveCompare($1.device.name) == .orderedAscending
        }
    }

    func recordUsage(of device: SmartDevice) {
        recordUsage(deviceID: device.id)
    }

    func recordUsage(deviceID: String) {
        lock.lock()
        defer { lock.unlock() }
        recentDeviceIDs.removeAll { $0 == deviceID }
        recentDeviceIDs.insert(deviceID, at: 0)
        if recentDeviceIDs.count > maximumRecentDevices {
            recentDeviceIDs.removeLast(recentDeviceIDs.count - maximumRecentDevices)
        }
    }

    func clearRecentContext() {
        lock.lock()
        recentDeviceIDs.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Kept for callers compiled against the original resolver API.
    func clearRecentDevices() {
        clearRecentContext()
    }

    private func mostRecentDevice(among devices: [SmartDevice]) -> SmartDevice? {
        let devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        return recentIDsSnapshot().compactMap { devicesByID[$0] }.first
    }

    private func recentIDsSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recentDeviceIDs
    }

    private static let ignoredTokens: Set<String> = [
        "a", "an", "and", "at", "down", "for", "in", "me", "my", "of",
        "off", "on", "please", "set", "the", "to", "turn", "up"
    ]
    private static let genericTypeTokens: Set<String> = [
        "alarm", "cover", "fan", "light", "lock", "media", "outlet",
        "scene", "script", "switch", "thermostat"
    ]

    private static func normalize(_ input: String) -> String {
        let folded = input.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .map { canonicalToken(String($0)) }
            .joined(separator: " ")
    }

    private static func significantTokens(in normalized: String) -> Set<String> {
        Set(normalized.split(separator: " ").map(String.init).filter {
            !ignoredTokens.contains($0) && Int($0) == nil
        })
    }

    private static func canonicalToken(_ token: String) -> String {
        switch token {
        case "lamps", "lamp", "lights": return "light"
        case "fans": return "fan"
        case "switches": return "switch"
        case "outlets", "plugs", "plug": return "outlet"
        case "television", "tv", "speaker", "speakers": return "media"
        case "blinds", "blind", "shades", "shade", "curtain", "curtains": return "cover"
        case "heater", "heating", "ac", "aircon": return "thermostat"
        case "locks", "doorlock": return "lock"
        default: return token
        }
    }

    private static func typeTokens(for type: DeviceType) -> Set<String> {
        switch type {
        case .light: return ["light"]
        case .switchDevice: return ["switch"]
        case .outlet: return ["outlet", "switch"]
        case .fan: return ["fan"]
        case .thermostat: return ["thermostat"]
        case .scene: return ["scene"]
        case .script: return ["script"]
        case .mediaPlayer: return ["media"]
        case .cover: return ["cover"]
        case .garageDoor: return ["cover", "garage"]
        case .lock: return ["lock"]
        case .alarm: return ["alarm"]
        case .sensor: return ["sensor"]
        case .unknown: return []
        }
    }

    private static func deviceTypeToken(in tokens: Set<String>) -> String? {
        tokens.first(where: { genericTypeTokens.contains($0) })
    }

    private static func roomReference(in normalized: String, devices: [SmartDevice]) -> String? {
        let rooms = Set(devices.compactMap { $0.room.map(Self.normalize) })
        return rooms.sorted { $0.count > $1.count }.first {
            normalized == $0 || normalized.hasPrefix($0 + " ") ||
                normalized.hasSuffix(" " + $0) || normalized.contains(" " + $0 + " ")
        }
    }

    private static func isRecentReference(_ normalized: String) -> Bool {
        if ["it", "that", "that one", "the same one", "same device", "same one"].contains(normalized) {
            return true
        }
        let tokens = significantTokens(in: normalized)
        return !tokens.isEmpty && tokens.isSubset(of: ["it", "that", "one", "same", "device"])
    }
}
