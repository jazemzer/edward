# Edward Intelligence Layer — Design Plan

## Context

Edward is a macOS always-on audio daemon with mic capture, VAD (SileroVAD), transcription (Qwen3-ASR), speaker ID (WeSpeaker), diarization, and SQLite storage all working. It streams transcriptions via Unix socket (`~/.edward/edward.sock`) and callbacks.

**Goal:** Add an always-on AI intelligence layer that produces real-time summaries, action items, and meeting copilot suggestions — served through a local web UI. Uses **Ollama** (local LLM) for privacy and zero-cost inference.

**Scope:** Intelligence layer only. System audio capture (ScreenCaptureKit) deferred to later.

**Decisions:**
- Local LLM via Ollama — configurable model, default **Qwen 2.5 7B** (best quality; 64 GB machine has plenty of headroom)
- Built in Swift, embedded in Edward daemon
- Web UI from the start (FlyingFox HTTP + WebSocket at `localhost:8420`)
- Always on — runs whenever Edward is listening

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Edward Daemon (enhanced)                    │
│                                                               │
│  Mic → VAD → Transcribe → Store  (existing, untouched)       │
│                    │                                          │
│                    │ onTranscription callback                 │
│                    ▼                                          │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │         Intelligence Engine (NEW)                        │  │
│  │                                                          │  │
│  │  MeetingSession (state accumulator)                      │  │
│  │  ├── Summarizer      (every ~60s of new speech)          │  │
│  │  ├── ActionExtractor  (every segment)                    │  │
│  │  └── MeetingCopilot   (every ~2-3min)                    │  │
│  │                                                          │  │
│  │  OllamaClient → POST http://localhost:11434/api/chat     │  │
│  └──────────────────────┬──────────────────────────────────┘  │
│                         │                                     │
│                         ▼                                     │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │         WebServer (FlyingFox) — NEW                      │  │
│  │  HTTP  localhost:8420     → dashboard.html                │  │
│  │  WS    localhost:8420/ws  → live transcript/summary/items │  │
│  └─────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

---

## LLM: Ollama (Configurable)

**Default:** Qwen 2.5 7B (`qwen2.5:7b`) — best structured output compliance, excellent summarization.
- ~4.4 GB on disk, ~5-6 GB RAM. Comfortable on 64 GB machine alongside all ML models.
- 25-40 tok/s on Apple Silicon — summary in 3-5 seconds.

**Configurable alternatives (via `config.json`):**

| Model | Params | RAM | Speed | When to use |
|-------|--------|-----|-------|-------------|
| `qwen2.5:7b` | 7B | ~6 GB | 25-40 tok/s | Default — best quality |
| `phi4-mini` | 3.8B | ~3-4 GB | 40-60 tok/s | Faster responses, lower RAM |
| `qwen2.5:14b` | 14B | ~10 GB | 15-25 tok/s | Maximum quality (64 GB machine can handle it) |
| `gemma2:2b` | 2.6B | ~2-3 GB | 60-80 tok/s | Fastest, lightest |
| Any Ollama model | — | — | — | Just change the config string |

**API:** `POST http://localhost:11434/api/chat` with `format: "json"` for structured output.

**Prerequisite:** Ollama installed and running with chosen model pulled.

---

## Component Design

### 1. `OllamaClient.swift` — LLM API wrapper

```swift
struct OllamaClient {
    let baseURL: String  // default "http://localhost:11434"
    let model: String    // default "qwen2.5:7b"
    
    func chat(system: String, user: String, jsonFormat: Bool) async throws -> String
    func chatStream(system: String, user: String) -> AsyncStream<String>
    func isAvailable() async -> Bool
}
```

- URLSession-based, async/await
- `format: "json"` for structured output (summaries, action items)
- Options: `temperature: 0.2`, `num_predict: 512`, `num_ctx: 4096`
- Graceful degradation: if Ollama unavailable, intelligence layer silently disabled

### 2. `MeetingSession.swift` — State management

```swift
class MeetingSession {
    let startedAt: Date
    var segments: [TranscriptEntry]
    var runningSummary: String
    var actionItems: [ActionItem]
    var suggestions: [Suggestion]
    var participants: Set<String>
    var isActive: Bool
    
    var lastSummaryAt: Date?
    var lastSuggestionAt: Date?
    
    func recentTranscript(minutes: Int = 5) -> String
    func fullTranscript() -> String
}

struct ActionItem: Codable {
    let description: String
    let owner: String?
    let deadline: String?
    let extractedAt: Date
}

struct Suggestion: Codable {
    let text: String
    let category: String  // "question", "risk", "idea"
    let generatedAt: Date
}
```

**Session lifecycle:**
- **Start:** First transcription after >5 min silence (or first ever)
- **End:** >5 min silence during active session → generate meeting summary
- **Reset:** New session starts fresh

### 3. `Summarizer.swift` — Running summary

- **Trigger:** Every ~60 seconds of new speech
- **Input:** Previous summary + new segments since last update
- **Output:** JSON `{"summary": [...], "decisions": [...]}`
- **System prompt:** Summarize incrementally, 3-5 bullets, highlight decisions

### 4. `ActionExtractor.swift` — Action item extraction

- **Trigger:** Every new segment (skip if <10 words)
- **Input:** New segment + existing items (for dedup)
- **Output:** JSON `{"new_items": [{description, owner, deadline}]}`
- **System prompt:** Extract commitments/assignments, return empty if none

### 5. `MeetingCopilot.swift` — Proactive suggestions

- **Trigger:** Every ~2-3 minutes during active discussion
- **Input:** Recent 5min transcript + running summary
- **Output:** JSON `{"suggestions": [{text, category}]}`
- **System prompt:** Suggest unasked questions, overlooked risks, relevant connections

### 6. `IntelligenceEngine.swift` — Orchestrator

```swift
class IntelligenceEngine {
    let ollama: OllamaClient
    let summarizer: Summarizer
    let actionExtractor: ActionExtractor
    let copilot: MeetingCopilot
    var session: MeetingSession?
    
    var onSummaryUpdate: (([String], [String]) -> Void)?
    var onActionItem: (([ActionItem]) -> Void)?
    var onSuggestion: (([Suggestion]) -> Void)?
    var onSessionEnd: ((MeetingSummaryDoc) -> Void)?
    
    func processTranscription(_ entry: TranscriptEntry) async
}
```

- Dispatches to agents concurrently (`async let`)
- On session end, generates Markdown summary to `~/.edward/meetings/`

### 7. `WebServer.swift` — Local dashboard server

Dependency: `https://github.com/swhitty/FlyingFox.git`

- HTTP `GET /` → serves `dashboard.html`
- WebSocket `/ws` → pushes JSON updates:
  ```json
  {"type": "transcript", "text": "...", "speaker": "...", "timestamp": ...}
  {"type": "summary", "bullets": [...], "decisions": [...]}
  {"type": "action_item", "description": "...", "owner": "...", "deadline": "..."}
  {"type": "suggestion", "text": "...", "category": "question"}
  ```

### 8. `dashboard.html` — Browser UI (single file)

```
┌─────────────────────────────────────────────────────┐
│  Edward Meeting Intelligence         [Session: 45m]  │
├────────────────┬──────────────────┬─────────────────┤
│  Transcript    │  Summary         │  Copilot        │
│                │                  │                  │
│  [Speaker 1]   │  * Key point 1   │  ? Consider:    │
│  "We should    │  * Key point 2   │    What about    │
│  prioritize    │  * Decision: X   │    the impact    │
│  the API..."   │                  │    on latency?   │
│                │  Action Items    │                  │
│  [Speaker 2]   │  ─────────────   │  ! Risk:        │
│  "Agreed, but  │  [ ] Task @Bob   │    No rollback   │
│  we need..."   │  [ ] Task @Ali   │    plan yet      │
└────────────────┴──────────────────┴─────────────────┘
```

- WebSocket auto-reconnect, auto-scroll, speaker color coding
- Dark theme, vanilla HTML + CSS + JS (no build step)

---

## Integration into EdwardDaemon

Minimal changes to `EdwardDaemon.swift`:

```swift
var intelligenceEngine: IntelligenceEngine?
var webServer: WebServer?

func initialize() async {
    // ... existing init ...
    
    if config.enableIntelligence {
        let ollama = OllamaClient(model: config.ollamaModel, baseURL: config.ollamaBaseURL)
        if await ollama.isAvailable() {
            intelligenceEngine = IntelligenceEngine(ollama: ollama, config: config)
            webServer = WebServer(port: config.webServerPort)
            // Wire callbacks → WebSocket broadcast
            try await webServer?.start()
        }
    }
}

// In onTranscription callback:
await intelligenceEngine?.processTranscription(entry)
```

---

## Config Additions

```swift
var enableIntelligence: Bool = true
var ollamaModel: String = "qwen2.5:7b"
var ollamaBaseURL: String = "http://localhost:11434"
var webServerPort: Int = 8420
var summaryIntervalSeconds: Double = 60
var copilotIntervalSeconds: Double = 180
var sessionTimeoutSeconds: Double = 300  // 5 min silence = session end
```

---

## Implementation Phases

### Phase 1: Ollama Client + Summarizer (MVP)
**New files:** `OllamaClient.swift`, `MeetingSession.swift`, `Summarizer.swift`, `IntelligenceEngine.swift`
1. Build Ollama client with chat + health check
2. Build session state manager
3. Build summarizer with JSON output
4. Build orchestrator (summarizer only)
5. Wire into daemon transcription callback
6. **Test:** Talk for 2 min → summary appears in log

### Phase 2: Action Items + Web UI
**New files:** `ActionExtractor.swift`, `WebServer.swift`, `dashboard.html`
**Modified:** `Package.swift` (add FlyingFox)
1. Build action item extractor
2. Build web server (HTTP + WebSocket)
3. Build dashboard HTML
4. Wire intelligence → WebSocket
5. **Test:** Open `localhost:8420`, talk → live updates

### Phase 3: Meeting Copilot
**New file:** `MeetingCopilot.swift`
1. Build copilot with suggestion prompts
2. Add suggestions panel to dashboard
3. **Test:** 5 min discussion → suggestions appear

### Phase 4: Session Lifecycle + Post-Meeting Docs
1. Implement silence-based session detection
2. On session end, generate Markdown summary
3. Save to `~/.edward/meetings/YYYY-MM-DD-HH-MM.md`
4. **Test:** Stop talking 5 min → doc generated

---

## Files Summary

**New:**
| File | Purpose |
|------|---------|
| `Sources/EdwardCore/Intelligence/OllamaClient.swift` | Ollama REST API wrapper |
| `Sources/EdwardCore/Intelligence/MeetingSession.swift` | Session state |
| `Sources/EdwardCore/Intelligence/Summarizer.swift` | Running summary |
| `Sources/EdwardCore/Intelligence/ActionExtractor.swift` | Action items |
| `Sources/EdwardCore/Intelligence/MeetingCopilot.swift` | Suggestions |
| `Sources/EdwardCore/Intelligence/IntelligenceEngine.swift` | Orchestrator |
| `Sources/EdwardCore/WebServer.swift` | HTTP + WebSocket |
| `Resources/dashboard.html` | Browser dashboard |

**Modified:**
| File | Changes |
|------|---------|
| `Sources/EdwardCore/Config.swift` | Intelligence/ollama/web config |
| `Sources/EdwardCore/EdwardDaemon.swift` | Wire intelligence + web server |
| `Package.swift` | Add FlyingFox dependency |

---

## Prerequisites

1. Ollama installed: `brew install ollama && ollama serve`
2. Model pulled: `ollama pull qwen2.5:7b`
3. Edward daemon working with mic capture + transcription

## Verification

1. Health check Ollama connection
2. Talk 2 min → JSON summary in logs
3. Say "Bob will handle migration by Friday" → action item extracted
4. Open `localhost:8420` → three panels update live
5. 5 min discussion → copilot suggestions appear
6. 5 min silence → meeting doc at `~/.edward/meetings/`
