import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var stringArrayValue: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap { $0.stringValue }
    }

    var doubleArrayValue: [Double]? {
        guard case .array(let values) = self else { return nil }
        let numbers = values.compactMap { $0.doubleValue }
        return numbers.count == values.count ? numbers : nil
    }
}

struct HomeAssistantEntity: Decodable, Equatable {
    let entityID: String
    let state: String
    let attributes: [String: JSONValue]
    let lastChanged: String?
    let lastUpdated: String?

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case state
        case attributes
        case lastChanged = "last_changed"
        case lastUpdated = "last_updated"
    }

    init(
        entityID: String,
        state: String,
        attributes: [String: JSONValue] = [:],
        lastChanged: String? = nil,
        lastUpdated: String? = nil
    ) {
        self.entityID = entityID
        self.state = state
        self.attributes = attributes
        self.lastChanged = lastChanged
        self.lastUpdated = lastUpdated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try container.decode(String.self, forKey: .entityID)
        state = try container.decode(String.self, forKey: .state)
        attributes = try container.decodeIfPresent([String: JSONValue].self, forKey: .attributes) ?? [:]
        lastChanged = try container.decodeIfPresent(String.self, forKey: .lastChanged)
        lastUpdated = try container.decodeIfPresent(String.self, forKey: .lastUpdated)
    }
}

struct HomeAssistantConfiguration: Decodable, Equatable {
    struct UnitSystem: Decodable, Equatable {
        let temperature: String?
    }

    let unitSystem: UnitSystem?

    enum CodingKeys: String, CodingKey {
        case unitSystem = "unit_system"
    }
}

final class HomeAssistantService {
    typealias BaseURLProvider = () -> String?
    typealias AccessTokenProvider = () -> String?

    private let baseURLProvider: BaseURLProvider
    private let accessTokenProvider: AccessTokenProvider
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        baseURL: @escaping BaseURLProvider,
        accessToken: @escaping AccessTokenProvider,
        session: URLSession = .shared
    ) {
        self.baseURLProvider = baseURL
        self.accessTokenProvider = accessToken
        self.session = session
    }

    convenience init(
        baseURL: URL,
        accessToken: @escaping AccessTokenProvider,
        session: URLSession = .shared
    ) {
        self.init(baseURL: { baseURL.absoluteString }, accessToken: accessToken, session: session)
    }

    @discardableResult
    func testConnection() async throws -> Bool {
        let data = try await request(method: "GET", path: [])
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let response = object as? [String: Any],
            response["message"] is String
        else {
            throw HomeControlError.invalidResponse
        }
        return true
    }

    func fetchStates() async throws -> [HomeAssistantEntity] {
        let data = try await request(method: "GET", path: ["states"])
        do {
            return try decoder.decode([HomeAssistantEntity].self, from: data)
        } catch {
            throw HomeControlError.invalidResponse
        }
    }

    func fetchConfiguration() async throws -> HomeAssistantConfiguration {
        let data = try await request(method: "GET", path: ["config"])
        do {
            return try decoder.decode(HomeAssistantConfiguration.self, from: data)
        } catch {
            throw HomeControlError.invalidResponse
        }
    }

    /// Resolves Home Assistant's real area assignments without relying on
    /// friendly-name heuristics. The template is fixed by Jarvis and returns no
    /// secrets; older installations that lack `area_name` can fall back to the
    /// attributes already handled by HomeAssistantProvider.
    func fetchEntityAreas() async throws -> [String: String] {
        let template = """
        {% set ns = namespace(items=[]) %}
        {% for item in states %}
          {% set area = area_name(item.entity_id) %}
          {% if area %}
            {% set ns.items = ns.items + [{"entity_id": item.entity_id, "area": area}] %}
          {% endif %}
        {% endfor %}
        {{ ns.items | tojson }}
        """
        let body = try encoder.encode(["template": JSONValue.string(template)])
        let data = try await request(method: "POST", path: ["template"], body: body)
        guard let rendered = String(data: data, encoding: .utf8),
              let renderedData = rendered.data(using: .utf8),
              let objects = try? JSONSerialization.jsonObject(with: renderedData) as? [[String: Any]] else {
            throw HomeControlError.invalidResponse
        }
        return Dictionary(uniqueKeysWithValues: objects.compactMap { object in
            guard let entityID = object["entity_id"] as? String,
                  let area = (object["area"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !entityID.isEmpty, !area.isEmpty else { return nil }
            return (entityID, area)
        })
    }

    func fetchState(entityID: String) async throws -> HomeAssistantEntity {
        guard !entityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HomeControlError.deviceNotFound(entityID)
        }
        let data = try await request(method: "GET", path: ["states", entityID])
        do {
            return try decoder.decode(HomeAssistantEntity.self, from: data)
        } catch {
            throw HomeControlError.invalidResponse
        }
    }

    /// Home Assistant acknowledges a service call before some integrations have
    /// propagated their state. Always fetching the entity here prevents callers
    /// from treating the POST alone as proof that the physical state changed.
    @discardableResult
    func callService(
        domain: String,
        service serviceName: String,
        entityID: String,
        fields: [String: JSONValue] = [:]
    ) async throws -> HomeAssistantEntity {
        guard isSafePathComponent(domain), isSafePathComponent(serviceName) else {
            throw HomeControlError.invalidConfiguration("The Home Assistant service name is invalid.")
        }

        var payload = fields
        payload["entity_id"] = .string(entityID)
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            throw HomeControlError.invalidValue("The smart-home command could not be encoded.")
        }

        _ = try await request(
            method: "POST",
            path: ["services", domain, serviceName],
            body: body
        )
        return try await fetchState(entityID: entityID)
    }

    private func request(method: String, path: [String], body: Data? = nil) async throws -> Data {
        let url = try makeAPIURL(path: path)
        let token = try accessToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await perform(request)
        switch response.statusCode {
        case 200...299:
            return data
        case 401:
            throw HomeControlError.authenticationFailed
        case 403:
            throw HomeControlError.permissionDenied
        case 404 where path.first == "states" && path.count > 1:
            throw HomeControlError.deviceNotFound(path[1])
        default:
            throw HomeControlError.serverError(statusCode: response.statusCode)
        }
    }

    /// URLSession's async convenience API requires macOS 12. This wrapper uses
    /// dataTask so the implementation remains deployable to Big Sur.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: HomeControlError.transport(error))
                    return
                }
                guard let response = response as? HTTPURLResponse else {
                    continuation.resume(throwing: HomeControlError.invalidResponse)
                    return
                }
                continuation.resume(returning: (data ?? Data(), response))
            }
            task.resume()
        }
    }

    private func makeAPIURL(path: [String]) throws -> URL {
        let configured = baseURLProvider()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard
            !configured.isEmpty,
            var components = URLComponents(string: configured),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            throw HomeControlError.invalidConfiguration("Enter a valid Home Assistant HTTP or HTTPS URL.")
        }
        guard var url = components.url else {
            throw HomeControlError.invalidConfiguration("Enter a valid Home Assistant URL.")
        }
        url.appendPathComponent("api", isDirectory: true)
        for component in path {
            url.appendPathComponent(component, isDirectory: false)
        }
        return url
    }

    private func accessToken() throws -> String {
        let token = accessTokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw HomeControlError.invalidConfiguration("Enter a Home Assistant long-lived access token.")
        }
        return token
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }
}
