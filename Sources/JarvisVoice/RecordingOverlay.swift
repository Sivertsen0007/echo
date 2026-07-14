import Cocoa
import SwiftUI

/// A small floating pill near the bottom of the screen that shows a live
/// waveform while recording and a spinner while transcribing - so you can see
/// at a glance that Echo is listening (Wispr Flow style).
///
/// The panel is a non-activating floating panel: it never becomes key, so the
/// text field you are dictating into keeps focus and the paste still lands
/// where your cursor was.
final class RecordingOverlay {
    static let shared = RecordingOverlay()

    enum Phase: Equatable { case listening, processing, error(String) }

    private let model = OverlayModel()
    private var panel: NSPanel?
    private var autoHide: DispatchWorkItem?

    private init() {}

    func showListening() {
        autoHide?.cancel()
        ensurePanel()
        model.reset()
        model.phase = .listening
        reposition()
        panel?.orderFrontRegardless()
    }

    /// New audio level (0...1). Pushed into the scrolling waveform history.
    func updateLevel(_ level: Float) {
        model.push(level)
    }

    func showProcessing() {
        autoHide?.cancel()
        ensurePanel()
        model.phase = .processing
        reposition()
        panel?.orderFrontRegardless()
    }

    /// Brief error pill ("No speech detected", "Network error") that hides
    /// itself. Failures used to be invisible - the overlay just vanished.
    func showError(_ message: String) {
        autoHide?.cancel()
        ensurePanel()
        model.phase = .error(message)
        reposition()
        panel?.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func hide() {
        autoHide?.cancel()
        panel?.orderOut(nil)
    }

    // MARK: - Panel plumbing

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = NSSize(width: 220, height: 56)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        panel = p
    }

    /// Bottom-centre of whichever screen currently has the mouse.
    private func reposition() {
        guard let panel = panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Observable state driving the overlay SwiftUI view.
final class OverlayModel: ObservableObject {
    @Published var phase: RecordingOverlay.Phase = .listening
    /// Scrolling history of recent audio levels; newest at the end.
    @Published var levels: [Float] = Array(repeating: 0, count: barCount)

    static let barCount = 26

    func reset() {
        levels = Array(repeating: 0, count: Self.barCount)
    }

    func push(_ level: Float) {
        var next = levels
        next.removeFirst()
        next.append(max(0, min(1, level)))
        levels = next
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .listening:
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Waveform(levels: model.levels)
                    .frame(height: 24)
                Text("Listening")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            case .processing:
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(6)
    }
}

/// A scrolling bar waveform. Each bar's height follows the level history, so as
/// new samples arrive the shape scrolls left - lively while you speak, flat
/// when silent.
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let spacing: CGFloat = 2
            let barWidth = max(1.5, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: barWidth,
                               height: max(3, CGFloat(level) * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .animation(.easeOut(duration: 0.08), value: levels)
        }
        .frame(width: 96)
    }
}
