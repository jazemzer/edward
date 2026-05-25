import SwiftUI
import AppKit

final class CopilotOverlayController {
    private var panel: NSPanel?
    private let engine: CopilotEngine

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
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let panelWidth: CGFloat = 320
        let panelHeight: CGFloat = screen.visibleFrame.height - 40
        let panelX = screen.visibleFrame.maxX - panelWidth - 12
        let panelY = screen.visibleFrame.minY + 20

        let panel = NSPanel(
            contentRect: NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight),
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

        let hostingView = NSHostingView(rootView: CopilotOverlayView(engine: engine))
        panel.contentView = hostingView

        self.panel = panel
    }
}

struct CopilotOverlayView: View {
    @ObservedObject var engine: CopilotEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider().background(Color.white.opacity(0.2))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = engine.state.error {
                        errorView(error)
                    } else if engine.state.lastUpdated == nil && !engine.state.isProcessing {
                        waitingView
                    } else {
                        contentView
                    }
                }
                .padding(16)
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
            } else if let updated = engine.state.lastUpdated {
                Text(timeAgo(updated))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var waitingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title)
                .foregroundColor(.white.opacity(0.4))
            Text("Listening...")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
            Text("Copilot will activate after the first update interval")
                .font(.caption)
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
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

    private func sectionView(title: String, icon: String, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                Text(title.uppercased())
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(color)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\u{2022}")
                        .foregroundColor(.white.opacity(0.5))
                    Text(item)
                        .font(.callout)
                        .foregroundColor(.white.opacity(0.9))
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
            Button(action: {
                Task { await engine.forceUpdate() }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .disabled(engine.state.isProcessing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

    private func durationString(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        if minutes == 0 { return "\(seconds)s" }
        return "\(minutes)m \(seconds)s"
    }
}
