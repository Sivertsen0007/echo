import Cocoa
import ApplicationServices

/// Phase 1 strategy: stash pasteboard, write text, send Cmd+V, restore pasteboard.
/// Works anywhere standard paste works (terminals, Slack, browser, native apps).
/// Phase 3 will add AXUIElement direct insert as a faster path.
final class TextInjector {
    static func ensureAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            NSLog("Accessibility permission required - grant in System Settings > Privacy & Security > Accessibility")
        }
    }

    func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        sendCmdV()

        // Restore pasteboard after a delay so the paste completes first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pb.clearContents()
            if let saved = saved {
                for (type, data) in saved {
                    pb.setData(data, forType: type)
                }
            }
        }
    }

    private func sendCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
