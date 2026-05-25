import Foundation
import EdwardCore

enum TranscriptEngine: String {
    case qwen = "Qwen"
    case apple = "Apple"
}

struct CopilotTranscript: Identifiable {
    let id = UUID()
    let timestamp: Date
    let text: String
    var engine: TranscriptEngine = .qwen
}

struct CopilotItem: Identifiable {
    let id = UUID()
    let text: String
    let isStrikethrough: Bool
}

struct CopilotState {
    var keyPoints: [CopilotItem] = []
    var suggestedQuestions: [CopilotItem] = []
    var actionItems: [CopilotItem] = []
    var lastUpdated: Date?
    var isProcessing: Bool = false
    var error: String?
    var segmentCount: Int = 0
    var listeningDuration: TimeInterval = 0
    var statusMessage: String?
    var transcripts: [CopilotTranscript] = []
    var partialTranscription: String?
    var appleTranscripts: [CopilotTranscript] = []
    var applePartialTranscription: String?
}

@MainActor
final class CopilotEngine: ObservableObject {
    @Published var state = CopilotState()

    static let defaultSystemPrompt = """
        You are a real-time meeting copilot. You receive:
        1. Your previous output (if any) — refine and update it, don't start from scratch
        2. The full conversation transcript so far

        Provide a concise update. Be brief — each bullet should be one short sentence.
        You MUST use this exact format:

        KEY POINTS:
        - ...

        SUGGESTED QUESTIONS:
        - ...

        ACTION ITEMS:
        - ...

        Rules:
        - Keep existing valid points, add new ones
        - If a previous point is no longer valid or was corrected, keep it but wrap in ~~strikethrough~~ like: - ~~old point that is no longer true~~
        - If a section has no items, write "- None yet"
        - Do not add commentary outside the format above
        """

    static let defaultUserPromptPrefix = "Analyze this conversation and provide an updated summary:"

    var systemPrompt: String = CopilotEngine.defaultSystemPrompt
    var userPromptPrefix: String = CopilotEngine.defaultUserPromptPrefix
    var isEnabled: Bool = true

    private var transcriptBuffer: [(timestamp: Date, text: String)] = []
    private var timer: Timer?
    private var lastProcessedCount = 0
    private var startTime: Date?
    private var hasTriggeredFirstUpdate = false

    private let model: String
    private let baseURL: String
    private let updateInterval: TimeInterval = 60
    private let firstUpdateDelay: TimeInterval = 10

    init(model: String, baseURL: String) {
        self.model = model
        self.baseURL = baseURL
    }

    func start() {
        startTime = Date()
        hasTriggeredFirstUpdate = false
        state.statusMessage = "Waiting for speech..."
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
        state.transcripts.append(CopilotTranscript(timestamp: timestamp, text: text))
        state.partialTranscription = nil
        // Advance committed offset — the finalized text replaces everything Whisper had buffered
        committedLength = 0
        if let start = startTime {
            state.listeningDuration = Date().timeIntervalSince(start)
        }
        state.statusMessage = "\(transcriptBuffer.count) segment\(transcriptBuffer.count == 1 ? "" : "s") captured"

        if !hasTriggeredFirstUpdate && transcriptBuffer.count >= 2 {
            hasTriggeredFirstUpdate = true
            Task {
                try? await Task.sleep(nanoseconds: UInt64(firstUpdateDelay * 1_000_000_000))
                await self.updateIfNeeded(force: true)
            }
        }
    }

    /// Tracks character offset into Whisper's rolling buffer that has been committed as frozen entries.
    /// Each partial re-transcribes the full buffer — we only display text past this offset.
    private var committedLength: Int = 0

    /// Full latest Whisper partial — kept for LLM consumption even though UI only shows the delta
    private var fullPartialForLLM: String = ""

    func updatePartialTranscription(_ text: String?) {
        guard let text = text, !text.isEmpty else {
            // Speech ended — reset for next speech segment
            state.partialTranscription = nil
            fullPartialForLLM = ""
            committedLength = 0
            return
        }

        // Store full partial for LLM use
        fullPartialForLLM = text

        // Only show text beyond what we've already committed (for UI)
        if text.count > committedLength {
            let delta = String(text.dropFirst(committedLength)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !delta.isEmpty {
                state.partialTranscription = delta
            }
        }
    }

    func addAppleTranscript(text: String, timestamp: Date) {
        state.appleTranscripts.append(CopilotTranscript(timestamp: timestamp, text: text, engine: .apple))
        state.applePartialTranscription = nil
    }

    func updateApplePartialTranscription(_ text: String?) {
        state.applePartialTranscription = text
    }

    func reset() {
        transcriptBuffer.removeAll()
        lastProcessedCount = 0
        hasTriggeredFirstUpdate = false
        state = CopilotState()
        startTime = nil
    }

    private func updateIfNeeded(force: Bool = false) async {
        guard isEnabled else { return }
        guard !state.isProcessing else { return }
        let hasNewSegments = transcriptBuffer.count > lastProcessedCount
        let hasPartialContent = !fullPartialForLLM.isEmpty
        guard force || hasNewSegments || hasPartialContent else { return }
        guard !transcriptBuffer.isEmpty || hasPartialContent else { return }

        state.isProcessing = true
        state.error = nil
        state.statusMessage = "Analyzing conversation..."

        let client = OllamaClient(model: model, baseURL: baseURL)

        let available = await client.isAvailable()
        guard available else {
            state.isProcessing = false
            state.error = "Ollama not reachable at \(baseURL). Make sure Ollama is running."
            state.statusMessage = nil
            return
        }

        var transcript = transcriptBuffer.map { $0.text }.joined(separator: "\n")
        if !fullPartialForLLM.isEmpty {
            transcript += "\n[still speaking]: \(fullPartialForLLM)"
        }

        // Build structured prompt: prefix + previous output + transcript
        var promptParts: [String] = []
        promptParts.append(userPromptPrefix)

        // Include previous output so LLM can refine rather than start from scratch
        if !state.keyPoints.isEmpty || !state.suggestedQuestions.isEmpty || !state.actionItems.isEmpty {
            var previousOutput = "\n\nYOUR PREVIOUS OUTPUT:"
            if !state.keyPoints.isEmpty {
                previousOutput += "\nKEY POINTS:\n" + state.keyPoints.map { $0.isStrikethrough ? "- ~~\($0.text)~~" : "- \($0.text)" }.joined(separator: "\n")
            }
            if !state.suggestedQuestions.isEmpty {
                previousOutput += "\nSUGGESTED QUESTIONS:\n" + state.suggestedQuestions.map { $0.isStrikethrough ? "- ~~\($0.text)~~" : "- \($0.text)" }.joined(separator: "\n")
            }
            if !state.actionItems.isEmpty {
                previousOutput += "\nACTION ITEMS:\n" + state.actionItems.map { $0.isStrikethrough ? "- ~~\($0.text)~~" : "- \($0.text)" }.joined(separator: "\n")
            }
            promptParts.append(previousOutput)
        }

        promptParts.append("\n\nTRANSCRIPT:\n\(transcript)")

        let prompt = promptParts.joined()

        log.info("[Copilot] Sending to LLM (\(transcript.count) chars, system prompt: \(systemPrompt.prefix(60))...)")
        log.debug("[Copilot] Full prompt:\n\(prompt)")

        do {
            let response = try await client.generate(prompt: prompt, system: systemPrompt)
            log.info("[Copilot] LLM response (\(response.count) chars):\n\(response)")
            let parsed = parseResponse(response)
            state.keyPoints = parsed.keyPoints
            state.suggestedQuestions = parsed.suggestedQuestions
            state.actionItems = parsed.actionItems
            state.lastUpdated = Date()
            state.statusMessage = nil
            lastProcessedCount = transcriptBuffer.count
        } catch {
            state.error = "Update failed: \(error.localizedDescription)"
            state.statusMessage = nil
        }

        state.isProcessing = false
    }

    func forceUpdate() async {
        await updateIfNeeded(force: true)
    }

    private func parseResponse(_ text: String) -> (keyPoints: [CopilotItem], suggestedQuestions: [CopilotItem], actionItems: [CopilotItem]) {
        var keyPoints: [CopilotItem] = []
        var suggestedQuestions: [CopilotItem] = []
        var actionItems: [CopilotItem] = []

        enum Section { case none, keyPoints, questions, actions }
        var current: Section = .none

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.uppercased().hasPrefix("KEY POINTS") || trimmed.uppercased().hasPrefix("**KEY POINTS") {
                current = .keyPoints
                continue
            } else if trimmed.uppercased().hasPrefix("SUGGESTED QUESTIONS") || trimmed.uppercased().hasPrefix("**SUGGESTED") {
                current = .questions
                continue
            } else if trimmed.uppercased().hasPrefix("ACTION ITEMS") || trimmed.uppercased().hasPrefix("**ACTION") {
                current = .actions
                continue
            }

            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") else { continue }
            let bullet = trimmed.first == "-" || trimmed.first == "*" || trimmed.first == "•"
            guard bullet else { continue }
            let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if item.isEmpty || item.lowercased() == "none yet" || item.lowercased() == "none" || item.lowercased() == "n/a" { continue }

            // Detect ~~strikethrough~~ markers
            let isStrikethrough = item.hasPrefix("~~") && item.hasSuffix("~~")
            let cleanText = isStrikethrough ? String(item.dropFirst(2).dropLast(2)) : item

            let copilotItem = CopilotItem(text: cleanText, isStrikethrough: isStrikethrough)
            switch current {
            case .keyPoints: keyPoints.append(copilotItem)
            case .questions: suggestedQuestions.append(copilotItem)
            case .actions: actionItems.append(copilotItem)
            case .none: break
            }
        }

        return (keyPoints, suggestedQuestions, actionItems)
    }
}
