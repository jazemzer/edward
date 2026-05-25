import SwiftUI
import ServiceManagement
import EdwardCore

@main
struct EdwardApp: App {
    @StateObject private var viewModel = EdwardViewModel()

    var body: some Scene {
        WindowGroup("Edward") {
            MainWindowView(viewModel: viewModel)
        }
        .defaultSize(width: 700, height: 600)

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

// MARK: - Main Window

struct MainWindowView: View {
    @ObservedObject var viewModel: EdwardViewModel
    @State private var selectedTab: MainTab = .live

    enum MainTab {
        case live, sessions
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top controls bar
            ControlBarView(viewModel: viewModel)

            Divider()

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("Live").tag(MainTab.live)
                Text("Sessions").tag(MainTab.sessions)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            // Tab content
            switch selectedTab {
            case .live:
                TranscriptContentView(viewModel: viewModel)
            case .sessions:
                SessionsListView(viewModel: viewModel)
            }

            // Fixed partial transcription bar
            if selectedTab == .live, let partial = viewModel.partialText {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                    Text(partial)
                        .font(.body)
                        .italic()
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .onAppear {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Control Bar

struct ControlBarView: View {
    @ObservedObject var viewModel: EdwardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // Status
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isRunning ? .green : .gray)
                        .frame(width: 10, height: 10)
                    Text(viewModel.statusText)
                        .font(.headline)
                }

                Spacer()

                // Settings button
                Button(action: { SettingsWindowController.shared.show(viewModel: viewModel) }) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isRunning)

                // Copilot toggle button
                Button(action: { viewModel.toggleCopilot() }) {
                    Image(systemName: viewModel.showCopilot ? "sparkles" : "sparkles")
                        .foregroundColor(viewModel.showCopilot ? .yellow : .primary)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.isRunning && !viewModel.showCopilot)
                .help("Toggle AI Copilot panel")

                // Start/Stop button
                Button(action: { viewModel.toggleDaemon() }) {
                    HStack(spacing: 4) {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: viewModel.isRunning ? "stop.fill" : "play.fill")
                        }
                        Text(viewModel.isLoading ? "Loading..." : (viewModel.isRunning ? "Stop" : "Start"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(viewModel.isRunning ? Color.red.opacity(0.15) : Color.green.opacity(0.15))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
            }

            if let error = viewModel.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                    if error.contains("Screen recording permission") {
                        Button("Open Screen Recording Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Transcript Content

struct TranscriptContentView: View {
    @ObservedObject var viewModel: EdwardViewModel
    @State private var searchText = ""
    @State private var autoScroll = true

    var filteredTranscripts: [TranscriptEntry] {
        if searchText.isEmpty {
            return viewModel.transcripts
        }
        return viewModel.transcripts.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search transcripts...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)

                Spacer()

                Text("\(viewModel.transcripts.count) entries")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Transcript list
            if filteredTranscripts.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tortoise")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(viewModel.isRunning ? "Listening... speak to see transcripts" : "Press Start to begin")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredTranscripts, id: \.id) { entry in
                                TranscriptRowView(entry: entry, onDelete: {
                                    viewModel.deleteTranscript(entry)
                                })
                                    .onAppear {
                                        if entry.id == filteredTranscripts.last?.id {
                                            autoScroll = true
                                        }
                                    }
                                    .onDisappear {
                                        if entry.id == filteredTranscripts.last?.id {
                                            autoScroll = false
                                        }
                                    }
                                Divider()
                            }
                        }
                    }
                    .onAppear {
                        if let last = filteredTranscripts.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.transcripts.count) {
                        if autoScroll, let last = filteredTranscripts.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Available Languages

struct LanguageOption: Identifiable, Hashable {
    let id: String // language code
    let name: String
    let flag: String
}

let availableLanguages: [LanguageOption] = [
    LanguageOption(id: "en", name: "English", flag: "EN"),
    LanguageOption(id: "nl", name: "Dutch", flag: "NL"),
]

// MARK: - ViewModel

@MainActor
class EdwardViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var isLoading = false
    @Published var isFinalizingSession = false
    @Published var transcripts: [TranscriptEntry] = []
    @Published var statusText = "Stopped"
    @Published var errorMessage: String?
    @Published var selectedLanguages: Set<String> = ["en"]
    @Published var partialText: String?
    @Published var enableMicCapture: Bool = true
    @Published var enableSystemAudioCapture: Bool = true
    @Published var systemAudioApps: [SystemAudioApp] = SystemAudioApp.defaults
    @Published var mergeWindow: Double = UserDefaults.standard.object(forKey: "mergeWindow") as? Double ?? EdwardConfig.default.mergeWindow {
        didSet {
            UserDefaults.standard.set(mergeWindow, forKey: "mergeWindow")
        }
    }
    @Published var sessionResult: SessionResult?
    @Published var showSessionSummary = false
    @Published var sessions: [SessionRecord] = []
    @Published var finalizingSessionPath: String?
    @Published var retranscribingSessionId: Int64?
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    @Published var startOnLaunch: Bool = UserDefaults.standard.bool(forKey: "startOnLaunch") {
        didSet {
            UserDefaults.standard.set(startOnLaunch, forKey: "startOnLaunch")
        }
    }
    @Published var dataDir: String = UserDefaults.standard.string(forKey: "dataDir") ?? EdwardConfig.default.dataDir {
        didSet {
            UserDefaults.standard.set(dataDir, forKey: "dataDir")
        }
    }
    @Published var ollamaModel: String = UserDefaults.standard.string(forKey: "ollamaModel") ?? EdwardConfig.default.ollamaModel {
        didSet {
            UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel")
        }
    }
    @Published var ollamaBaseURL: String = UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? EdwardConfig.default.ollamaBaseURL {
        didSet {
            UserDefaults.standard.set(ollamaBaseURL, forKey: "ollamaBaseURL")
        }
    }
    @Published var copilotSystemPrompt: String = UserDefaults.standard.string(forKey: "copilotSystemPrompt") ?? CopilotEngine.defaultSystemPrompt {
        didSet {
            UserDefaults.standard.set(copilotSystemPrompt, forKey: "copilotSystemPrompt")
            copilotEngine?.systemPrompt = copilotSystemPrompt
        }
    }
    @Published var copilotUserPromptPrefix: String = UserDefaults.standard.string(forKey: "copilotUserPromptPrefix") ?? CopilotEngine.defaultUserPromptPrefix {
        didSet {
            UserDefaults.standard.set(copilotUserPromptPrefix, forKey: "copilotUserPromptPrefix")
            copilotEngine?.userPromptPrefix = copilotUserPromptPrefix
        }
    }
    @Published var copilotEnabled: Bool = UserDefaults.standard.object(forKey: "copilotEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(copilotEnabled, forKey: "copilotEnabled")
            copilotEngine?.isEnabled = copilotEnabled
        }
    }
    @Published var availableOllamaModels: [String] = []
    @Published var showCopilot: Bool = false

    @Published var isModelsLoaded = false

    private var daemon: EdwardDaemon?
    private(set) var copilotEngine: CopilotEngine?
    private var copilotOverlay: CopilotOverlayController?

    init() {
        // Load saved language preferences
        let saved = UserDefaults.standard.stringArray(forKey: "selectedLanguages")
        if let saved = saved, !saved.isEmpty {
            selectedLanguages = Set(saved)
        }

        // Load recent transcripts from database
        var config = EdwardConfig.load()
        config.dataDir = dataDir
        let storage = Storage(config: config)
        if let _ = try? storage.open(),
           let recent = try? storage.recent(limit: 50) {
            transcripts = recent.reversed()
        }
        if let _ = try? storage.open(),
           let pastSessions = try? storage.recentSessions(limit: 20) {
            sessions = pastSessions
        }

        // Pre-load models on launch
        Task { await preloadModels() }

        // Auto-start listening if preference is set
        if startOnLaunch {
            Task { await start() }
        }
    }

    func preloadModels() async {
        guard daemon == nil else { return }
        isLoading = true
        statusText = "Loading models..."

        var config = EdwardConfig.load()
        config.languages = Array(selectedLanguages)
        config.enableMicCapture = enableMicCapture
        config.enableSystemAudioCapture = enableSystemAudioCapture
        config.systemAudioApps = systemAudioApps
        config.mergeWindow = mergeWindow
        config.dataDir = dataDir

        let d = EdwardDaemon(config: config)
        self.daemon = d

        d.onTranscription = { [weak self] entry in
            Task { @MainActor in
                self?.partialText = nil
                self?.transcripts.append(entry)
                if (self?.transcripts.count ?? 0) > 200 {
                    self?.transcripts.removeFirst()
                }
                self?.copilotEngine?.addTranscript(text: entry.text, timestamp: entry.timestamp)
            }
        }

        d.onPartialTranscription = { [weak self] text in
            Task { @MainActor in
                self?.partialText = text
                self?.copilotEngine?.updatePartialTranscription(text)
            }
        }

        d.onWordTimestampsReady = { [weak self] entryId, timestamps in
            Task { @MainActor in
                if let idx = self?.transcripts.firstIndex(where: { $0.id == entryId }) {
                    self?.transcripts[idx].wordTimestamps = timestamps
                }
            }
        }

        d.onSessionFinalizing = { [weak self] sessionInfo in
            Task { @MainActor in
                let placeholder = SessionRecord(
                    id: -1,
                    startTime: sessionInfo.startTime,
                    endTime: sessionInfo.endTime,
                    duration: sessionInfo.duration,
                    audioPath: sessionInfo.path,
                    numSpeakers: nil,
                    transcriptText: nil,
                    summary: nil,
                    modelUsed: nil
                )
                self?.sessions.insert(placeholder, at: 0)
                self?.finalizingSessionPath = sessionInfo.path
                self?.isFinalizingSession = true
            }
        }

        d.onSessionComplete = { [weak self] result in
            Task { @MainActor in
                self?.isFinalizingSession = false
                self?.finalizingSessionPath = nil
                self?.statusText = "Ready"
                self?.sessionResult = result
                self?.loadSessions()
            }
        }

        do {
            try await d.initialize()
            isModelsLoaded = true
            isLoading = false
            statusText = "Ready"
        } catch {
            isLoading = false
            statusText = "Error loading models"
            errorMessage = error.localizedDescription
            self.daemon = nil
        }
    }

    func saveLanguagePreferences() {
        UserDefaults.standard.set(Array(selectedLanguages), forKey: "selectedLanguages")
    }

    func toggleLanguage(_ code: String) {
        if selectedLanguages.contains(code) {
            if selectedLanguages.count > 1 {
                selectedLanguages.remove(code)
            }
            // Don't allow removing the last language
        } else {
            selectedLanguages.insert(code)
        }
        saveLanguagePreferences()
    }

    var languageSummary: String {
        let names = availableLanguages
            .filter { selectedLanguages.contains($0.id) }
            .map { $0.name }
        return names.joined(separator: ", ")
    }

    func toggleDaemon() {
        if isRunning {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        errorMessage = nil

        // If models aren't loaded yet, wait for preload to finish
        if !isModelsLoaded {
            isLoading = true
            statusText = "Loading models..."
            await preloadModels()
            guard isModelsLoaded else { return }
        }

        // Recreate daemon if config changed
        var config = EdwardConfig.load()
        config.languages = Array(selectedLanguages)
        config.enableMicCapture = enableMicCapture
        config.enableSystemAudioCapture = enableSystemAudioCapture
        config.systemAudioApps = systemAudioApps
        config.mergeWindow = mergeWindow
        config.dataDir = dataDir

        if let existing = daemon, existing.configHash != config.configHash {
            existing.shutdown()
            daemon = nil
            isModelsLoaded = false
            await preloadModels()
            guard isModelsLoaded else { return }
        }

        do {
            try daemon!.start()
            isRunning = true
            isLoading = false
            let sources = daemon!.activeSources.joined(separator: " + ")
            statusText = "Listening (\(languageSummary)) — \(sources)"

            // Start copilot engine
            copilotEngine?.reset()
            let engine = CopilotEngine(model: ollamaModel, baseURL: ollamaBaseURL)
            engine.systemPrompt = copilotSystemPrompt
            engine.userPromptPrefix = copilotUserPromptPrefix
            engine.isEnabled = copilotEnabled
            self.copilotEngine = engine
            engine.start()

            // Check for failed sources after system audio pipelines have had time to start
            let d = daemon!
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    let failed = d.failedSources
                    if !failed.isEmpty {
                        let msgs = failed.map { "\($0.label): \($0.error)" }
                        self.errorMessage = msgs.joined(separator: "\n")
                    }
                    let active = d.activeSources
                    if !active.isEmpty {
                        self.statusText = "Listening (\(self.languageSummary)) — \(active.joined(separator: " + "))"
                    }
                }
            }
        } catch {
            isLoading = false
            isRunning = false
            statusText = "Error"
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        let hadSessionRecording = daemon?.hasActiveSession ?? false
        daemon?.stop()
        copilotEngine?.stop()
        isRunning = false
        partialText = nil

        if hadSessionRecording {
            isFinalizingSession = true
            statusText = "Finalizing session..."
        } else {
            statusText = "Stopped"
        }
    }

    func toggleCopilot() {
        guard let engine = copilotEngine else { return }
        if copilotOverlay == nil {
            copilotOverlay = CopilotOverlayController(engine: engine)
            copilotOverlay?.onClose = { [weak self] in
                self?.showCopilot = false
            }
        }
        copilotOverlay?.toggle()
        showCopilot = copilotOverlay?.isVisible ?? false
    }

    func loadSessions() {
        var config = EdwardConfig.load()
        config.dataDir = dataDir
        let storage = Storage(config: config)
        if let _ = try? storage.open(),
           let pastSessions = try? storage.recentSessions(limit: 20) {
            sessions = pastSessions
        }
    }

    func deleteTranscript(_ entry: TranscriptEntry) {
        var config = EdwardConfig.load()
        config.dataDir = dataDir
        let storage = Storage(config: config)
        guard let _ = try? storage.open() else { return }
        try? storage.deleteTranscript(id: entry.id)
        transcripts.removeAll { $0.id == entry.id }
    }

    func renameSession(_ session: SessionRecord, newName: String) {
        var config = EdwardConfig.load()
        config.dataDir = dataDir
        let storage = Storage(config: config)
        guard let _ = try? storage.open(),
              let newPath = try? storage.renameSession(id: session.id, newName: newName) else { return }
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = SessionRecord(
                id: session.id, startTime: session.startTime, endTime: session.endTime,
                duration: session.duration, audioPath: newPath,
                numSpeakers: session.numSpeakers, transcriptText: session.transcriptText,
                summary: session.summary, modelUsed: session.modelUsed
            )
        }
    }

    func deleteSession(_ session: SessionRecord) {
        var config = EdwardConfig.load()
        config.dataDir = dataDir
        let storage = Storage(config: config)
        guard let _ = try? storage.open() else { return }
        try? storage.deleteSession(id: session.id)
        sessions.removeAll { $0.id == session.id }
    }

    func copySessionTranscript(_ session: SessionRecord) {
        guard let text = session.transcriptText else { return }
        // Strip speaker labels like "[Speaker 1] " from lines
        let cleaned = text.components(separatedBy: .newlines).map { line in
            if let range = line.range(of: #"^\[.*?\]\s*"#, options: .regularExpression) {
                return String(line[range.upperBound...])
            }
            return line
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cleaned, forType: .string)
    }

    func generateSessionSummary(_ session: SessionRecord) {
        guard let transcript = session.transcriptText else { return }
        let client = OllamaClient(model: ollamaModel, baseURL: ollamaBaseURL)

        Task {
            let prompt = "Summarize the following transcript concisely. Focus on key topics, decisions, and action items:\n\n\(transcript)"
            do {
                let summary = try await client.generate(prompt: prompt, system: "You are a helpful assistant that summarizes meeting transcripts concisely.")

                var cfg = EdwardConfig.load()
                cfg.dataDir = self.dataDir
                let storage = Storage(config: cfg)
                guard let _ = try? storage.open() else { return }
                try storage.updateSessionSummary(id: session.id, summary: summary)
                self.loadSessions()
            } catch {
                self.errorMessage = "Summary failed: \(error.localizedDescription)"
            }
        }
    }

    func retranscribeSession(_ session: SessionRecord) {
        guard retranscribingSessionId == nil else {
            errorMessage = "Retranscription already in progress"
            return
        }
        retranscribingSessionId = session.id

        Task {
            do {
                var cfg = EdwardConfig.load()
                cfg.dataDir = self.dataDir
                let storage = Storage(config: cfg)
                try storage.open()

                let finalizer = SessionFinalizer(config: cfg)
                let result = try await finalizer.retranscribe(session: session, storage: storage)

                self.retranscribingSessionId = nil
                self.sessionResult = result
                self.loadSessions()
            } catch {
                self.retranscribingSessionId = nil
                self.errorMessage = "Retranscription failed: \(error.localizedDescription)"
            }
        }
    }

    func fetchOllamaModels() {
        Task {
            guard let url = URL(string: "\(ollamaBaseURL)/api/tags") else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["models"] as? [[String: Any]] {
                    let names = models.compactMap { $0["name"] as? String }.sorted()
                    self.availableOllamaModels = names
                }
            } catch {
                self.availableOllamaModels = []
            }
        }
    }
}

// MARK: - Language Toggle Button

struct LanguageToggle: View {
    let lang: LanguageOption
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                Text(lang.name)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}

// MARK: - Source Toggle Button

struct SourceToggle: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: EdwardViewModel

    var body: some View {
        Form {
            Section("Languages") {
                Text("Select which languages are spoken. The ASR model will prioritize these.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(availableLanguages) { lang in
                    Toggle(isOn: Binding(
                        get: { viewModel.selectedLanguages.contains(lang.id) },
                        set: { _ in viewModel.toggleLanguage(lang.id) }
                    )) {
                        HStack {
                            Text(lang.flag)
                                .font(.caption)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(3)
                            Text(lang.name)
                        }
                    }
                }
            }

            Section("Audio Sources") {
                Text("Configure which audio sources to capture.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Microphone", isOn: $viewModel.enableMicCapture)

                Toggle("System Audio", isOn: $viewModel.enableSystemAudioCapture)

                if viewModel.enableSystemAudioCapture {
                    ForEach(viewModel.systemAudioApps.indices, id: \.self) { idx in
                        Toggle(isOn: $viewModel.systemAudioApps[idx].enabled) {
                            VStack(alignment: .leading) {
                                Text(viewModel.systemAudioApps[idx].label)
                                Text(viewModel.systemAudioApps[idx].bundleId)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Storage") {
                Text("Folder where audio recordings and transcripts are saved.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text(viewModel.dataDir)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            viewModel.dataDir = url.path
                        }
                    }
                }

                Button("Reset to Default") {
                    viewModel.dataDir = EdwardConfig.default.dataDir
                }
                .font(.caption)
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)
                Toggle("Start Listening on Launch", isOn: $viewModel.startOnLaunch)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 450)
    }
}

// MARK: - Settings Dialog (opened from gear button)

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case languages = "Languages"
    case audioSources = "Audio Sources"
    case ai = "AI"
    case storage = "Storage"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .languages: return "globe"
        case .audioSources: return "waveform"
        case .ai: return "sparkles"
        case .storage: return "folder"
        }
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(viewModel: EdwardViewModel) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = SettingsDialogView(viewModel: viewModel, onClose: { [weak self] in
            self?.window?.close()
        })
        let hostingView = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 550),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

struct SettingsDialogView: View {
    @ObservedObject var viewModel: EdwardViewModel
    var onClose: (() -> Void)?
    @State private var selectedCategory: SettingsCategory = .general

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HSplitView {
                // Sidebar
                List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                    Label(category.rawValue, systemImage: category.icon)
                        .tag(category)
                }
                .listStyle(.sidebar)
                .frame(minWidth: 140, idealWidth: 160, maxWidth: 180)

                // Detail panel
                Group {
                    switch selectedCategory {
                    case .general:
                        SettingsGeneralPane(viewModel: viewModel)
                    case .languages:
                        SettingsLanguagesPane(viewModel: viewModel)
                    case .audioSources:
                        SettingsAudioSourcesPane(viewModel: viewModel)
                    case .ai:
                        SettingsAIPane(viewModel: viewModel)
                    case .storage:
                        SettingsStoragePane(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Settings Panes

struct SettingsGeneralPane: View {
    @ObservedObject var viewModel: EdwardViewModel

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)
            Toggle("Start Listening on Launch", isOn: $viewModel.startOnLaunch)
        }
        .formStyle(.grouped)
    }
}

struct SettingsLanguagesPane: View {
    @ObservedObject var viewModel: EdwardViewModel

    var body: some View {
        Form {
            Section {
                Text("Select which languages are spoken. The ASR model will prioritize these.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(availableLanguages) { lang in
                    Toggle(isOn: Binding(
                        get: { viewModel.selectedLanguages.contains(lang.id) },
                        set: { _ in viewModel.toggleLanguage(lang.id) }
                    )) {
                        HStack {
                            Text(lang.flag)
                                .font(.caption)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(3)
                            Text(lang.name)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingsAudioSourcesPane: View {
    @ObservedObject var viewModel: EdwardViewModel

    var body: some View {
        Form {
            Section {
                Text("Configure which audio sources to capture.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Microphone", isOn: $viewModel.enableMicCapture)
                Toggle("System Audio", isOn: $viewModel.enableSystemAudioCapture)
            }

            if viewModel.enableSystemAudioCapture {
                Section("Applications") {
                    ForEach(viewModel.systemAudioApps.indices, id: \.self) { idx in
                        Toggle(isOn: $viewModel.systemAudioApps[idx].enabled) {
                            VStack(alignment: .leading) {
                                Text(viewModel.systemAudioApps[idx].label)
                                Text(viewModel.systemAudioApps[idx].bundleId)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Transcription") {
                HStack {
                    Text("Commit delay")
                        .frame(width: 100, alignment: .leading)
                    Slider(value: $viewModel.mergeWindow, in: 0.2...3.0, step: 0.1)
                    Text("\(viewModel.mergeWindow, specifier: "%.1f")s")
                        .frame(width: 35)
                        .font(.caption)
                }
                Text("How long to wait after speech pauses before finalizing. Lower = faster but more fragmented.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingsAIPane: View {
    @ObservedObject var viewModel: EdwardViewModel
    @State private var connectionStatus: String?

    var body: some View {
        Form {
            Section("Ollama") {
                Text("Local LLM used for session summarization.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Server URL")
                        .frame(width: 80, alignment: .leading)
                    TextField("http://localhost:11434", text: $viewModel.ollamaBaseURL)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Model")
                        .frame(width: 80, alignment: .leading)
                    if viewModel.availableOllamaModels.isEmpty {
                        TextField("Model name", text: $viewModel.ollamaModel)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: $viewModel.ollamaModel) {
                            ForEach(viewModel.availableOllamaModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                    }
                    Button("Refresh") {
                        viewModel.fetchOllamaModels()
                    }
                    .font(.caption)
                }

                if let status = connectionStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(status.contains("Connected") ? .green : .red)
                }

                Button("Test Connection") {
                    testConnection()
                }
                .font(.caption)
            }

            Section("Copilot") {
                Toggle("Enable AI Copilot", isOn: $viewModel.copilotEnabled)

                Text("System Prompt")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $viewModel.copilotSystemPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))

                Text("User Prompt Prefix (transcript is appended after this)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Prefix before transcript", text: $viewModel.copilotUserPromptPrefix)
                    .textFieldStyle(.roundedBorder)

                Button("Reset to Defaults") {
                    viewModel.copilotSystemPrompt = CopilotEngine.defaultSystemPrompt
                    viewModel.copilotUserPromptPrefix = CopilotEngine.defaultUserPromptPrefix
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            viewModel.fetchOllamaModels()
        }
    }

    private func testConnection() {
        connectionStatus = nil
        let client = OllamaClient(model: viewModel.ollamaModel, baseURL: viewModel.ollamaBaseURL)
        Task {
            let available = await client.isAvailable()
            connectionStatus = available ? "Connected" : "Cannot reach Ollama at \(viewModel.ollamaBaseURL)"
        }
    }
}

struct SettingsStoragePane: View {
    @ObservedObject var viewModel: EdwardViewModel

    var body: some View {
        Form {
            Section {
                Text("Folder where audio recordings and transcripts are saved.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text(viewModel.dataDir)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            viewModel.dataDir = url.path
                        }
                    }
                }

                Button("Reset to Default") {
                    viewModel.dataDir = EdwardConfig.default.dataDir
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcript Row

struct TranscriptRowView: View {
    let entry: TranscriptEntry
    var onDelete: (() -> Void)?
    @State private var showWordTimestamps = false

    private var speakerColor: Color {
        guard let id = entry.speakerId else { return .secondary }
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo]
        let hash = abs(id.hashValue)
        return colors[hash % colors.count]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let _ = entry.speakerId {
                    Text(entry.speakerLabel)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(speakerColor)
                }

                if showWordTimestamps, let words = entry.wordTimestamps {
                    WordTimestampView(words: words)
                } else {
                    Text(entry.text)
                        .font(.body)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Text("\(String(format: "%.1f", entry.duration))s")
                    if let conf = entry.speakerConfidence {
                        Text("speaker: \(String(format: "%.0f%%", conf * 100))")
                    }
                    Text("processed in \(String(format: "%.2f", entry.processingTime))s")
                    if entry.wordTimestamps != nil {
                        Button(action: { showWordTimestamps.toggle() }) {
                            Text(showWordTimestamps ? "hide timing" : "show timing")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.timeString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                if let source = entry.source {
                    Text(sourceDisplayName(source))
                        .font(.system(.caption2, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(sourceColor(source).opacity(0.15))
                        .foregroundColor(sourceColor(source))
                        .cornerRadius(4)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contextMenu {
            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func sourceDisplayName(_ source: String) -> String {
        if source == "mic" { return "MIC" }
        if source.hasPrefix("system:") {
            return String(source.dropFirst(7)).uppercased()
        }
        return source.uppercased()
    }

    private func sourceColor(_ source: String) -> Color {
        if source == "mic" { return .blue }
        if source.contains("zoom") { return .indigo }
        if source.contains("chrome") { return .orange }
        if source.contains("teams") { return .purple }
        return .gray
    }
}

// MARK: - Word Timestamp View

struct WordTimestampView: View {
    let words: [WordTimestamp]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                VStack(spacing: 0) {
                    Text(word.text)
                        .font(.body)
                    Text(String(format: "%.2f", word.startTime))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(4)
            }
        }
        .textSelection(.enabled)
    }
}

// Simple flow layout for wrapping word chips
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

// MARK: - Sessions List View

struct SessionsListView: View {
    @ObservedObject var viewModel: EdwardViewModel
    @State private var selectedSessionId: Int64?
    @State private var renamingSession: SessionRecord?
    @State private var renameText = ""
    @State private var sessionToDelete: SessionRecord?
    @State private var showDeleteConfirmation = false

    private var selectedSession: SessionRecord? {
        guard let id = selectedSessionId else { return nil }
        return viewModel.sessions.first { $0.id == id }
    }

    var body: some View {
        if viewModel.sessions.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No sessions yet")
                    .foregroundColor(.secondary)
                Text("Sessions appear here after you stop a recording")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    // Session list
                    VStack(spacing: 0) {
                        List(viewModel.sessions, selection: $selectedSessionId) { session in
                        SessionRowView(session: session, isFinalizing: viewModel.finalizingSessionPath == session.audioPath)
                            .tag(session.id)
                            .popover(isPresented: Binding(
                                get: { renamingSession?.id == session.id },
                                set: { if !$0 { renamingSession = nil } }
                            )) {
                                RenamePopover(
                                    text: $renameText,
                                    onCommit: {
                                        if !renameText.isEmpty {
                                            viewModel.renameSession(session, newName: renameText)
                                        }
                                        renamingSession = nil
                                    },
                                    onCancel: { renamingSession = nil }
                                )
                            }
                            .contextMenu {
                                Button {
                                    renameText = ((session.audioPath as NSString).lastPathComponent as NSString).deletingPathExtension
                                    renamingSession = session
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }

                                Button {
                                    viewModel.copySessionTranscript(session)
                                } label: {
                                    Label("Copy Transcript", systemImage: "doc.on.doc")
                                }
                                .disabled(session.transcriptText == nil)

                                Button {
                                    viewModel.generateSessionSummary(session)
                                } label: {
                                    Label("Generate AI Summary", systemImage: "sparkles")
                                }
                                .disabled(session.transcriptText == nil)

                                Button {
                                    viewModel.retranscribeSession(session)
                                } label: {
                                    if viewModel.retranscribingSessionId == session.id {
                                        Label("Retranscribing...", systemImage: "hourglass")
                                    } else {
                                        Label("Retranscribe", systemImage: "arrow.clockwise")
                                    }
                                }
                                .disabled(viewModel.retranscribingSessionId != nil)

                                Divider()

                                Button {
                                    let url = URL(fileURLWithPath: session.audioPath)
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } label: {
                                    Label("Show in Finder", systemImage: "folder")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    sessionToDelete = session
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .listStyle(.sidebar)
                    }
                    .frame(width: geo.size.width * 0.25)
                    .clipped()

                    Divider()

                    // Session detail
                    Group {
                        if let session = selectedSession {
                            SessionDetailView(session: session, viewModel: viewModel)
                        } else {
                            VStack {
                                Spacer()
                                Text("Select a session")
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .alert("Delete Session?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { sessionToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let session = sessionToDelete {
                        if selectedSessionId == session.id {
                            selectedSessionId = nil
                        }
                        viewModel.deleteSession(session)
                    }
                    sessionToDelete = nil
                }
            } message: {
                Text("This will permanently delete the session and its audio file. This action cannot be undone.")
            }
        }
    }
}

struct RenamePopover: View {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text("Rename")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit {
                    if text.isEmpty {
                        onCancel()
                    } else {
                        onCommit()
                    }
                }
                .onExitCommand(perform: onCancel)
                .frame(minWidth: 180)
        }
        .padding(12)
        .onAppear { isFocused = true }
    }
}

struct SessionRowView: View {
    let session: SessionRecord
    var isFinalizing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sessionDisplayName)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack(spacing: 6) {
                if isFinalizing {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Finalizing...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Label(session.durationString, systemImage: "clock")
                    if let speakers = session.numSpeakers {
                        Label("\(speakers)", systemImage: "person.2")
                    }
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var sessionDisplayName: String {
        let filename = (session.audioPath as NSString).lastPathComponent
        let name = (filename as NSString).deletingPathExtension
        if name.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return session.dateString
        }
        return name
    }
}

// MARK: - Session Audio Player

import AVFoundation

class SessionAudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var isLoaded = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(sessionPath: String, sampleRate: Int) {
        player?.stop()
        timer?.invalidate()
        isPlaying = false
        currentTime = 0

        let audioPath = Storage.playbackFilePath(for: sessionPath)
        guard FileManager.default.fileExists(atPath: audioPath) else {
            isLoaded = false
            return
        }

        do {
            player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: audioPath))
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            isLoaded = true
        } catch {
            isLoaded = false
        }
    }

    func play() {
        player?.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: Double) {
        player?.currentTime = time
        currentTime = time
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.player else { return }
            DispatchQueue.main.async {
                self.currentTime = p.currentTime
                if !p.isPlaying {
                    self.isPlaying = false
                    self.timer?.invalidate()
                }
            }
        }
    }
}

struct SessionDetailView: View {
    let session: SessionRecord
    @ObservedObject var viewModel: EdwardViewModel
    @StateObject private var player = SessionAudioPlayer()

    private var isFinalizing: Bool {
        viewModel.finalizingSessionPath == session.audioPath
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sessionDisplayName)
                            .font(.title3)
                            .fontWeight(.semibold)
                        HStack(spacing: 12) {
                            Label(session.durationString, systemImage: "clock")
                            if let speakers = session.numSpeakers {
                                Label("\(speakers) speaker\(speakers == 1 ? "" : "s")", systemImage: "person.2")
                            }
                            if let model = session.modelUsed {
                                Label(model, systemImage: "cpu")
                            }
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                        Text(session.dateString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !isFinalizing {
                        Button(action: { viewModel.generateSessionSummary(session) }) {
                            Label("Summarize", systemImage: "sparkles")
                        }
                        .disabled(session.transcriptText == nil)
                    }
                }

                if isFinalizing {
                    Divider()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Finalizing session...")
                            .font(.headline)
                        Text("Diarizing speakers and generating transcript")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {

                // Audio player controls
                if player.isLoaded {
                    HStack(spacing: 12) {
                        Button(action: { player.togglePlayPause() }) {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)

                        Text(formatTime(player.currentTime))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)

                        Slider(value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ), in: 0...max(player.duration, 0.1))

                        Text(formatTime(player.duration))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if let summary = session.summary {
                    Divider()
                    Text("Summary")
                        .font(.headline)
                    Text(summary)
                        .font(.body)
                        .textSelection(.enabled)
                }

                Divider()
                Text("Transcript")
                    .font(.headline)

                if let segments = loadedSegments {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            TranscriptLineView(
                                segment: segment,
                                isActive: player.isPlaying && isSegmentActive(segment),
                                onTap: {
                                    player.seek(to: segment.start)
                                    player.play()
                                }
                            )
                        }
                    }
                } else if let transcript = session.transcriptText {
                    Text(transcript)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                } // end else (not finalizing)
            }
            .padding()
        }
        .frame(maxWidth: .infinity)
        .onAppear { player.load(sessionPath: session.audioPath, sampleRate: 16000) }
        .onChange(of: session.id) { player.load(sessionPath: session.audioPath, sampleRate: 16000) }
    }

    private var loadedSegments: [TranscriptSegment]? {
        Storage.loadTranscriptJSON(sessionDir: session.audioPath)?.segments
    }

    private func isSegmentActive(_ segment: TranscriptSegment) -> Bool {
        player.currentTime >= segment.start && player.currentTime < segment.end
    }

    private var sessionDisplayName: String {
        let filename = (session.audioPath as NSString).lastPathComponent
        let name = (filename as NSString).deletingPathExtension
        if name.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return session.dateString
        }
        return name
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

struct TranscriptLineView: View {
    let segment: TranscriptSegment
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(timeString)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)

            Text(segment.speaker)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.blue)
                .frame(width: 80, alignment: .leading)

            Text(segment.text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var timeString: String {
        let total = Int(segment.start)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Session Summary View

struct SessionSummaryView: View {
    let result: SessionResult?
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Session Summary")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if let result = result {
                    Button(action: { revealInFinder(path: result.audioPath) }) {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }

            if let result = result {
                HStack(spacing: 16) {
                    Label("\(String(format: "%.0f", result.duration))s", systemImage: "clock")
                    Label("\(result.numSpeakers) speaker\(result.numSpeakers == 1 ? "" : "s")", systemImage: "person.2")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)

                Divider()

                if let summary = result.summary {
                    Text("Summary")
                        .font(.headline)
                    Text(summary)
                        .font(.body)
                        .textSelection(.enabled)

                    Divider()
                }

                Text("Diarized Transcript")
                    .font(.headline)

                ScrollView {
                    Text(result.diarizedTranscript)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No session data available")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
