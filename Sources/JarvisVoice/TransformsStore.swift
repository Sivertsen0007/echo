import Foundation

/// One-off LLM transformations triggered per recording. Different from Style:
/// Style is your *default* post-processing. Transforms are picked by name
/// for a specific recording when you want a different shape than the default.
///
/// UX (v1): a "next recording uses ..." override set from the menubar or the
/// Transforms view. The override applies to the next single recording, then
/// resets to the default style.
struct Transform: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var description: String
    var systemPrompt: String

    init(id: UUID = UUID(), name: String, description: String, systemPrompt: String) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
    }
}

struct TransformsData: Codable {
    var transforms: [Transform]

    static let defaultData = TransformsData(transforms: [
        Transform(
            name: "Slack message",
            description: "Casual, short, no signature. Strip filler. One paragraph.",
            systemPrompt: """
            Rewrite as a casual Slack message: short, direct, no filler words,
            no signature, single paragraph. Match the input language.
            Return only the rewritten text.
            """
        ),
        Transform(
            name: "Action items",
            description: "Extract clear, imperative TODO items as a bulleted list.",
            systemPrompt: """
            Extract action items from the dictated text. One per line, prefixed
            with "- ", in imperative form (e.g. "- Call supplier about Q4 order").
            Skip narration. Match the input language.
            """
        ),
        Transform(
            name: "Meeting note",
            description: "Structured note: TL;DR + decisions + next steps.",
            systemPrompt: """
            Convert the dictated text into a structured meeting note in markdown:
            ## TL;DR
            (one sentence)
            ## Decisions
            - ...
            ## Next steps
            - ...
            Skip sections that have no content. Match the input language.
            """
        ),
        Transform(
            name: "Translate to English",
            description: "Translate Danish dictation into natural English, preserving tone.",
            systemPrompt: """
            Translate the text into natural, idiomatic English. Preserve the
            speaker's tone (formal/casual). Return only the translation.
            """
        )
    ])
}

final class TransformsStore: ObservableObject {
    static let shared = TransformsStore()
    private let url: URL
    @Published private(set) var data: TransformsData = .defaultData

    /// Active one-shot override. When non-nil, the next recording uses this
    /// instead of the default Style. Cleared after the recording completes.
    @Published var nextRecordingOverride: Transform?

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis-voice")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("transforms.json")
        load()
    }

    private func load() {
        guard let raw = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TransformsData.self, from: raw) else {
            save(); return
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

    func add(name: String, description: String, systemPrompt: String) {
        let t = Transform(name: name, description: description, systemPrompt: systemPrompt)
        data.transforms.append(t)
        save()
    }

    func update(_ transform: Transform) {
        guard let idx = data.transforms.firstIndex(where: { $0.id == transform.id }) else { return }
        data.transforms[idx] = transform
        save()
    }

    func remove(id: UUID) {
        data.transforms.removeAll { $0.id == id }
        save()
    }

    /// Take the current override (if any) and clear it - call after a recording
    /// completes so the next one is back to default.
    func consumeOverride() -> Transform? {
        let t = nextRecordingOverride
        nextRecordingOverride = nil
        return t
    }
}
