import Foundation

struct GeminiFunctionCall {
    let id: String
    let name: String
    let arguments: [String: Any]
}

struct GeminiToolExecutionResult {
    let success: Bool
    let message: String
    let data: [String: Any]

    init(success: Bool, message: String, data: [String: Any] = [:]) {
        self.success = success
        self.message = message
        self.data = data
    }

    var jsonObject: [String: Any] {
        var object = data
        object["success"] = success
        object["message"] = message
        return object
    }
}

struct GeminiToolDefinition {
    let name: String
    let description: String
    let parameters: [String: Any]

    var jsonObject: [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": parameters
        ]
    }
}

struct GeminiResponse {
    let text: String
    let executedToolCount: Int
}

enum GeminiError: LocalizedError {
    case missingAPIKey
    case invalidModel
    case invalidRequest
    case invalidResponse
    case api(statusCode: Int, message: String)
    case interaction(status: String, message: String)
    case toolLoopLimit
    case noResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a Gemini API key in Jarvis Settings."
        case .invalidModel:
            return "Choose a valid Gemini model in Jarvis Settings."
        case .invalidRequest:
            return "Jarvis could not prepare the Gemini request."
        case .invalidResponse:
            return "Gemini returned a response Jarvis could not understand."
        case .api(let statusCode, let message):
            if statusCode == 401 || statusCode == 403 {
                return "Gemini rejected the API key. Check it in Jarvis Settings."
            }
            if statusCode == 429 {
                return "Gemini is rate-limited right now. Try again shortly."
            }
            return "Gemini request failed (HTTP \(statusCode)): \(message)"
        case .interaction(let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Gemini ended the request with status \(status)."
                : "Gemini ended the request with status \(status): \(detail)"
        case .toolLoopLimit:
            return "Jarvis stopped an unexpectedly long chain of actions."
        case .noResponse:
            return "Gemini did not return a spoken response."
        }
    }
}
