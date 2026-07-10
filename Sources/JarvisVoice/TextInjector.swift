import Cocoa
import ApplicationServices

/// Inserts text where the cursor is.
///
/// Two strategies, fastest-safe first:
///  1. AX direct-insert - set `kAXSelectedText` on the focused element. Works in
///     native text fields/areas (TextEdit, Notes, Mail, native app fields) with
///     no clipboard clobber and no paste race. We only attempt it on genuine
///     editable text roles that report the attribute settable, so we never
///     silently drop text into an element that ignores the write.
///  2. Cmd+V paste fallback - stash pasteboard, write text, send Cmd+V, restore.
///     Works anywhere paste works (browsers, Slack, Electron, terminals) - the
///     places AX insert can't reach.
final class TextInjector {
    static func ensureAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            NSLog("Accessibility permission required - grant in System Settings > Privacy & Security > Accessibility")
        }
    }

    func insert(_ text: String) {
        if insertViaAX(text) {
            NSLog("Inserted via AX direct-insert")
            return
        }
        insertViaPaste(text)
    }

    // MARK: - AX direct-insert

    /// Returns true only if the text was written into a settable editable-text
    /// element. Any uncertainty returns false so the caller falls back to paste.
    private func insertViaAX(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return false }
        // A focused UI element is always an AXUIElement.
        let element = focused as! AXUIElement

        // Restrict to real editable text roles - web/Electron controls that
        // merely echo a settable AXValue would accept the write without actually
        // inserting, silently losing the dictation.
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        guard let role = roleRef as? String, editableRoles.contains(role) else { return false }

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }

        // Setting selected text replaces the current selection, or inserts at the
        // caret when the selection is empty - i.e. exactly what typing would do.
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        return status == .success
    }

    // MARK: - Cmd+V paste fallback

    private func insertViaPaste(_ text: String) {
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
