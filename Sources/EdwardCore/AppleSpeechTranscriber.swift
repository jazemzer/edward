import Foundation
import Speech
import AVFoundation

public final class AppleSpeechTranscriber {
    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let sampleRate: Int
    private let audioFormat: AVAudioFormat
    private var isRunning = false

    public var onPartialResult: ((String) -> Void)?
    public var onFinalResult: ((String, Date) -> Void)?

    public init(locale: Locale = .current, sampleRate: Int = 16000) {
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
        self.sampleRate = sampleRate
        self.audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    }

    public static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        startRecognitionTask()
    }

    public func feedSamples(_ samples: [Float]) {
        guard isRunning, let request = request else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        for i in 0..<samples.count {
            channelData[i] = samples[i]
        }
        request.append(buffer)
    }

    public func stop() {
        isRunning = false
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private func startRecognitionTask() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        self.request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString

                if result.isFinal {
                    self.onFinalResult?(text, Date())
                    self.logWordTimings(result.bestTranscription)
                    // Restart for continuous recognition
                    if self.isRunning {
                        self.restartRecognitionTask()
                    }
                } else {
                    self.onPartialResult?(text)
                }
            }

            if let error = error {
                let nsError = error as NSError
                // Error 216 = recognition request was canceled (expected on restart)
                // Error 1110 = no speech detected (normal)
                let ignorable = nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 216 || nsError.code == 1110)
                if !ignorable {
                    log.info("[AppleSpeech] Recognition error: \(error.localizedDescription)")
                }
                if self.isRunning && !ignorable {
                    self.restartRecognitionTask()
                }
            }
        }
    }

    private func restartRecognitionTask() {
        task?.cancel()
        task = nil
        request = nil
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.startRecognitionTask()
        }
    }

    private func logWordTimings(_ transcription: SFTranscription) {
        let segments = transcription.segments
        guard !segments.isEmpty else { return }
        let timings = segments.prefix(5).map { "\($0.substring)@\(String(format: "%.2f", $0.timestamp))s" }
        log.debug("[AppleSpeech] Word timings (first 5): \(timings.joined(separator: ", "))")
    }
}
