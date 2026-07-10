import Cocoa
import ApplicationServices

/// After we inject transcribed text, watch the focused element for ~8s.
/// If the user edits the inserted text, diff and offer to learn it as a
/// replacement.
///
/// Works in any AX-compliant text field (Notes, Mail, Slack, browsers).
/// Will silently skip when the focused element doesn't expose AXValue.
final class CorrectionDetector {
    static let shared = CorrectionDetector()
    private var pendingTimer: DispatchWorkItem?
    private let observationDelay: TimeInterval = 8

    /// Call right after injector.insert(text). We wait 400ms for the paste to
    /// land in the AX tree, snapshot, then wait `observationDelay` and check.
    func observeAfterInjection(_ insertedText: String) {
        pendingTimer?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.beginObservation(insertedText)
        }
    }

    private func beginObservation(_ insertedText: String) {
        guard let element = Self.focusedAXElement() else { return }
        guard let initial = Self.value(of: element) else { return }
        // Make sure our text actually landed in this field before we promise
        // to monitor it.
        guard initial.contains(insertedText) else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.evaluate(element: element, initial: initial, inserted: insertedText)
        }
        pendingTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + observationDelay, execute: work)
    }

    private func evaluate(element: AXUIElement, initial: String, inserted: String) {
        guard let final = Self.value(of: element), final != initial else { return }
        guard let diff = Self.diff(from: initial, to: final) else { return }

        // Sanity gates: only suggest "word-shaped" corrections.
        let oldT = diff.oldMiddle.trimmingCharacters(in: .whitespacesAndNewlines)
        let newT = diff.newMiddle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldT.isEmpty, !newT.isEmpty else { return }
        guard oldT.count <= 60, newT.count <= 60 else { return }
        guard !oldT.contains("\n"), !newT.contains("\n") else { return }
        guard oldT.lowercased() != newT.lowercased() else { return }
        // Ignore tiny corrections (single character) - too noisy.
        guard oldT.count >= 2 || newT.count >= 2 else { return }
        // Ignore if `oldT` did not actually appear inside our inserted text.
        // This rules out the user editing unrelated content elsewhere.
        guard inserted.range(of: oldT, options: .caseInsensitive) != nil else { return }

        DispatchQueue.main.async {
            self.promptToLearn(oldText: oldT, newText: newT)
        }
    }

    private func promptToLearn(oldText: String, newText: String) {
        let alert = NSAlert()
        alert.messageText = "Learn this correction?"
        alert.informativeText = "Next time you say \"\(oldText)\", Echo will write \"\(newText)\"."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            VocabStore.shared.addReplacement(spoken: oldText, write: newText)
        }
    }

    // MARK: - AX helpers

    static func focusedAXElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide,
                                                kAXFocusedUIElementAttribute as CFString,
                                                &focused)
        guard err == .success, let raw = focused else { return nil }
        return (raw as! AXUIElement)
    }

    static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success, let str = value as? String else { return nil }
        return str
    }

    // MARK: - Diff (longest common prefix + suffix)

    struct Diff { let oldMiddle: String; let newMiddle: String }

    static func diff(from a: String, to b: String) -> Diff? {
        let aArr = Array(a), bArr = Array(b)
        var prefix = 0
        while prefix < aArr.count && prefix < bArr.count && aArr[prefix] == bArr[prefix] {
            prefix += 1
        }
        var suffix = 0
        let aRem = aArr.count - prefix
        let bRem = bArr.count - prefix
        while suffix < aRem && suffix < bRem
              && aArr[aArr.count - 1 - suffix] == bArr[bArr.count - 1 - suffix] {
            suffix += 1
        }
        let oldMid = String(aArr[prefix..<(aArr.count - suffix)])
        let newMid = String(bArr[prefix..<(bArr.count - suffix)])
        if oldMid.isEmpty && newMid.isEmpty { return nil }
        return Diff(oldMiddle: oldMid, newMiddle: newMid)
    }
}
