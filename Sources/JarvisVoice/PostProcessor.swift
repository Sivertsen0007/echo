import Foundation

/// Runs `claude -p ...` to post-process transcribed text with a style preset.
///
/// Shells out instead of using the Anthropic SDK directly because we want the
/// existing Claude Code login/auth on this machine. Skip if the CLI isn't
/// installed - we just return the input unchanged.
final class PostProcessor {
    static let shared = PostProcessor()

    private let claudePath: String?
    private let timeout: TimeInterval = 12

    private init() {
        self.claudePath = Self.findClaudeBinary()
        if claudePath == nil {
            NSLog("claude CLI not found - Style post-processing disabled")
        }
    }

    /// Apply a style to text. If the style is Raw, the CLI is missing, or the
    /// CLI errors/times out, returns the original text unchanged.
    func apply(style: StylePreset, to text: String, completion: @escaping (String) -> Void) {
        guard !style.systemPrompt.isEmpty else { completion(text); return }
        guard let claude = claudePath else { completion(text); return }
        guard !text.isEmpty else { completion(text); return }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runClaude(path: claude, systemPrompt: style.systemPrompt, userText: text)
            DispatchQueue.main.async {
                completion(result ?? text)
            }
        }
    }

    private func runClaude(path: String, systemPrompt: String, userText: String) -> String? {
        let combined = """
        \(systemPrompt)

        --- DICTATED TEXT ---
        \(userText)
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
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
        NSLog("Style applied in \(String(format: "%.2f", elapsed))s")
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
