# Open-Source Tools Landscape for Edward

> Research compiled March 2026. Some data based on knowledge through mid-2025 — verify GitHub repos for latest status.

---

## Existing Complete Systems (closest to what we want)

### meetcap (v2.0.8, Mar 2026) — MOST RELEVANT
- **What**: Offline meeting recorder & summarizer for macOS
- **URL**: https://pypi.org/project/meetcap/
- **License**: MIT | **Python >=3.10**
- **Features**:
  - Records both system audio + microphone simultaneously
  - 100% offline — no network connections
  - Local transcription: **Parakeet TDT** (default Apple Silicon), MLX Whisper, faster-whisper, or Vosk
  - Local summarization: **Qwen3.5-4B** via MLX
  - Speaker diarization via **sherpa-onnx**
  - CLI workflow: `meetcap record` → stop with hotkey → transcript & summary
- **Audio capture**: Uses **BlackHole** virtual audio device (system-wide, not per-app)
- **STT extras**: `mlx-stt`, `stt` (faster-whisper), `vosk-stt`, `parakeet-stt`
- **Gap vs our needs**: Not 24/7 daemon, not per-app audio, no wake word, no real-time streaming intelligence

### WhisperX
- **URL**: github.com/m-bain/whisperX
- **What**: Whisper + forced alignment (wav2vec2) + pyannote diarization = word-level timestamps with speaker labels
- **License**: BSD-4-Clause
- **Gap**: Offline/batch processing, not real-time

### Ecoute
- **URL**: github.com/SevaSk/ecoute
- **What**: Real-time dual-stream capture (mic + system audio) → Whisper → GPT for suggested responses
- **License**: MIT
- **Gap**: Prototype quality, minimal maintenance, uses cloud GPT

---

## Speech Recognition / Transcription

### Tier 1 — Best for M4 Max

| Tool | Type | Metal/MLX? | Streaming? | Accuracy | License |
|---|---|---|---|---|---|
| **whisper.cpp** | C++ | **Metal + CoreML** | Yes | Excellent (= Whisper) | MIT |
| **MLX Whisper** | Python/MLX | **MLX native** | Limited | Excellent | MIT |
| **Distil-Whisper** | Model | Via runtime | Via runtime | Near-SOTA (~1% of large) | MIT |
| **Parakeet TDT** (NeMo) | Python | CUDA-focused, CPU on Mac | Yes | SOTA (<3% WER) | Apache 2.0 |

### Tier 2 — Strong alternatives

| Tool | Type | Metal? | Streaming? | Notes |
|---|---|---|---|---|
| **faster-whisper** | Python/CTranslate2 | CPU only on Mac | Yes | 4x faster than OG Whisper, Silero VAD built-in |
| **Vosk** | C++/Kaldi | CPU only | Yes (first-class) | Lightweight (50MB-2GB), 20+ languages, speaker ID |
| **Moonshine** | Python/ONNX | CPU/ONNX | Yes | Ultra-small (27-61M params), 5x faster than Whisper-tiny |
| **WhisperKit/Whisper.swift** | Swift | **CoreML + Metal** | Yes | Best for native macOS/iOS apps |
| **sherpa-onnx** | C++/ONNX | CPU + CoreML | Yes | Multi-model runtime (Whisper, Paraformer, Zipformer) |

### Tier 3 — Research / Specialized

| Tool | Notes |
|---|---|
| **SpeechBrain** | Full speech toolkit (ASR+diarization+TTS). Apache 2.0. Research-oriented. |
| **wav2vec2 / HuggingFace** | Good for domain-specific fine-tuning. Many community models. |
| **NeMo** | SOTA but CUDA-dependent. Poor fit for Apple Silicon. |

### Dead / Avoid
- **DeepSpeech** (Mozilla) — archived 2021
- **Coqui STT** — company shut down 2023
- **Original Whisper Python** — barely maintained, slow

---

## Voice Activity Detection (VAD)

| Tool | License | Accuracy | Latency | Size | Apple Silicon | Notes |
|---|---|---|---|---|---|---|
| **Silero VAD** | MIT | Excellent | 30-90ms | ~2MB ONNX | Yes | **Clear winner.** ONNX version preferred. |
| **WebRTC VAD** | MIT | Moderate | ~1ms | Negligible | Yes | Ultra-lightweight, GMM-based. Good pre-filter. |
| **pyannote VAD** | MIT* | Excellent | 200-500ms | Heavy | Yes (MPS) | Overkill for standalone VAD, best with diarization. |
| **Cobra** (Picovoice) | Freemium | Very good | <30ms | Small | Yes | Proprietary engine. |

**Recommendation**: **Silero VAD** (ONNX) for production. WebRTC VAD as ultra-fast pre-filter.

---

## Wake Word / Keyword Detection

| Tool | License | Truly OSS? | Accuracy | Latency | Notes |
|---|---|---|---|---|---|
| **OpenWakeWord** | Apache 2.0 | **Yes** | Good | 100-300ms | Best OSS option. Custom training supported. HA integration. |
| **Porcupine** (Picovoice) | Freemium | No | Excellent | <100ms | Best accuracy but proprietary engine. Free tier usable. |
| **Mycroft Precise** | Apache 2.0 | Yes | Moderate | 200-500ms | **Dead** (Mycroft bankrupt 2023). Use OpenWakeWord. |
| **Snowboy** | Apache 2.0 | Yes | Was good | — | **Dead** (Kitt.AI acquired by Baidu). |
| **SpeechBrain KWS** | Apache 2.0 | Yes | Very good | High | Research. Train models, export to ONNX for prod. |

**Recommendation**: **OpenWakeWord** for fully open-source. Porcupine if freemium is acceptable.

---

## Speaker Diarization

| Tool | Real-time? | DER | Apple Silicon | License | Notes |
|---|---|---|---|---|---|
| **pyannote-audio 3.x** | No (batch) | 11-20% | Yes (MPS) | MIT (gated models) | De facto standard. Overlap-aware. |
| **diart** | **Yes (streaming)** | 15-25% | Yes (MPS) | MIT | Built on pyannote. **Only real-time diarization lib.** |
| **sherpa-onnx** | Yes | Competitive | Yes (ONNX/CoreML) | Apache 2.0 | Used by meetcap. Lightweight. |
| **NeMo MSDD** | No | 5-20% | No (CUDA) | Apache 2.0 | Best accuracy but NVIDIA-only. |
| **SpeechBrain** | No | 20-25% | Yes (MPS) | Apache 2.0 | Strong embeddings (ECAPA-TDNN). |
| **WeSpeaker** | Near-RT (ONNX) | Competitive | Yes (ONNX) | Apache 2.0 | ONNX export, CAM++ architecture. |
| **Resemblyzer** | Embeddings only | — | Yes | Apache 2.0 | GE2E speaker embeddings. Superseded by ECAPA-TDNN. |

**Recommendation**: **diart** (real-time, built on pyannote) for streaming. **sherpa-onnx** for lightweight/embedded. **pyannote** for batch/best accuracy.

---

## macOS System Audio Capture

| Tool | Per-App? | Setup Complexity | License | Notes |
|---|---|---|---|---|
| **BlackHole** | No (system-wide) | Moderate (Audio MIDI Setup) | GPL-3.0 | Most popular. Used by meetcap. Mature. |
| **ScreenCaptureKit** | **Yes** | Low (API-level) | Apple (free) | macOS 13+. Best for per-app targeting. Needs Swift helper. |
| **AudioProcessTap** | **Yes** (process-level) | Low-Medium | Apple (free) | macOS 14.4+. Newest, most powerful. Limited docs. |
| **Soundflower** | No | — | MIT | **Deprecated.** Needs kext, no Apple Silicon. |
| **Background Music** | Partial | Low | GPL-2.0 | Per-app volume control + virtual device. |

**Notable projects**:
- **AudioCap** (github.com/insidegui/AudioCap) — Swift app using AudioProcessTap for per-process capture
- **OBS Studio** — Has ScreenCaptureKit audio capture

**Recommendation**: **ScreenCaptureKit** for per-app capture (our primary need). **BlackHole** as simpler fallback (meetcap's approach). **AudioProcessTap** if targeting macOS 14.4+ only.

---

## Audio Capture Libraries

| Tool | Language | Install Experience | Best For |
|---|---|---|---|
| **sounddevice** | Python | `pip install` just works | **Preferred.** Callback streams, NumPy, async. |
| **PyAudio** | Python | Fragile on Apple Silicon | Legacy. Avoid unless dependency requires it. |
| **pvrecorder** | C/Python | Good | Simple capture-only. Picovoice ecosystem. |
| **cpal** | Rust | Good | If building in Rust. |

---

## Real-Time Audio Pipelines

| Tool | What It Does | License | Apple Silicon | 24/7 Fit |
|---|---|---|---|---|
| **RealtimeSTT** | Continuous listen → VAD → streaming Whisper | MIT | Yes (CPU) | **Excellent.** Handles VAD + utterance segmentation + streaming partials. |
| **RealtimeTTS** | Streaming text → speech (token-by-token) | MIT | Yes | Companion to RealtimeSTT. Coqui/Piper for local. |
| **LiveKit Agents** | WebRTC rooms + AI agent framework | Apache 2.0 | Yes | Overkill for local-only. Great if agent needs network access. |
| **SpeechRecognition** | Unified API across STT backends | BSD-3 | Yes | Prototyping only. Weak VAD, blocking API. |

---

## Complete Voice Assistant Frameworks

| Tool | Status | macOS Support | Notes |
|---|---|---|---|
| **OVOS (Open Voice OS)** | Active (Mycroft successor) | Linux-focused, friction on macOS | Full assistant stack with skill ecosystem |
| **Home Assistant Voice / Wyoming** | Very active | Works on macOS | Best for smart home. OpenWakeWord + faster-whisper + Piper TTS. |
| **Rhasspy 3** | Merged into Wyoming | Linux-focused | Good architecture to study. |
| **Willow** | Slowed | Server runs anywhere | ESP32 satellites + inference server concept. |
| **Leon** | Slow development | Works via Node.js | Small ecosystem. Lower priority. |
| **Jasper** | **Dead** since ~2016 | — | Historical only. |

---

## TTS (Text-to-Speech) for Agent Responses

| Tool | Type | License | Apple Silicon | Notes |
|---|---|---|---|---|
| **Piper TTS** | ONNX neural TTS | MIT | Yes (CPU, fast) | Wyoming ecosystem. Many voices. Best local option. |
| **Coqui XTTS** | PyTorch neural TTS | MPL-2.0 | MPS (slow) | Voice cloning. Company dead but code works. |
| **macOS `say`** | System TTS | Built-in | Native | Basic but zero-setup. |
| **RealtimeTTS** | Multi-engine wrapper | MIT | Yes | Wraps Coqui, pyttsx3, cloud APIs. |

---

## Recommended Stack for Edward

### For Phase 1 (Mic capture + transcription):
```
sounddevice (capture) → Silero VAD (filter) → whisper.cpp or MLX Whisper (transcribe) → SQLite
```

### For Phase 2 (System audio capture):
```
ScreenCaptureKit Swift helper (per-app audio) → Unix socket → Python consumer
OR: BlackHole (simpler, system-wide) — meetcap's proven approach
```

### For Phase 3 (Diarization):
```
diart (real-time, pyannote-based) OR sherpa-onnx (lightweight, meetcap's approach)
```

### For Phase 4 (Intelligence):
```
OpenWakeWord (wake word) → RealtimeSTT (streaming transcription) → Local LLM (MLX/Ollama)
→ RealtimeTTS + Piper (spoken response)
```

### Key Insight from meetcap:
meetcap already solved mic+system audio+transcription+diarization+summarization for macOS. Consider:
1. **Using meetcap as a library/dependency** for the recording+transcription layer
2. **Extending it** with always-on daemon mode, wake word, real-time streaming, and intelligence
3. **Building fresh** but borrowing its architecture choices (BlackHole, Parakeet TDT, sherpa-onnx, Qwen via MLX)
