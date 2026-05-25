import Foundation

/// Minimal HTTP client for local Ollama LLM inference.
public struct OllamaClient {
    public let model: String
    public let baseURL: String

    public init(model: String = "llama3.2", baseURL: String = "http://localhost:11434") {
        self.model = model
        self.baseURL = baseURL
    }

    public func generate(prompt: String, system: String? = nil) async throws -> String {
        let url = URL(string: "\(baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]
        if let system = system {
            body["system"] = system
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw OllamaError.parseError
        }

        return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

public enum OllamaError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case parseError

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Ollama"
        case .httpError(let code, let body):
            return "Ollama HTTP \(code): \(body)"
        case .parseError:
            return "Failed to parse Ollama response"
        }
    }
}
