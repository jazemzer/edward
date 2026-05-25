import Foundation
import EdwardCore

struct CopilotState {
    var keyPoints: [String] = []
    var suggestedQuestions: [String] = []
    var actionItems: [String] = []
    var lastUpdated: Date?
    var isProcessing: Bool = false
    var error: String?
    var segmentCount: Int = 0
    var listeningDuration: TimeInterval = 0
}

@MainActor
final class CopilotEngine: ObservableObject {
    @Published var state = CopilotState()

    private var transcriptBuffer: [(timestamp: Date, text: String)] = []
    private var timer: Timer?
    private var lastProcessedCount = 0
    private var startTime: Date?

    private let model: String
    private let baseURL: String
    private let updateInterval: TimeInterval = 60

    init(model: String, baseURL: String) {
        self.model = model
        self.baseURL = baseURL
    }

    func start() {
        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.updateIfNeeded()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        Task { await updateIfNeeded(force: true) }
    }

    func addTranscript(text: String, timestamp: Date) {
        transcriptBuffer.append((timestamp: timestamp, text: text))
        state.segmentCount = transcriptBuffer.count
        if let start = startTime {
            state.listeningDuration = Date().timeIntervalSince(start)
        }
    }

    func reset() {
        transcriptBuffer.removeAll()
        lastProcessedCount = 0
        state = CopilotState()
        startTime = nil
    }

    private func updateIfNeeded(force: Bool = false) async {
        guard !state.isProcessing else { return }
        guard force || transcriptBuffer.count > lastProcessedCount else { return }
        guard !transcriptBuffer.isEmpty else { return }

        state.isProcessing = true
        state.error = nil

        let client = OllamaClient(model: model, baseURL: baseURL)

        let available = await client.isAvailable()
        guard available else {
            state.isProcessing = false
            state.error = "Ollama not reachable at \(baseURL)"
            return
        }

        let transcript = transcriptBuffer.map { $0.text }.joined(separator: "\n")

        let systemPrompt = """
            You are a real-time meeting copilot. Given the conversation transcript so far, \
            provide a concise update. Be brief — each bullet should be one short sentence. \
            Use this exact format:

            KEY POINTS:
            - ...

            SUGGESTED QUESTIONS:
            - ...

            ACTION ITEMS:
            - ...

            If a section has no items, write "- None yet" for that section.
            """

        let prompt = "Here is the conversation so far:\n\n\(transcript)"

        do {
            let response = try await client.generate(prompt: prompt, system: systemPrompt)
            let parsed = parseResponse(response)
            state.keyPoints = parsed.keyPoints
            state.suggestedQuestions = parsed.suggestedQuestions
            state.actionItems = parsed.actionItems
            state.lastUpdated = Date()
            lastProcessedCount = transcriptBuffer.count
        } catch {
            state.error = "Update failed: \(error.localizedDescription)"
        }

        state.isProcessing = false
    }

    func forceUpdate() async {
        await updateIfNeeded(force: true)
    }

    private func parseResponse(_ text: String) -> (keyPoints: [String], suggestedQuestions: [String], actionItems: [String]) {
        var keyPoints: [String] = []
        var suggestedQuestions: [String] = []
        var actionItems: [String] = []

        enum Section { case none, keyPoints, questions, actions }
        var current: Section = .none

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.uppercased().hasPrefix("KEY POINTS") {
                current = .keyPoints
                continue
            } else if trimmed.uppercased().hasPrefix("SUGGESTED QUESTIONS") {
                current = .questions
                continue
            } else if trimmed.uppercased().hasPrefix("ACTION ITEMS") {
                current = .actions
                continue
            }

            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { continue }
            let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if item.isEmpty || item.lowercased() == "none yet" || item.lowercased() == "none" { continue }

            switch current {
            case .keyPoints: keyPoints.append(item)
            case .questions: suggestedQuestions.append(item)
            case .actions: actionItems.append(item)
            case .none: break
            }
        }

        return (keyPoints, suggestedQuestions, actionItems)
    }
}
