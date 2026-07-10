import Cocoa
import SwiftUI
import AVFoundation
import ApplicationServices

/// Detects first-run state and shows a setup window walking through:
///   1. Welcome
///   2. Microphone permission
///   3. Accessibility permission
///   4. OpenAI API key
///   5. Done - try a dictation
final class OnboardingController: NSObject, NSWindowDelegate {
    static let shared = OnboardingController()
    private var window: NSWindow?

    var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "echo.onboarding.completed")
    }

    func markComplete() {
        UserDefaults.standard.set(true, forKey: "echo.onboarding.completed")
    }

    func showIfNeeded() {
        if !hasCompletedOnboarding {
            show()
        }
    }

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let root = NSHostingController(rootView: OnboardingView(onClose: { [weak self] in
            self?.markComplete()
            self?.window?.close()
            self?.window = nil
        }))
        let w = NSWindow(contentViewController: root)
        w.setContentSize(NSSize(width: 640, height: 520))
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.title = "Welcome to Echo"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

struct OnboardingView: View {
    let onClose: () -> Void

    @State private var step: Int = 0
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axGranted = AXIsProcessTrusted()
    @State private var hasKey = ConfigStore.shared.hasKeyForActiveProvider
    @State private var keyInput = ""
    @State private var selectedProvider: TranscriptionProvider = ConfigStore.shared.activeProvider

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
            ScrollView { content.padding(28) }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { startPolling() }
    }

    // MARK: Step indicator
    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.top, 18)
    }

    // MARK: Steps
    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcomeStep
        case 1: micStep
        case 2: axStep
        case 3: keyStep
        default: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "mic.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.top, 20)
            Text("Welcome to Echo").font(.system(size: 28, weight: .semibold))
            Text("A voice-to-text app that learns your vocabulary.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                bullet("Double-tap Fn to start dictating")
                bullet("Single tap Fn to stop")
                bullet("Text is inserted wherever your cursor is")
                bullet("Echo learns your custom words over time")
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private var micStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle.fill").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Microphone access").font(.title2.weight(.semibold))
            Text("Echo needs to record your voice to transcribe it. Audio never leaves this machine except for the request to OpenAI.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            statusBadge(granted: micGranted)
            if !micGranted {
                Button("Grant microphone access") {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async { micGranted = granted }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var axStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fingers.spread.fill").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Accessibility access").font(.title2.weight(.semibold))
            Text("Echo needs Accessibility permission to detect the Fn hotkey, paste text into other apps, and learn corrections you make.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            statusBadge(granted: axGranted)
            if !axGranted {
                VStack(spacing: 8) {
                    Button("Open System Settings") {
                        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(opts)
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("After enabling, quit and reopen Echo for the change to take effect.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var keyStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Transcription provider").font(.title2.weight(.semibold))
            Text("Echo sends audio to a Whisper API for transcription. Pick a provider and paste your key.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)

            Picker("Provider", selection: $selectedProvider) {
                ForEach(TranscriptionProvider.allCases) { p in
                    Text("\(p.displayName) - $\(String(format: "%.4f", p.pricePerMinute))/min").tag(p)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)

            Text(selectedProvider == .groq
                ? "Groq is fastest and cheapest. Free signup at console.groq.com."
                : "OpenAI is the reference Whisper API. Requires billing on your account.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: 460)

            statusBadge(granted: hasKey, grantedLabel: "Configured", missingLabel: "Not configured")

            VStack(alignment: .leading, spacing: 8) {
                SecureField(selectedProvider == .openai ? "sk-..." : "gsk_...", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save key") { saveKey() }
                        .buttonStyle(.borderedProminent)
                        .disabled(keyInput.isEmpty)
                    Spacer()
                    Link("Get a \(selectedProvider.displayName) key", destination: selectedProvider.signupURL)
                }
            }
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("You're set up").font(.title2.weight(.semibold))
            Text("Click 🎙 in the menubar to open Echo any time.\n\nTry a dictation now: double-tap Fn in any text field.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Footer
    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            if step < 4 {
                Button("Continue") { step += 1 }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            } else {
                Button("Get started") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private var canContinue: Bool {
        switch step {
        case 1: return micGranted
        case 2: return axGranted
        case 3: return hasKey
        default: return true
        }
    }

    // MARK: Helpers
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark").foregroundStyle(.tint)
            Text(text)
        }
    }

    private func statusBadge(granted: Bool, grantedLabel: String = "Granted", missingLabel: String = "Not granted yet") -> some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .secondary)
            Text(granted ? grantedLabel : missingLabel)
                .foregroundStyle(granted ? .green : .secondary)
        }
        .padding(.vertical, 6).padding(.horizontal, 12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(Capsule())
    }

    private func saveKey() {
        ConfigStore.shared.setProvider(selectedProvider)
        ConfigStore.shared.setApiKey(keyInput, for: selectedProvider)
        hasKey = ConfigStore.shared.hasKeyForActiveProvider
        keyInput = ""
    }

    /// Permissions change behind our back (user toggles in System Settings),
    /// so refresh the badge every second while onboarding is open.
    private func startPolling() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            DispatchQueue.main.async {
                micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                axGranted = AXIsProcessTrusted()
                hasKey = ConfigStore.shared.hasKeyForActiveProvider
            }
            if step >= 4 { timer.invalidate() }
        }
    }
}
