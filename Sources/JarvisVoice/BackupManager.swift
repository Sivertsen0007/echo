import Cocoa

/// Export / import the user-tunable config files (vocab, snippets, transforms,
/// style) as a single JSON bundle. Settings, API key, and the history DB are
/// intentionally not included.
enum BackupManager {
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".jarvis-voice")

    private static let files = ["vocab.json", "snippets.json", "transforms.json", "style.json"]

    static func exportToFile(at url: URL) throws {
        var bundle: [String: Any] = ["version": 1, "exported_at": ISO8601DateFormatter().string(from: Date())]
        for name in files {
            let path = configDir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: path),
               let json = try? JSONSerialization.jsonObject(with: data) {
                bundle[name] = json
            }
        }
        let out = try JSONSerialization.data(withJSONObject: bundle,
                                             options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url)
    }

    static func importFromFile(at url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        guard let bundle = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Echo", code: 1, userInfo: [NSLocalizedDescriptionKey: "File is not a valid Echo backup."])
        }
        var imported: [String] = []
        for name in files {
            guard let payload = bundle[name] else { continue }
            let path = configDir.appendingPathComponent(name)
            let out = try JSONSerialization.data(withJSONObject: payload,
                                                 options: [.prettyPrinted, .sortedKeys])
            try out.write(to: path)
            imported.append(name)
        }
        // Tell live stores to reload from disk.
        NotificationCenter.default.post(name: .backupImported, object: nil)
        return imported
    }
}

extension Notification.Name {
    static let backupImported = Notification.Name("EchoBackupImported")
}
