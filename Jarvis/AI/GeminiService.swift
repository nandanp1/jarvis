import Foundation

final class GeminiService {
    typealias ToolExecutor = (GeminiFunctionCall) async -> GeminiToolExecutionResult

    static let defaultSystemInstruction = """
    You are Jarvis, an intelligent voice assistant running continuously
    on a Mac in the user's room.

    Your role is similar to a highly capable smart-home assistant.

    Be concise and conversational because responses are normally spoken
    aloud.

    Use available tools when the user asks you to perform an action.

    Never claim an action succeeded until its tool reports success.

    For simple requests, respond in one or two sentences.

    Refer to yourself as Jarvis.
    """

    private let session: URLSession
    private let apiKeyProvider: () throws -> String
    private let modelProvider: () -> String
    private let maximumTurnsProvider: () -> Int
    private let locationProvider: () -> String
    private let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1/interactions")!
    private let historyQueue = DispatchQueue(label: "com.nandan.jarvis.gemini-history")
    private var turns: [[[String: Any]]] = []
    private var conversationGeneration = 0
    private let maximumHistoryBytes = 256_000

    init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping () throws -> String,
        modelProvider: @escaping () -> String,
        maximumTurnsProvider: @escaping () -> Int,
        locationProvider: @escaping () -> String = { "" }
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
        self.modelProvider = modelProvider
        self.maximumTurnsProvider = maximumTurnsProvider
        self.locationProvider = locationProvider
    }

    func respond(
        to prompt: String,
        tools: [GeminiToolDefinition],
        onToolsRequested: @escaping ([GeminiFunctionCall]) -> Void,
        execute: @escaping ToolExecutor
    ) async throws -> GeminiResponse {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GeminiError.invalidRequest }

        let context = historyQueue.sync { (turns.flatMap { $0 }, conversationGeneration) }
        let priorSteps = context.0
        var currentTurn: [[String: Any]] = [[
            "type": "user_input",
            "content": [["type": "text", "text": trimmed]]
        ]]
        var executedToolCount = 0

        for _ in 0..<6 {
            let interaction = try await createInteraction(input: priorSteps + currentTurn, tools: tools)
            currentTurn.append(contentsOf: interaction.steps)

            if interaction.functionCalls.isEmpty {
                guard !interaction.outputText.isEmpty else { throw GeminiError.noResponse }
                commit(turn: currentTurn, generation: context.1)
                return GeminiResponse(text: interaction.outputText, executedToolCount: executedToolCount)
            }

            onToolsRequested(interaction.functionCalls)
            for call in interaction.functionCalls {
                let result = await execute(call)
                executedToolCount += 1
                let resultData = try JSONSerialization.data(withJSONObject: result.jsonObject, options: [.sortedKeys])
                let resultText = String(data: resultData, encoding: .utf8) ?? "{\"success\":false}"
                currentTurn.append([
                    "type": "function_result",
                    "name": call.name,
                    "call_id": call.id,
                    "result": [["type": "text", "text": resultText]]
                ])
            }
        }

        throw GeminiError.toolLoopLimit
    }

    func testConnection() async throws -> String {
        let probe = GeminiToolDefinition(
            name: "connection_probe",
            description: "A test-only function. Do not call it.",
            parameters: ["type": "object", "properties": [:]]
        )
        let response = try await createInteraction(
            input: [[
                "type": "user_input",
                "content": [["type": "text", "text": "Reply with only: Jarvis connected"]]
            ]],
            tools: [probe]
        )
        if !response.outputText.isEmpty { return response.outputText }
        if !response.functionCalls.isEmpty { return "Jarvis connected" }
        throw GeminiError.noResponse
    }

    func listModels() async throws -> [String] {
        let key = try validatedAPIKey()
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1/models")!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "100")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await perform(request)
        try validateHTTP(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            throw GeminiError.invalidResponse
        }
        return models.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }.sorted()
    }

    func clearConversation() {
        historyQueue.sync {
            conversationGeneration += 1
            turns.removeAll(keepingCapacity: false)
        }
    }

    func appendLocalTurn(user: String, assistant: String) {
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssistant = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty, !trimmedAssistant.isEmpty else { return }
        let turn: [[String: Any]] = [
            ["type": "user_input", "content": [["type": "text", "text": trimmedUser]]],
            ["type": "model_output", "content": [["type": "text", "text": trimmedAssistant]]]
        ]
        historyQueue.sync { appendBounded(turn: turn) }
    }

    private struct InteractionResult {
        let steps: [[String: Any]]
        let functionCalls: [GeminiFunctionCall]
        let outputText: String
    }

    private func createInteraction(input: [[String: Any]], tools: [GeminiToolDefinition]) async throws -> InteractionResult {
        let key = try validatedAPIKey()
        let model = modelProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw GeminiError.invalidModel }

        let supportsCombinedTools = model.lowercased().hasPrefix("gemini-3")
        var toolObjects: [[String: Any]] = tools.map { $0.jsonObject }
        if supportsCombinedTools {
            toolObjects.append(["type": "google_search"])
        }

        let location = locationProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        let systemInstruction: String
        if location.isEmpty {
            systemInstruction = Self.defaultSystemInstruction
        } else {
            systemInstruction = Self.defaultSystemInstruction + "\n\nThe user's home location is \(location). Use it for weather and other local requests unless the user specifies another place."
        }

        let body: [String: Any] = [
            "model": model,
            "store": false,
            "input": input,
            "system_instruction": systemInstruction,
            "tools": toolObjects,
            "generation_config": [
                "tool_choice": supportsCombinedTools && !tools.isEmpty ? "validated" : "auto",
                "max_output_tokens": 1_024
            ]
        ]
        guard JSONSerialization.isValidJSONObject(body) else { throw GeminiError.invalidRequest }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await perform(request)
        try validateHTTP(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.invalidResponse
        }
        let status = (object["status"] as? String)?.lowercased() ?? ""
        if ["failed", "cancelled", "incomplete"].contains(status) {
            throw GeminiError.interaction(status: status, message: interactionErrorMessage(from: object))
        }
        if !status.isEmpty && !["completed", "requires_action"].contains(status) {
            throw GeminiError.interaction(status: status, message: interactionErrorMessage(from: object))
        }
        guard let steps = object["steps"] as? [[String: Any]] else {
            throw GeminiError.invalidResponse
        }

        var calls: [GeminiFunctionCall] = []
        var outputFragments: [String] = []
        for step in steps {
            switch step["type"] as? String {
            case "function_call":
                guard let id = step["id"] as? String,
                      let name = step["name"] as? String else { continue }
                calls.append(GeminiFunctionCall(
                    id: id,
                    name: name,
                    arguments: step["arguments"] as? [String: Any] ?? [:]
                ))
            case "model_output":
                let content = step["content"] as? [[String: Any]] ?? []
                outputFragments.append(contentsOf: content.compactMap { item in
                    guard item["type"] as? String == "text" else { return nil }
                    return item["text"] as? String
                })
            default:
                break
            }
        }

        return InteractionResult(
            steps: steps,
            functionCalls: calls,
            outputText: outputFragments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func validatedAPIKey() throws -> String {
        let key = try apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GeminiError.missingAPIKey }
        return key
    }

    private func commit(turn: [[String: Any]], generation: Int) {
        historyQueue.sync {
            guard conversationGeneration == generation else { return }
            appendBounded(turn: turn)
        }
    }

    private func appendBounded(turn: [[String: Any]]) {
        turns.append(turn)
        let maximumTurns = min(20, max(2, maximumTurnsProvider()))
        if turns.count > maximumTurns {
            turns.removeFirst(turns.count - maximumTurns)
        }
        while turns.count > 1 && serializedHistorySize() > maximumHistoryBytes {
            turns.removeFirst()
        }
        if turns.count == 1 && serializedHistorySize() > maximumHistoryBytes {
            turns.removeAll(keepingCapacity: false)
        }
    }

    private func serializedHistorySize() -> Int {
        guard JSONSerialization.isValidJSONObject(turns) else { return maximumHistoryBytes + 1 }
        return (try? JSONSerialization.data(withJSONObject: turns, options: []).count) ?? maximumHistoryBytes + 1
    }

    private func interactionErrorMessage(from object: [String: Any]) -> String {
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let errors = object["errors"] as? [[String: Any]] {
            return errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
        }
        return ""
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data = data, let response = response else {
                    continuation.resume(throwing: GeminiError.invalidResponse)
                    return
                }
                continuation.resume(returning: (data, response))
            }.resume()
        }
    }

    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw GeminiError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errorObject = object?["error"] as? [String: Any]
            let message = errorObject?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GeminiError.api(statusCode: http.statusCode, message: message)
        }
    }
}
