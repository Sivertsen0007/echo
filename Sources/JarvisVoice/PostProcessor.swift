import Foundation

/// Post-processes transcribed text with a style preset.
///
/// Primary path is a fast chat-completions call (Groq ~0.3s, or OpenAI). The
/// `claude -p` CLI is kept only as a fallback for machines with no API key -
/// it works but is slow (10-15s) because it spins up a full Claude Code
/// session, so we never use it when a key is available.
final class PostProcessor {
    static let shared = PostProcessor()

    private let claudePath: String?
    private let timeout: TimeInterval = 12

    private init() {
        self.claudePath = Self.findClaudeBinary()
        if claudePath == nil {
            NSLog("claude CLI not found - Style fallback disabled (API styling still works)")
        }
    }

    /// Apply a style to text. Raw style, no key + no CLI, or an error all return
    /// the original text unchanged.
    func apply(style: StylePreset, to text: String, completion: @escaping (String) -> Void) {
        guard !style.systemPrompt.isEmpty else { completion(text); return }
        guard !text.isEmpty else { completion(text); return }

        DispatchQueue.global(qos: .userInitiated).async {
            let styled = self.styleViaAPI(systemPrompt: style.systemPrompt, userText: text)
                ?? self.styleViaCLI(systemPrompt: style.systemPrompt, userText: text)
                ?? text
            DispatchQueue.main.async { completion(styled) }
        }
    }

    // MARK: - Fast path: chat completions API

    private func styleViaAPI(systemPrompt: String, userText: String) -> String? {
        guard let provider = ConfigStore.shared.styleProvider,
              let key = ConfigStore.shared.apiKey(for: provider) else { return nil }
        let model = provider.defaultStyleModel

        var req = URLRequest(url: provider.chatEndpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        req.httpBody = body

        let started = Date()
        var output: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, error in
            defer { sem.signal() }
            if let error = error {
                NSLog("Style API error (\(provider.displayName)): \(error)")
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                NSLog("Style API bad response (\(provider.displayName)): \(String(describing: json).prefix(200))")
                return
            }
            output = content.trimmingCharacters(in: .whitespacesAndNewlines)
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)

        guard let result = output, !result.isEmpty else { return nil }
        NSLog("Style applied via \(provider.displayName)/\(model) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return result
    }

    // MARK: - Fallback: claude CLI (slow, no key required)

    private func styleViaCLI(systemPrompt: String, userText: String) -> String? {
        guard let claude = claudePath else { return nil }
        let combined = """
        \(systemPrompt)

        --- DICTATED TEXT ---
        \(userText)
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claude)
        proc.arguments = ["-p", combined, "--model", "haiku"]

        let stdout = Pipe(), stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let started = Date()
        do { try proc.run() } catch {
            NSLog("claude launch failed: \(error)")
            return nil
        }

        // Hard timeout: kill if not done within `timeout` seconds.
        let killer = DispatchWorkItem { [weak proc] in
            if proc?.isRunning == true { proc?.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        proc.waitUntilExit()
        killer.cancel()

        let elapsed = Date().timeIntervalSince(started)
        guard proc.terminationStatus == 0 else {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("claude exited \(proc.terminationStatus) in \(String(format: "%.2f", elapsed))s: \(err.prefix(300))")
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("Style applied via claude CLI in \(String(format: "%.2f", elapsed))s")
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Locate `claude` via the user's login shell so PATH is set correctly.
    private static func findClaudeBinary() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: out, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = path, !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) else {
            return nil
        }
        return p
    }
}
