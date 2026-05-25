# Edward — Always-On Transcription App

## Architecture

A single macOS app that runs silently in the background, capturing and transcribing audio in real-time.

```
Edward.app (LSUIElement — no dock icon)
├── EdwardCore (library)
│   ├── AudioCapture        — mic input via AVAudioEngine
│   ├── SystemAudioSource   — per-app audio via ScreenCaptureKit
│   ├── AudioPipeline       — VAD → buffer → transcribe flow
│   ├── VADProcessor        — Silero VAD for speech detection
│   ├── Transcriber         — Qwen3 ASR (MLX, on-device)
│   ├── SpeakerTracker      — speaker embedding + identification
│   ├── ForcedAligner       — word-level timestamps
│   ├── Storage             — SQLite (transcripts, audio, speakers)
│   └── Config              — ~/.edward/config.json
└── Edward (SwiftUI app)
    ├── EdwardApp           — @main, WindowGroup + Settings
    ├── ViewModel           — controls daemon lifecycle
    └── Views               — transcript list, controls, settings
```

## How it works

1. App launches (at login via SMAppService, or manually)
2. User presses Start — loads models, begins listening
3. Audio pipelines detect speech via VAD, buffer it, transcribe
4. Transcripts appear in the window, stored in SQLite
5. App stays running in background (LSUIElement = no dock icon)
6. Reopen via Spotlight or the Applications folder

## Key design choices

| Decision | Choice | Why |
|----------|--------|-----|
| App type | Regular macOS app, LSUIElement | Simplest. No menubar, no daemon, no CLI. Just an app. |
| Audio capture | ScreenCaptureKit | Per-app capture without routing changes |
| ASR | Qwen3 via MLX | Fast, local, multi-language, runs on Apple Silicon |
| Storage | SQLite at ~/.edward/edward.db | Simple, queryable, no server |
| Launch at login | SMAppService | Native macOS API, no launchd plists |
| Inter-process | None | Everything runs in one process |

## Data

All data lives in `~/.edward/`:
- `edward.db` — SQLite database (transcripts, word timestamps, speakers)
- `audio/` — saved audio segments (for offline diarization)
- `transcripts/` — text export
- `logs/` — app logs
- `config.json` — user configuration
- `speakers.json` — learned speaker profiles

## Build & Run

```bash
make bundle   # builds and packages Edward.app
make run      # builds and opens the app
```

## Future

- Intelligence layer (summarization, action items, voice commands)
- Semantic search over transcripts
- Meeting detection and auto-labeling
