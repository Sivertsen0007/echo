import Foundation

/// Persistent vocabulary store at ~/.jarvis-voice/vocab.json.
///
/// Two parts:
///   - `replacements`: case-insensitive word/phrase substitutions applied
///     AFTER transcription. This is the reliable path - "InSync" -> "Inseanq".
///   - `terms`: bias words sent to Whisper's `prompt` field to nudge the
///     model toward correct spelling on its own.
///
/// Both are user-editable via the menubar "Add correction" action or by
/// editing the JSON directly.
/// A replacement that may be scoped to a single app bundle id.
struct ScopedReplacement: Codable, Hashable {
    var spoken: String
    var target: String
    var appBundleId: String?   // nil = global, otherwise restricted to that app
    var appName: String?       // for display only
}

struct VocabData: Codable {
    var replacements: [String: String] // legacy: global, kept for backward compat
    var terms: [String]
    var scopedReplacements: [ScopedReplacement]?

    static let defaultData = VocabData(
        replacements: [
            "InSync": "Inseanq",
            "in sync": "Inseanq",
            "Insync": "Inseanq"
        ],
        terms: ["Mathias", "Master Liveaboards", "MLUK", "Inseanq", "Jarvis", "Claude Code"],
        scopedReplacements: []
    )
}

final class VocabStore: ObservableObject {
    static let shared = VocabStore()
    private let url: URL
    @Published private(set) var data: VocabData = .defaultData

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis-voice")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("vocab.json")
        load()
    }

    func load() {
        guard let raw = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(VocabData.self, from: raw) else {
            save() // seed file with defaults so user can edit it
            return
        }
        data = decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? encoder.encode(data) {
            try? encoded.write(to: url)
        }
    }

    /// Adds (or updates) a "when I say X, write Y" mapping. Also adds the
    /// target word to the prompt bias so Whisper learns the correct spelling.
    func addReplacement(spoken: String, write target: String) {
        let s = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !t.isEmpty else { return }
        data.replacements[s] = t
        if !data.terms.contains(t) { data.terms.append(t) }
        save()
        NSLog("Vocab: '\(s)' -> '\(t)' saved")
    }

    func removeReplacement(spoken: String) {
        data.replacements.removeValue(forKey: spoken)
        save()
    }

    func addScopedReplacement(spoken: String, target: String, appBundleId: String?, appName: String?) {
        let s = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !t.isEmpty else { return }
        let item = ScopedReplacement(spoken: s, target: t,
                                     appBundleId: appBundleId, appName: appName)
        var list = data.scopedReplacements ?? []
        // Replace existing match (same spoken + scope)
        list.removeAll { $0.spoken == s && $0.appBundleId == appBundleId }
        list.append(item)
        data.scopedReplacements = list
        if !data.terms.contains(t) { data.terms.append(t) }
        save()
    }

    func removeScopedReplacement(_ item: ScopedReplacement) {
        var list = data.scopedReplacements ?? []
        list.removeAll { $0 == item }
        data.scopedReplacements = list
        save()
    }

    func addTerm(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !data.terms.contains(t) else { return }
        data.terms.append(t)
        save()
    }

    func removeTerm(_ term: String) {
        data.terms.removeAll { $0 == term }
        save()
    }

    /// Build the prompt string sent to Whisper.
    func promptBias() -> String {
        data.terms.joined(separator: ", ") + "."
    }

    /// Apply replacements to a transcription. Global replacements always
    /// apply; scoped replacements only when the target app matches.
    func applyReplacements(_ text: String, currentAppBundleId: String? = nil) -> String {
        var result = text
        var pairs: [(String, String)] = data.replacements.map { ($0.key, $0.value) }
        for item in data.scopedReplacements ?? [] {
            if item.appBundleId == nil || item.appBundleId == currentAppBundleId {
                pairs.append((item.spoken, item.target))
            }
        }
        // Sort by length descending so longer phrases match before substrings.
        pairs.sort { $0.0.count > $1.0.count }
        for (spoken, target) in pairs {
            let escaped = NSRegularExpression.escapedPattern(for: spoken)
            // Word boundaries on both sides for clean single-word matches;
            // multi-word phrases use \b too (works on first/last char).
            let pattern = "\\b\(escaped)\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(
                    in: result, options: [], range: range, withTemplate: target
                )
            }
        }
        return result
    }
}
