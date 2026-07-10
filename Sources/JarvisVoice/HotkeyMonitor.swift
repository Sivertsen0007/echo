import Cocoa
import CoreGraphics

/// Modifier-only push-to-talk hotkeys.
///
/// Each option is identified by a stable string id so it can persist to
/// UserDefaults. The host (AppDelegate) decides what taps mean (double-tap =
/// start, single = stop).
enum HotkeyOption: String, CaseIterable, Identifiable {
    case fn
    case rightOption
    case rightCommand
    case rightShift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: return "Fn / Globe"
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightShift: return "Right Shift (⇧)"
        }
    }

    /// Whether the event's flags indicate this hotkey is currently held down.
    /// Each modifier has both a "main" mask (set whenever ANY left/right of
    /// that modifier is down) AND a "device" bit that differentiates left vs
    /// right. We require both so left-side presses don't fire.
    func isDown(_ flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        switch self {
        case .fn:
            return (raw & 0x800000) != 0 // NX_SECONDARYFNMASK
        case .rightOption:
            return flags.contains(.maskAlternate) && (raw & 0x040) != 0 // NX_DEVICERALTKEYMASK
        case .rightCommand:
            return flags.contains(.maskCommand) && (raw & 0x010) != 0 // NX_DEVICERCMDKEYMASK
        case .rightShift:
            return flags.contains(.maskShift) && (raw & 0x004) != 0 // NX_DEVICERSHIFTKEYMASK
        }
    }
}

/// Detects single taps of the selected modifier key (down + up within 600ms).
/// The host receives one `onTap` callback per release.
final class HotkeyMonitor {
    private let onTap: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyDown = false
    private var pressedAt: Date?
    private let tapMaxDuration: TimeInterval = 0.6

    /// Read/write so it can be changed at runtime without recreating the tap.
    var hotkey: HotkeyOption = .fn

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    func start() {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .flagsChanged {
                    monitor.handleFlagsChanged(event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            NSLog("Failed to create event tap. Grant Accessibility permission in System Settings.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("HotkeyMonitor started (\(hotkey.displayName) tap detection)")
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let isDown = hotkey.isDown(event.flags)
        if isDown && !keyDown {
            keyDown = true
            pressedAt = Date()
        } else if !isDown && keyDown {
            keyDown = false
            let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
            pressedAt = nil
            if held <= tapMaxDuration {
                DispatchQueue.main.async { self.onTap() }
            }
        }
    }
}
