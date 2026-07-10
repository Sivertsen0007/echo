import AppKit
import AVFoundation

/// Tiny system-tone cues so you know when recording starts/stops without
/// looking at the menubar. Uses the built-in system sounds; no asset files.
enum AudioFeedback {
    private static let startSound: NSSound? = NSSound(named: NSSound.Name("Tink"))
    private static let stopSound: NSSound? = NSSound(named: NSSound.Name("Pop"))
    private static let errorSound: NSSound? = NSSound(named: NSSound.Name("Funk"))

    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: "echo.sound.enabled") as? Bool ?? true
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "echo.sound.enabled")
    }

    static var isEnabled: Bool { enabled }

    static func playStart() { if enabled { startSound?.play() } }
    static func playStop()  { if enabled { stopSound?.play() } }
    static func playError() { if enabled { errorSound?.play() } }
}
