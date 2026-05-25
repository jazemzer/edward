import SwiftUI
import EdwardCore

@main
struct EdwardUIApp: App {
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

    var body: some View {
        VStack(spacing: 0) {
            // Top controls bar
            ControlBarView(viewModel: viewModel)

            Divider()

            // Transcript content
            TranscriptContentView(viewModel: viewModel)

            // Fixed partial transcription bar
            if let partial = viewModel.partialText {
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

            // Languages row
            HStack(spacing: 8) {
                Text("Languages")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 65, alignment: .leading)
                ForEach(availableLanguages) { lang in
                    LanguageToggle(
                        lang: lang,
                        isSelected: viewModel.selectedLanguages.contains(lang.id),
                        isDisabled: viewModel.isRunning
                    ) {
                        viewModel.toggleLanguage(lang.id)
                    }
                }
            }

            // Sources row
            HStack(spacing: 8) {
                Text("Sources")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 65, alignment: .leading)
                SourceToggle(
                    label: "Mic",
                    icon: "mic.fill",
                    isSelected: viewModel.enableMicCapture,
                    isDisabled: viewModel.isRunning
                ) {
                    viewModel.enableMicCapture.toggle()
                }
                ForEach(viewModel.systemAudioApps.indices, id: \.self) { idx in
                    SourceToggle(
                        label: viewModel.systemAudioApps[idx].label,
                        icon: "speaker.wave.2.fill",
                        isSelected: viewModel.systemAudioApps[idx].enabled,
                        isDisabled: viewModel.isRunning
                    ) {
                        viewModel.systemAudioApps[idx].enabled.toggle()
                        viewModel.enableSystemAudioCapture = viewModel.systemAudioApps.contains { $0.enabled }
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
                                TranscriptRowView(entry: entry)
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
    @Published var transcripts: [TranscriptEntry] = []
    @Published var statusText = "Stopped"
    @Published var errorMessage: String?
    @Published var selectedLanguages: Set<String> = ["en"]
    @Published var partialText: String?
    @Published var enableMicCapture: Bool = true
    @Published var enableSystemAudioCapture: Bool = true
    @Published var systemAudioApps: [SystemAudioApp] = SystemAudioApp.defaults

    private var daemon: EdwardDaemon?

    init() {
        // Load saved language preferences
        let saved = UserDefaults.standard.stringArray(forKey: "selectedLanguages")
        if let saved = saved, !saved.isEmpty {
            selectedLanguages = Set(saved)
        }

        // Load recent transcripts from database
        let config = EdwardConfig.load()
        let storage = Storage(config: config)
        if let _ = try? storage.open(),
           let recent = try? storage.recent(limit: 50) {
            transcripts = recent.reversed()
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
        isLoading = true
        statusText = "Loading models..."
        errorMessage = nil

        var config = EdwardConfig.load()
        config.languages = Array(selectedLanguages)
        config.enableMicCapture = enableMicCapture
        config.enableSystemAudioCapture = enableSystemAudioCapture
        config.systemAudioApps = systemAudioApps

        // Recreate daemon if config changed
        if let existing = daemon, existing.configHash != config.configHash {
            existing.shutdown()
            daemon = nil
        }

        // Reuse existing daemon if already initialized
        if daemon == nil {
            let d = EdwardDaemon(config: config)
            self.daemon = d

            d.onTranscription = { [weak self] entry in
                Task { @MainActor in
                    self?.partialText = nil
                    self?.transcripts.append(entry)
                    if (self?.transcripts.count ?? 0) > 200 {
                        self?.transcripts.removeFirst()
                    }
                }
            }

            d.onPartialTranscription = { [weak self] text in
                Task { @MainActor in
                    self?.partialText = text
                }
            }

            d.onWordTimestampsReady = { [weak self] entryId, timestamps in
                Task { @MainActor in
                    if let idx = self?.transcripts.firstIndex(where: { $0.id == entryId }) {
                        self?.transcripts[idx].wordTimestamps = timestamps
                    }
                }
            }

            do {
                try await d.initialize()
            } catch {
                isLoading = false
                isRunning = false
                statusText = "Error"
                errorMessage = error.localizedDescription
                self.daemon = nil
                return
            }
        }

        do {
            try daemon!.start()
            isRunning = true
            isLoading = false
            let sources = daemon!.activeSources.joined(separator: " + ")
            statusText = "Listening (\(languageSummary)) — \(sources)"

            // Check for failed sources after system audio pipelines have had time to start
            let d = daemon!
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                await MainActor.run {
                    let failed = d.failedSources
                    if !failed.isEmpty {
                        let msgs = failed.map { "\($0.label): \($0.error)" }
                        self.errorMessage = msgs.joined(separator: "\n")
                    }
                    // Refresh active sources
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
        daemon?.stop()
        isRunning = false
        partialText = nil
        statusText = "Stopped"
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
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 400)
    }
}

// MARK: - Transcript Row

struct TranscriptRowView: View {
    let entry: TranscriptEntry
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
