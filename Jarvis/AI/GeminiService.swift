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
    private let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    private let historyQueue = DispatchQueue(label: "com.nandan.jarvis.gemini-history")
    private var turns: [[[String: Any]]] = []

    init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping () throws -> String,
        modelProvider: @escaping () -> String,
        maximumTurnsProvider: @escaping () -> Int
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
        self.modelProvider = modelProvider
        self.maximumTurnsProvider = maximumTurnsProvider
    }

    func respond(
        to prompt: String,
        tools: [GeminiToolDefinition],
        onToolsRequested: @escaping ([GeminiFunctionCall]) -> Void,
        execute: @escaping ToolExecutor
    ) async throws -> GeminiResponse {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GeminiError.invalidRequest }

        let priorSteps = historyQueue.sync { turns.flatMap { $0 } }
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
                commit(turn: currentTurn)
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
        let response = try await createInteraction(
            input: [["type": "user_input", "content": "Reply with only: Jarvis connected"]],
            tools: []
        )
        guard !response.outputText.isEmpty else { throw GeminiError.noResponse }
        return response.outputText
    }

    func listModels() async throws -> [String] {
        let key = try validatedAPIKey()
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
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
        historyQueue.sync { turns.removeAll(keepingCapacity: false) }
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

        var toolObjects: [[String: Any]] = tools.map { $0.jsonObject }
        toolObjects.append(["type": "google_search"])

        let body: [String: Any] = [
            "model": model,
            "store": false,
            "input": input,
            "system_instruction": Self.defaultSystemInstruction,
            "tools": toolObjects,
            "generation_config": [
                "temperature": 0.35,
                "tool_choice": "auto",
                "max_output_tokens": 1_024
            ]
        ]
        guard JSONSerialization.isValidJSONObject(body) else { throw GeminiError.invalidRequest }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await perform(request)
        try validateHTTP(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = object["steps"] as? [[String: Any]] else {
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

    private func commit(turn: [[String: Any]]) {
        historyQueue.sync {
            turns.append(turn)
            let maximumTurns = max(2, maximumTurnsProvider())
            if turns.count > maximumTurns {
                turns.removeFirst(turns.count - maximumTurns)
            }
        }
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
