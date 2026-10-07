import Foundation

/// Built-in style presets and the user's chosen default. Default persists
/// to ~/.jarvis-voice/style.json.
struct StylePreset: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let systemPrompt: String
    /// True for styles that only tidy the speaker's own words (Clean). Lets the
    /// post-processor reject output that is mostly invented text - a sign the
    /// model answered or expanded instead of cleaning. Left false for styles
    /// that legitimately rewrite or restructure (Email, Bullets) and for British
    /// (its spelling swaps read as "new" words to a token check, so the backstop
    /// would misfire).
    var preservesWording: Bool = false

    static let raw = StylePreset(
        id: "raw",
        name: "Raw",
        description: "No post-processing. Whisper output, plus your vocab replacements.",
        systemPrompt: ""
    )

    static let clean = StylePreset(
        id: "clean",
        name: "Clean",
        description: "Remove filler words (uh, like, øh), fix punctuation and capitalisation. Preserve your voice.",
        systemPrompt: """
        You are cleaning a dictation transcript. Apply these edits only:
        - Remove filler words: um, uh, like, you know, sort of, ligesom, øh, altså.
        - Fix capitalisation and punctuation (commas, full stops, question marks).
        - Add paragraph breaks where the speaker pauses between thoughts.
        Preserve the speaker's wording, tone, and meaning. Do not rephrase or summarise.
        Match the input language (Danish or English) - do not translate.
        Return only the cleaned text. No preamble, no quotes.
        """,
        preservesWording: true
    )

    static let email = StylePreset(
        id: "email",
        name: "Email",
        description: "Rewrite as a polite, professional email body.",
        systemPrompt: """
        You are editing dictated text into a polite, professional email body.
        - Fix grammar and structure.
        - Warm but professional tone.
        - Keep the speaker's core message and intent intact.
        - Match the input language (Danish or English).
        Return only the rewritten text. No preamble, no signature, no quotes.
        """
    )

    static let bullets = StylePreset(
        id: "bullets",
        name: "Bullet Points",
        description: "Convert spoken paragraph into a clean bulleted list.",
        systemPrompt: """
        Convert the dictated text into a clean bulleted list.
        - One point per line, each line starting with "- ".
        - Preserve the speaker's wording where reasonable.
        - No headings, no preamble, no commentary.
        Match the input language (Danish or English).
        """
    )

    static let british = StylePreset(
        id: "british",
        name: "British English",
        description: "Clean + force British spelling (colour, organise, behaviour). Useful for ML brand copy.",
        systemPrompt: """
        Clean a dictation transcript:
        - Remove filler words.
        - Fix punctuation and capitalisation.
        - Use British English spelling throughout (colour, organise, behaviour, realise, centre).
        Preserve the speaker's wording, tone and meaning.
        Return only the edited text. No preamble.
        """
    )

    static let all: [StylePreset] = [.raw, .clean, .email, .bullets, .british]
}

final class StyleStore: ObservableObject {
    static let shared = StyleStore()
    private let url: URL
    @Published var defaultStyleId: String {
        didSet { save() }
    }

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis-voice")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("style.json")
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["default_style_id"] as? String,
           StylePreset.all.contains(where: { $0.id == id }) {
            self.defaultStyleId = id
        } else {
            self.defaultStyleId = StylePreset.raw.id
        }
        save()
        // Reload the default style on backup import - no restart needed.
        NotificationCenter.default.addObserver(forName: .backupImported, object: nil, queue: .main) { [weak self] _ in
            self?.reloadFromDisk()
        }
    }

    /// Re-read the persisted default style from disk (after a backup import).
    private func reloadFromDisk() {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["default_style_id"] as? String,
              StylePreset.all.contains(where: { $0.id == id }) else { return }
        if defaultStyleId != id { defaultStyleId = id }
    }

    private func save() {
        let json: [String: Any] = ["default_style_id": defaultStyleId]
        if let data = try? JSONSerialization.data(withJSONObject: json,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    var defaultStyle: StylePreset {
        StylePreset.all.first(where: { $0.id == defaultStyleId }) ?? .raw
    }
}
