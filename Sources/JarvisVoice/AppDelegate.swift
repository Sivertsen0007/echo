import Cocoa

/// Hold-to-talk state machine:
///   idle      -- hotkey down --> recording (records while held)
///   recording -- hotkey up   --> processing -> idle
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotkey: HotkeyMonitor!
    private var recorder: AudioRecorder!
    private var transcriber: Transcriber!
    private var injector: TextInjector!

    private enum State { case idle, recording, processing }
    private var state: State = .idle

    private lazy var menubarIcon: NSImage? = {
        guard let path = Bundle.main.path(forResource: "menubar-icon", ofType: "png"),
              let image = NSImage(contentsOfFile: path) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    private var pulseTimer: Timer?
    private var pulseOn = false
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var maxRecordingTimer: Timer?
    private var processingWatchdog: DispatchWorkItem?

    /// Hard cap on one dictation. Also the recovery path when the hotkey
    /// release event is lost (tap disabled mid-hold): without it the app
    /// would record forever.
    private let maxRecordingSeconds: TimeInterval = 300
    /// Absolute ceiling on the processing phase. The network layer has its
    /// own timeouts; this is the safety net that guarantees the app always
    /// returns to idle and accepts the next dictation.
    private let processingWatchdogSeconds: TimeInterval = 60
    private let minRecordingSeconds: TimeInterval = 0.3
    /// Peak level (0...1, ~-50dB..0dB) a recording must reach to be treated
    /// as speech. 0.1 = -45 dB: safely below any real speech, above room hum.
    private let silencePeakThreshold: Float = 0.1

    private func startPulsing() {
        stopPulsing()
        pulseOn = false
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pulseOn.toggle()
            self.statusItem.button?.alphaValue = self.pulseOn ? 0.35 : 1.0
        }
    }

    private func stopPulsing() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusItem.button?.alphaValue = 1.0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIdle()
        // Left-click opens the main window directly; right-click (or option-click) shows the menu.
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        buildStatusMenu()

        _ = VocabStore.shared // force-create vocab.json on startup
        _ = ConfigStore.shared // force-load config.json
        _ = StyleStore.shared // force-create style.json on startup
        _ = SnippetsStore.shared // force-create snippets.json on startup
        _ = TransformsStore.shared // force-create transforms.json on startup
        _ = Database.shared   // force-create db.sqlite + run migrations on startup
        _ = PostProcessor.shared // discover claude CLI path on startup
        recorder = AudioRecorder()
        recorder.onLevel = { level in RecordingOverlay.shared.updateLevel(level) }
        transcriber = Transcriber()
        injector = TextInjector()

        hotkey = HotkeyMonitor(
            onPress: { [weak self] in self?.handlePress() },
            onRelease: { [weak self] in self?.handleRelease() })
        if let saved = UserDefaults.standard.string(forKey: "echo.hotkey"),
           let opt = HotkeyOption(rawValue: saved) {
            hotkey.hotkey = opt
        }
        hotkey.start()
        NotificationCenter.default.addObserver(self, selector: #selector(hotkeyChanged),
                                               name: .hotkeyChanged, object: nil)

        recorder.requestPermission { granted in
            if !granted { NSLog("Microphone permission denied") }
        }
        recorder.prewarm()
        TextInjector.ensureAccessibilityPermission()

        // Re-validate the pieces that die across sleep/wake: the event tap
        // can come back disabled, and the prewarmed engine may point at a
        // device that vanished while the lid was closed.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            NSLog("System woke - revalidating hotkey tap and audio engine")
            self?.hotkey.ensureEnabled()
            self?.recorder.prewarm()
        }

        // Make sure Echo comes back after a reboot. Registered once; if the
        // user later turns the login item off in Settings we respect that.
        if !UserDefaults.standard.bool(forKey: "echo.loginItemAutoregistered") {
            UserDefaults.standard.set(true, forKey: "echo.loginItemAutoregistered")
            if !LoginItem.isEnabled {
                do {
                    try LoginItem.setEnabled(true)
                    NSLog("Registered Echo as a login item")
                } catch {
                    NSLog("Could not register login item: \(error)")
                }
            }
        }

        // Show onboarding on first run only.
        OnboardingController.shared.showIfNeeded()
    }

    /// Hotkey pressed: start recording if we are idle. Presses during
    /// processing are ignored so a fresh recording can't stomp an in-flight one.
    private func handlePress() {
        guard state == .idle else { return }
        startRecording()
    }

    /// Hotkey released: stop the recording we started on press.
    private func handleRelease() {
        guard state == .recording else { return }
        stopRecording()
    }

    private func startRecording() {
        guard recorder.start() else {
            showTransientError("Microphone unavailable")
            return
        }
        state = .recording
        setRecording()
        AudioFeedback.playStart()

        maxRecordingTimer?.invalidate()
        maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingSeconds,
                                                 repeats: false) { [weak self] _ in
            guard let self = self, self.state == .recording else { return }
            NSLog("Max recording duration reached - auto-stopping")
            self.hotkey.resetKeyState()
            self.stopRecording()
        }
    }

    /// Every failure funnels through here: audible cue, a short-lived overlay
    /// message, then back to idle so the next dictation can start.
    private func showTransientError(_ message: String) {
        processingWatchdog?.cancel()
        maxRecordingTimer?.invalidate(); maxRecordingTimer = nil
        AudioFeedback.playError()
        state = .idle
        setIdle()
        RecordingOverlay.shared.showError(message)
        NSLog("Dictation failed: \(message)")
    }

    private static func errorMessage(for failure: Transcriber.Failure?) -> String {
        switch failure {
        case .noKey: return "No API key - open Echo settings"
        case .badKey: return "API key rejected"
        case .rateLimited: return "Rate limited - try again"
        case .serverError(let code): return "Provider error (\(code))"
        case .network: return "Network error - recording kept"
        case .empty, nil: return "No speech detected"
        }
    }

    private func stopRecording() {
        state = .processing
        setProcessing()
        AudioFeedback.playStop()
        maxRecordingTimer?.invalidate(); maxRecordingTimer = nil

        // Watchdog: whatever goes wrong below (hung request, bug in a
        // completion chain), the app must come back to idle.
        processingWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .processing else { return }
            NSLog("Processing watchdog fired - forcing back to idle")
            self.showTransientError("Timed out - try again")
        }
        processingWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + processingWatchdogSeconds,
                                      execute: watchdog)

        // Capture the focused app NOW, before we steal focus with the alert /
        // before injection ambiguity.
        let focused = NSWorkspace.shared.frontmostApplication
        let appBundle = focused?.bundleIdentifier
        let appName = focused?.localizedName

        recorder.stop { [weak self] url, duration, peak in
            guard let self = self else { return }
            guard let url = url, duration >= self.minRecordingSeconds else {
                if let url = url { try? FileManager.default.removeItem(at: url) }
                NSLog("Discarded short recording (\(duration)s)")
                Database.shared.logTranscription(
                    rawText: "", finalText: "", audioDuration: duration, latency: 0,
                    appBundleId: appBundle, appName: appName, discarded: true)
                DispatchQueue.main.async {
                    self.showTransientError("Too short - hold while speaking")
                }
                return
            }
            // Silence gate: audio that never rose above the noise floor would
            // only make the API hallucinate or echo the vocab prompt back.
            guard peak >= self.silencePeakThreshold else {
                try? FileManager.default.removeItem(at: url)
                NSLog("Discarded silent recording (peak \(peak))")
                Database.shared.logTranscription(
                    rawText: "", finalText: "", audioDuration: duration, latency: 0,
                    appBundleId: appBundle, appName: appName, discarded: true)
                DispatchQueue.main.async {
                    self.showTransientError("No speech detected")
                }
                return
            }
            let transcribeStart = Date()
            self.transcriber.transcribe(audioURL: url) { result in
                let latency = Date().timeIntervalSince(transcribeStart)
                let raw = result.text ?? ""
                let providerId = result.provider.rawValue
                let modelId = result.model
                guard !raw.isEmpty else {
                    DispatchQueue.main.async {
                        Database.shared.logTranscription(
                            rawText: "", finalText: "", audioDuration: duration,
                            latency: latency, appBundleId: appBundle, appName: appName,
                            styleUsed: nil, stylePromptChars: 0,
                            provider: providerId, model: modelId, discarded: true)
                        self.showTransientError(Self.errorMessage(for: result.failure))
                    }
                    return
                }
                // One-shot transform overrides the default Style for this recording only.
                let override = TransformsStore.shared.consumeOverride()
                let stylePreset: StylePreset
                if let o = override {
                    stylePreset = StylePreset(id: "transform-\(o.id.uuidString)",
                                              name: o.name, description: o.description,
                                              systemPrompt: o.systemPrompt)
                } else {
                    stylePreset = StyleStore.shared.defaultStyle
                }
                PostProcessor.shared.apply(style: stylePreset, to: raw) { styled in
                    let withVocab = VocabStore.shared.applyReplacements(styled, currentAppBundleId: appBundle)
                    let corrected = SnippetsStore.shared.apply(to: withVocab)
                    Database.shared.logTranscription(
                        rawText: raw, finalText: corrected, audioDuration: duration,
                        latency: latency, appBundleId: appBundle, appName: appName,
                        styleUsed: stylePreset.id,
                        stylePromptChars: stylePreset.systemPrompt.count,
                        provider: providerId, model: modelId,
                        discarded: corrected.isEmpty)
                    guard !corrected.isEmpty else {
                        self.showTransientError("Nothing to insert")
                        return
                    }
                    self.injector.insert(corrected)
                    CorrectionDetector.shared.observeAfterInjection(corrected)
                    self.processingWatchdog?.cancel()
                    self.state = .idle
                    self.setIdle()
                }
            }
        }
    }

    @objc private func showAddCorrection() {
        let alert = NSAlert()
        alert.messageText = "Add Correction"
        alert.informativeText = "When I say the first phrase, write the second."

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 64))
        let spokenField = NSTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        spokenField.placeholderString = "What I say (e.g. InSync)"
        let targetField = NSTextField(frame: NSRect(x: 0, y: 4, width: 300, height: 24))
        targetField.placeholderString = "What to write (e.g. Inseanq)"
        container.addSubview(spokenField)
        container.addSubview(targetField)
        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            VocabStore.shared.addReplacement(spoken: spokenField.stringValue,
                                             write: targetField.stringValue)
        }
    }

    private var statusMenu: NSMenu?

    private func buildStatusMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Echo", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let openMain = NSMenuItem(title: "Open Echo", action: #selector(openMainWindow), keyEquivalent: "o")
        openMain.target = self
        menu.addItem(openMain)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Hold hotkey to record - release to insert", action: nil, keyEquivalent: ""))
        let transformsItem = NSMenuItem(title: "Use for next recording", action: nil, keyEquivalent: "")
        let transformsSub = NSMenu()
        transformsSub.delegate = self
        transformsSub.identifier = NSUserInterfaceItemIdentifier("transformsSubmenu")
        transformsItem.submenu = transformsSub
        menu.addItem(transformsItem)
        menu.addItem(.separator())
        let addCorrection = NSMenuItem(title: "Add Correction...", action: #selector(showAddCorrection), keyEquivalent: "")
        addCorrection.target = self
        menu.addItem(addCorrection)
        let openVocab = NSMenuItem(title: "Open vocab.json", action: #selector(openVocabFile), keyEquivalent: "")
        openVocab.target = self
        menu.addItem(openVocab)
        menu.addItem(.separator())
        let stats = NSMenuItem(title: "Show Stats", action: #selector(showStats), keyEquivalent: "")
        stats.target = self
        menu.addItem(stats)
        let onboarding = NSMenuItem(title: "Show Welcome Tour", action: #selector(showOnboarding), keyEquivalent: "")
        onboarding.target = self
        menu.addItem(onboarding)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusMenu = menu
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isContextual = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.option) == true
            || event?.modifierFlags.contains(.control) == true
        if isContextual, let menu = statusMenu {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            // Detach menu so the next plain click opens the window again.
            DispatchQueue.main.async { [weak self] in self?.statusItem.menu = nil }
        } else {
            MainWindowController.shared.show()
        }
    }

    @objc private func openMainWindow() {
        MainWindowController.shared.show()
    }

    @objc private func hotkeyChanged() {
        if let saved = UserDefaults.standard.string(forKey: "echo.hotkey"),
           let opt = HotkeyOption(rawValue: saved) {
            hotkey.hotkey = opt
            NSLog("Hotkey switched to \(opt.displayName)")
        }
    }

    @objc private func showOnboarding() {
        OnboardingController.shared.show()
    }

    // Populate the Transforms submenu lazily so it stays in sync with the store.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier?.rawValue == "transformsSubmenu" else { return }
        menu.removeAllItems()
        let store = TransformsStore.shared
        let current = store.nextRecordingOverride

        let defaultItem = NSMenuItem(title: "(Default: \(StyleStore.shared.defaultStyle.name))",
                                     action: #selector(clearTransformOverride), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.state = current == nil ? .on : .off
        menu.addItem(defaultItem)
        menu.addItem(.separator())
        for transform in store.data.transforms {
            let item = NSMenuItem(title: transform.name, action: #selector(setTransformOverride(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = transform
            item.state = (current?.id == transform.id) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func setTransformOverride(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? Transform else { return }
        TransformsStore.shared.nextRecordingOverride = t
        updateStatusTitle()
    }

    @objc private func clearTransformOverride() {
        TransformsStore.shared.nextRecordingOverride = nil
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        guard state == .idle else { return }
        if let t = TransformsStore.shared.nextRecordingOverride {
            statusItem.button?.title = "🎙 \(t.name)"
        } else {
            statusItem.button?.title = "🎙"
        }
    }

    @objc private func showStats() {
        let totals = Database.shared.totals()
        let streak = Database.shared.dayStreak()
        let recent = Database.shared.recentTranscriptions(limit: 5)
        let recentLines = recent.map {
            "  \($0.createdAt.prefix(16))  [\($0.wordCount)w]  \($0.finalText.prefix(60))"
        }.joined(separator: "\n")
        let wpm = totals.seconds > 0 ? Double(totals.words) / (totals.seconds / 60.0) : 0

        let alert = NSAlert()
        alert.messageText = "Echo Stats"
        alert.informativeText = """
        Total words:        \(totals.words)
        Transcriptions:     \(totals.transcriptions)
        Recording time:     \(String(format: "%.1f min", totals.seconds / 60))
        Average WPM:        \(String(format: "%.0f", wpm))
        Day streak:         \(streak)

        Recent:
        \(recentLines.isEmpty ? "  (none yet)" : recentLines)
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openVocabFile() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis-voice/vocab.json")
        NSWorkspace.shared.open(url)
    }

    private func setIdle() {
        stopPulsing()
        RecordingOverlay.shared.hide()
        statusItem.button?.image = menubarIcon
        statusItem.button?.contentTintColor = nil
        if let t = TransformsStore.shared.nextRecordingOverride {
            statusItem.button?.title = " \(t.name)"
        } else {
            statusItem.button?.title = ""
        }
    }

    private func setRecording() {
        RecordingOverlay.shared.showListening()
        statusItem.button?.image = menubarIcon
        statusItem.button?.contentTintColor = .systemRed
        recordingStartedAt = Date()
        statusItem.button?.title = " 0s"
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, let started = self.recordingStartedAt else { return }
            let s = Int(Date().timeIntervalSince(started))
            self.statusItem.button?.title = " \(s)s"
        }
        startPulsing()
    }

    private func setProcessing() {
        stopPulsing()
        RecordingOverlay.shared.showProcessing()
        recordingTimer?.invalidate(); recordingTimer = nil
        recordingStartedAt = nil
        statusItem.button?.image = menubarIcon
        statusItem.button?.contentTintColor = .systemOrange
        statusItem.button?.title = ""
    }
}
