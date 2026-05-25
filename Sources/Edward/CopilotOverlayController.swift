import SwiftUI
import AppKit

final class CopilotOverlayController {
    private var panel: NSPanel?
    private let engine: CopilotEngine
    var onClose: (() -> Void)?

    private static let frameKey = "copilotPanelFrame"

    var isVisible: Bool { panel?.isVisible ?? false }

    init(engine: CopilotEngine) {
        self.engine = engine
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            createPanel()
        }
        panel?.orderFront(nil)
    }

    func hide() {
        saveFrame()
        panel?.orderOut(nil)
    }

    private func saveFrame() {
        guard let frame = panel?.frame else { return }
        let dict: [String: CGFloat] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height]
        UserDefaults.standard.set(dict, forKey: Self.frameKey)
    }

    private func savedFrame() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.frameKey) as? [String: CGFloat] else { return nil }
        guard let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"] else { return nil }
        let rect = NSRect(x: x, y: y, width: w, height: h)
        // Validate the frame is still on a visible screen
        for screen in NSScreen.screens {
            if screen.frame.intersects(rect) {
                return rect
            }
        }
        return nil
    }

    private func createPanel() {
        let frame: NSRect
        if let saved = savedFrame() {
            frame = saved
        } else {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let panelWidth: CGFloat = 320
            let panelHeight: CGFloat = screen.visibleFrame.height - 40
            let panelX = screen.visibleFrame.maxX - panelWidth - 12
            let panelY = screen.visibleFrame.minY + 20
            frame = NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
        }

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: nil) { [weak self] _ in
            self?.saveFrame()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: nil) { [weak self] _ in
            self?.saveFrame()
        }

        let hostingView = NSHostingView(rootView: CopilotOverlayView(engine: engine, onClose: { [weak self] in
            self?.hide()
            self?.onClose?()
        }))
        panel.contentView = hostingView

        self.panel = panel
    }
}

struct CopilotOverlayView: View {
    @ObservedObject var engine: CopilotEngine
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider().background(Color.white.opacity(0.2))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = engine.state.error {
                        errorView(error)
                    } else if engine.state.lastUpdated == nil && engine.state.transcripts.isEmpty && engine.state.partialTranscription == nil {
                        waitingView
                    } else {
                        if engine.state.lastUpdated != nil {
                            contentView
                            Divider().background(Color.white.opacity(0.15))
                        }
                        transcriptView
                    }
                    }
                    .padding(16)
                    .textSelection(.enabled)
                }
            Divider().background(Color.white.opacity(0.2))
            footerView
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.82))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundColor(.yellow)
            Text("Edward Copilot")
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
            if engine.state.isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
            } else {
                Button(action: { Task { await engine.forceUpdate() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Force update now")
            }
            Button(action: { onClose?() }) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var waitingView: some View {
        VStack(spacing: 12) {
            if engine.state.isProcessing {
                ProgressView()
                    .controlSize(.regular)
                    .colorScheme(.dark)
                Text("Analyzing...")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            } else {
                Image(systemName: "waveform")
                    .font(.title)
                    .foregroundColor(.white.opacity(0.4))
                if let status = engine.state.statusMessage {
                    Text(status)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                } else {
                    Text("Waiting for speech...")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                }
                if engine.state.segmentCount > 0 {
                    Text("First analysis after ~10s of speech")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))
                } else {
                    Text("Speak to start the copilot")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.orange.opacity(0.9))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !engine.state.keyPoints.isEmpty {
                sectionView(title: "Key Points", icon: "list.bullet", items: engine.state.keyPoints, color: .cyan)
            }
            if !engine.state.suggestedQuestions.isEmpty {
                sectionView(title: "Questions to Ask", icon: "questionmark.bubble", items: engine.state.suggestedQuestions, color: .green)
            }
            if !engine.state.actionItems.isEmpty {
                sectionView(title: "Action Items", icon: "checkmark.circle", items: engine.state.actionItems, color: .orange)
            }
        }
    }

    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundColor(.purple)
                Text("LIVE TRANSCRIPT")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.purple)
                Spacer()
                Button(action: {
                    let text = engine.state.transcripts.map { $0.text }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Copy transcript")
                .disabled(engine.state.transcripts.isEmpty)
            }

            let hasApple = !engine.state.appleTranscripts.isEmpty || engine.state.applePartialTranscription != nil

            if hasApple {
                HStack(alignment: .top, spacing: 8) {
                    // Qwen column
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Qwen3 ASR")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.cyan)
                        ForEach(engine.state.transcripts) { segment in
                            Text(segment.text)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let partial = engine.state.partialTranscription, !partial.isEmpty {
                            HStack(alignment: .top, spacing: 4) {
                                Circle().fill(Color.red).frame(width: 5, height: 5).padding(.top, 4)
                                Text(partial)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().background(Color.white.opacity(0.2))

                    // Apple column
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Speech")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                        ForEach(engine.state.appleTranscripts) { segment in
                            Text(segment.text)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let partial = engine.state.applePartialTranscription, !partial.isEmpty {
                            HStack(alignment: .top, spacing: 4) {
                                Circle().fill(Color.green).frame(width: 5, height: 5).padding(.top, 4)
                                Text(partial)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // Single column (Qwen only)
                ForEach(engine.state.transcripts) { segment in
                    HStack(alignment: .top, spacing: 8) {
                        Text(timeLabel(segment.timestamp))
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.35))
                            .frame(width: 36, alignment: .trailing)
                        Text(segment.text)
                            .font(.callout)
                            .foregroundColor(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .id(segment.id)
                }
                if let partial = engine.state.partialTranscription, !partial.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                        Text(partial)
                            .font(.callout)
                            .foregroundColor(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .animation(.none, value: partial)
                    }
                }
            }
        }
    }

    private func sectionView(title: String, icon: String, items: [CopilotItem], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                Text(title.uppercased())
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(color)
                Spacer()
                Button(action: {
                    let text = items.map { "\u{2022} \($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Copy \(title)")
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\u{2022}")
                        .foregroundColor(.white.opacity(item.isStrikethrough ? 0.3 : 0.5))
                    Text(item.text)
                        .font(.callout)
                        .foregroundColor(.white.opacity(item.isStrikethrough ? 0.4 : 0.9))
                        .strikethrough(item.isStrikethrough, color: .white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footerView: some View {
        HStack {
            Text("\(engine.state.segmentCount) segments")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))
            Text("\u{2022}")
                .foregroundColor(.white.opacity(0.3))
            Text(durationString(engine.state.listeningDuration))
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "m:ss"
        return formatter.string(from: date)
    }

    private func partialTail(_ text: String) -> String {
        guard text.count > 120 else { return text }
        let tail = text.suffix(120)
        if let space = tail.firstIndex(of: " ") {
            return "..." + tail[tail.index(after: space)...]
        }
        return "..." + tail
    }

    private func durationString(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        if minutes == 0 { return "\(seconds)s" }
        return "\(minutes)m \(seconds)s"
    }
}
