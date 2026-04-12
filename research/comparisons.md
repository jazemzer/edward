# Tool Comparisons for Edward

> Research compiled March 2026. Based on knowledge through mid-2025 — verify repos for latest status.

---

## Vosk vs Whisper — Speech Recognition

| Aspect | **Vosk** | **Whisper** (OpenAI) |
|---|---|---|
| **Architecture** | Kaldi-based (traditional ASR + neural) | Transformer encoder-decoder |
| **Runs offline** | Yes | Yes |
| **Real-time / streaming** | Yes — designed for it | No native streaming (batch) |
| **Model sizes** | Very small (~50MB) to medium | Tiny (~39MB) to Large (~3GB) |
| **Accuracy** | Good, but below Whisper on most benchmarks | State-of-the-art on many benchmarks |
| **Language support** | ~20 languages | ~99 languages |
| **Speed (CPU)** | Fast — optimized for low-latency, embedded | Slower without GPU; real-time factor >1x on CPU for larger models |
| **GPU required?** | No (runs well on CPU/edge devices) | Not required, but strongly recommended for larger models |
| **Resource usage** | Low — suitable for Raspberry Pi, mobile | Higher — larger models need significant RAM/VRAM |
| **API style** | Streaming (feed audio chunks, get partial results) | Batch (pass full audio file/buffer) |
| **Punctuation** | Limited | Built-in punctuation and casing |
| **Translation** | No | Yes (speech to English text) |
| **Speaker diarization** | Basic (via Kaldi) | Not built-in (needs external tools) |
| **License** | Apache 2.0 | MIT |

### When to use Vosk
- Real-time/streaming transcription (live mic, phone calls, voice commands)
- Edge/embedded devices (Raspberry Pi, Android, iOS)
- Low-latency, low-resource environments
- Lightweight offline solution needed

### When to use Whisper
- Highest accuracy matters most (recordings, podcasts, meetings)
- Multilingual support or translation needed
- Batch processing of audio files
- GPU available
- Good punctuation/formatting out of the box

### Hybrid pattern
Use Vosk for real-time partial results and Whisper for final polished transcription.

### Edward relevance
Vosk is listed as a Tier 2 STT option in tools-landscape.md. For Edward's real-time needs, whisper.cpp/MLX Whisper are preferred (Metal acceleration), but Vosk remains a viable lightweight fallback, especially if resource usage becomes a concern.

---

## pyannote vs WeSpeaker — Speaker Recognition

| Aspect | **pyannote** | **WeSpeaker** |
|---|---|---|
| **Primary focus** | Speaker diarization (who spoke when) | Speaker embedding extraction / verification |
| **Architecture** | End-to-end neural diarization pipeline | ResNet / ECAPA-TDNN embedding models |
| **Diarization** | Yes — core strength, full pipeline | No built-in pipeline (embeddings only) |
| **Speaker embeddings** | Yes (uses internal or external embeddings) | Yes — main purpose |
| **Overlapping speech** | Yes — handles it well | Not directly (needs external diarization) |
| **VAD** | Built-in | Not included |
| **Pre-trained models** | Via Hugging Face Hub | Via ModelScope / WeNet ecosystem |
| **Ease of use** | High — `Pipeline.from_pretrained()` for full diarization | Lower — embeddings only, build pipeline yourself |
| **Integration with Whisper** | Excellent (whisperx, common pairing) | Possible but less common |
| **Community / ecosystem** | Large, well-documented, widely adopted | Smaller, more research-oriented |
| **Diarization benchmarks** | State-of-the-art (DIHARD, AMI, VoxConverse) | N/A (not a diarization system) |
| **Embedding quality** | Good | Competitive on VoxCeleb |
| **License** | MIT (gated models on HF) | Apache 2.0 |
| **Backed by** | CNRS (French research) | WeNet / Seasalt AI community |

### Key distinction
They solve **different problems**:
- **pyannote** = full diarization pipeline (segmentation, embedding, clustering, labeling)
- **WeSpeaker** = speaker embedding extractor (vectors for verification, clustering, etc.)

### When to use pyannote
- End-to-end diarization (meeting transcription, podcasts)
- Out-of-the-box solution with minimal setup
- Pairing with Whisper (via whisperx)
- Handling overlapping speakers

### When to use WeSpeaker
- Speaker embeddings for a custom pipeline (verification, identification)
- Building your own diarization system with full control
- Lightweight, fast embedding extraction
- Already in the WeNet ecosystem

### Can they work together?
Yes — pyannote can use external embeddings, so WeSpeaker embeddings could plug into pyannote's clustering. In practice, pyannote's built-in embeddings are good enough that most don't bother.

### Edward relevance
Both are listed in tools-landscape.md's diarization section. For Edward, **diart** (built on pyannote, streaming) or **sherpa-onnx** (lightweight) are the recommended paths. WeSpeaker's ONNX export and near-real-time capability make it a viable alternative if we need custom embedding control.
