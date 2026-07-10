import Foundation

/// Multi-line text templates triggered by spoken phrases.
///
/// Differs from VocabStore replacements in two ways:
///   1. Expansions can be multi-line / multi-paragraph.
///   2. We track usage (`hits`, `lastUsedAt`) so the UI can show what gets used.
///
/// Triggers are matched case-insensitively as whole phrases. Longer triggers
/// match before shorter ones to avoid "mvh" eating into "mvh signature".
struct Snippet: Codable, Identifiable, Hashable {
    var id: UUID
    var trigger: String
    var expansion: String
    var hits: Int
    var lastUsedAt: String?

    init(id: UUID = UUID(), trigger: String, expansion: String, hits: Int = 0, lastUsedAt: String? = nil) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.hits = hits
        self.lastUsedAt = lastUsedAt
    }
}

struct SnippetsData: Codable {
    var snippets: [Snippet]

    static let defaultData = SnippetsData(snippets: [
        Snippet(trigger: "signatur",
                expansion: "Med venlig hilsen,\nMathias Sivertsen"),
        Snippet(trigger: "email start",
                expansion: "Hi there,\n\nThanks for reaching out. "),
        Snippet(trigger: "ml address",
                expansion: "Master Liveaboards Ltd\nlevels@masterliveaboards.com\nmasterliveaboards.com")
    ])
}

final class SnippetsStore: ObservableObject {
    static let shared = SnippetsStore()
    private let url: URL
    @Published private(set) var data: SnippetsData = .defaultData

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis-voice")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("snippets.json")
        load()
    }

    private func load() {
        guard let raw = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SnippetsData.self, from: raw) else {
            save()
            return
        }
        data = decoded
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? enc.encode(data) {
            try? encoded.write(to: url)
        }
    }

    func add(trigger: String, expansion: String) {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !expansion.isEmpty else { return }
        data.snippets.append(Snippet(trigger: t, expansion: expansion))
        save()
    }

    func update(_ snippet: Snippet) {
        guard let idx = data.snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        data.snippets[idx] = snippet
        save()
    }

    func remove(id: UUID) {
        data.snippets.removeAll { $0.id == id }
        save()
    }

    /// Apply all snippet expansions to `text`. Whole-phrase, case-insensitive.
    /// Longer triggers checked first so they don't get eaten by shorter ones.
    /// Increments hit counter for each match.
    func apply(to text: String) -> String {
        var result = text
        var changed = false
        let sorted = data.snippets.sorted { $0.trigger.count > $1.trigger.count }
        for snippet in sorted {
            let escaped = NSRegularExpression.escapedPattern(for: snippet.trigger)
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.numberOfMatches(in: result, options: [], range: range)
            if matches > 0 {
                result = regex.stringByReplacingMatches(
                    in: result, options: [], range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: snippet.expansion)
                )
                if let idx = data.snippets.firstIndex(where: { $0.id == snippet.id }) {
                    data.snippets[idx].hits += matches
                    data.snippets[idx].lastUsedAt = ISO8601DateFormatter().string(from: Date())
                    changed = true
                }
            }
        }
        if changed { save() }
        return result
    }
}
