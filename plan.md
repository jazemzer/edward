# Edward — Always-On AI Agent

## Architecture Overview

There are **3 major subsystems** to build:

### 1. Microphone Capture (24/7 ambient listening)

- **Core Audio / AVFoundation** allows multiple processes to share the mic simultaneously — no conflict with Zoom
- Use **Voice Activity Detection (VAD)** to avoid transcribing silence (saves compute). `silero-vad` is lightweight and excellent
- Pipeline: `Mic → VAD → Buffer → Transcription → Command Parser`

### 2. System Audio Capture (per-app)

This is the hardest part on macOS. Three realistic options:

| Approach | Pros | Cons |
|---|---|---|
| **ScreenCaptureKit** (macOS 13+) | Apple-native, can target specific apps by PID, no kernel extensions | Requires screen recording permission, Swift/ObjC API |
| **BlackHole** virtual audio device | Simple, well-known | Captures ALL system audio, not per-app; requires audio routing config |
| **Custom Audio Tap** (macOS 14.4+ `AudioProcessTap`) | Per-process tap, no routing changes | Very new API, limited docs |

**Recommendation:** **ScreenCaptureKit** is the best balance. It can capture audio from specific apps (Zoom, Meet, Teams) by process ID without touching their audio routing. A small Swift helper streams audio buffers to the Python pipeline via a Unix socket or shared memory.

### 3. Transcription + Diarization + Intelligence

Fully local on M4 Max:

- **MLX Whisper** or **whisper.cpp** (Metal-accelerated) — real-time transcription on Apple Silicon
- **pyannote-audio** — speaker diarization (who is speaking). Can run on MPS (Metal Performance Shaders)
- **Streaming approach**: chunk audio into ~5-10s segments with overlap, transcribe in near-real-time

---

## Tech Stack

```
┌─────────────────────────────────────────────────┐
│                  Agent Daemon                    │
│              (Python + Swift helper)             │
├──────────────────┬──────────────────────────────-┤
│  Mic Pipeline    │  System Audio Pipeline        │
│                  │                               │
│  sounddevice     │  Swift ScreenCaptureKit helper│
│  → silero-vad    │  → streams PCM via Unix socket│
│  → audio buffer  │  → audio buffer               │
│  → whisper (MLX) │  → whisper (MLX)              │
│  → command parse │  → pyannote diarization       │
│                  │  → transcript + speaker labels │
├──────────────────┴──────────────────────────────-┤
│              Storage / Intelligence              │
│                                                  │
│  SQLite (transcripts, timestamps, speakers)      │
│  Local LLM or Claude API for summarization       │
│  Action dispatcher (for voice commands)          │
└──────────────────────────────────────────────────┘
```

## Implementation Phases

### Phase 1 — Mic capture + transcription
- Python daemon using `sounddevice` for mic input
- Silero VAD for speech detection
- MLX Whisper for local transcription
- Write transcripts to SQLite with timestamps
- Run as a `launchd` service for 24/7 operation

### Phase 2 — System audio capture
- Swift CLI tool using ScreenCaptureKit to capture audio from target apps
- Expose audio stream over Unix domain socket
- Python consumer reads the stream and feeds to Whisper

### Phase 3 — Diarization
- Integrate pyannote-audio for speaker identification
- Label transcript segments with speaker IDs
- Optional: build speaker embeddings over time to learn names

### Phase 4 — Intelligence layer
- Summarize meetings in real-time
- Extract action items, decisions, key topics
- Voice command recognition from mic pipeline (wake word → command)
- Claude API or local LLM (e.g., MLX LLaMA) for reasoning

## Open Decisions

1. **Language split**: Python for ML/pipelines, Swift for macOS audio APIs — or go all-Swift with Swift bindings to whisper.cpp?
2. **Wake word**: Always-listening command recognition, or push-to-talk for commands?
3. **Storage**: SQLite is simple. Want a vector DB (like ChromaDB) for semantic search over transcripts?
4. **Privacy**: Everything local, or okay with sending audio/text to cloud APIs for intelligence?
