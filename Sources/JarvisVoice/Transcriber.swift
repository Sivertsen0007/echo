import Foundation

/// Posts audio to the active transcription provider (OpenAI or Groq).
/// Both providers expose an OpenAI-compatible /audio/transcriptions endpoint
/// so the request body is identical - only URL, auth, and model name change.
///
/// Failure handling: transient failures (network, 429, 5xx) are retried once,
/// and the audio of a dictation that ultimately fails is moved to
/// ~/.jarvis-voice/failed/ instead of deleted, so a network blip cannot
/// destroy what was said.
final class Transcriber {
    private var promptBias: String { VocabStore.shared.promptBias() }
    private let requestTimeout: TimeInterval = 30

    /// Why a transcription produced no text - drives the user-facing message.
    enum Failure {
        case noKey
        case network
        case badKey            // 401 / 403
        case rateLimited       // 429
        case serverError(Int)  // 5xx and other unexpected statuses
        case empty             // no speech / echoed prompt
    }

    /// Result includes which provider + model was used so the caller can
    /// attribute cost and compare latency across models.
    struct Result {
        let text: String?
        let provider: TranscriptionProvider
        let model: String
        var failure: Failure? = nil
    }

    func transcribe(audioURL: URL, completion: @escaping (Result) -> Void) {
        attempt(audioURL: audioURL, retriesLeft: 1, completion: completion)
    }

    private func attempt(audioURL: URL, retriesLeft: Int, completion: @escaping (Result) -> Void) {
        let provider = ConfigStore.shared.activeProvider
        let model = ConfigStore.shared.model(for: provider)
        func fail(_ failure: Failure, keepAudio: Bool = true) {
            if keepAudio {
                Self.keepFailedAudio(audioURL)
            } else {
                try? FileManager.default.removeItem(at: audioURL)
            }
            completion(Result(text: nil, provider: provider, model: model, failure: failure))
        }

        guard let apiKey = ConfigStore.shared.apiKey(for: provider) else {
            NSLog("Missing \(provider.displayName) API key. Configure it in Settings.")
            fail(.noKey)
            return
        }
        guard let audioData = try? Data(contentsOf: audioURL) else {
            fail(.empty, keepAudio: false)
            return
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: provider.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", model)
        appendField("prompt", promptBias)
        appendField("response_format", "json")
        appendField("temperature", "0")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let started = Date()
        URLSession.shared.dataTask(with: req) { data, response, error in
            func retryOrFail(_ failure: Failure) {
                guard retriesLeft > 0 else { fail(failure); return }
                NSLog("Transcribe retrying (\(retriesLeft) attempt(s) left)")
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
                    self.attempt(audioURL: audioURL, retriesLeft: retriesLeft - 1, completion: completion)
                }
            }

            if let error = error {
                NSLog("Transcribe error (\(provider.displayName)): \(error.localizedDescription)")
                retryOrFail(.network)
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: break
            case 401, 403:
                NSLog("Transcribe rejected (\(provider.displayName) HTTP \(status)) - check the API key")
                fail(.badKey)
                return
            case 429:
                NSLog("Transcribe rate-limited (\(provider.displayName))")
                retryOrFail(.rateLimited)
                return
            default:
                let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                NSLog("Transcribe HTTP \(status) (\(provider.displayName)): \(bodyText.prefix(300))")
                retryOrFail(.serverError(status))
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                retryOrFail(.serverError(status))
                return
            }
            let elapsed = Date().timeIntervalSince(started)
            guard let text = json["text"] as? String else {
                NSLog("Transcribe response from \(provider.displayName): \(json)")
                retryOrFail(.serverError(status))
                return
            }

            NSLog("Transcribed via \(provider.displayName) in \(String(format: "%.2f", elapsed))s: \(text)")
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || self.isPromptEcho(cleaned) {
                NSLog("Discarded empty/echoed transcription")
                fail(.empty, keepAudio: false)
                return
            }
            try? FileManager.default.removeItem(at: audioURL)
            completion(Result(text: text, provider: provider, model: model))
        }.resume()
    }

    /// True when the transcription is just the vocab prompt echoed back - a
    /// known Whisper failure mode on silent or near-empty audio. Word-set
    /// containment catches partial echoes, not only byte-exact ones, while
    /// still allowing a dictation that legitimately uses a few vocab terms:
    /// it must both consist almost entirely of prompt words AND cover most of
    /// the prompt to count as an echo.
    private func isPromptEcho(_ text: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let resultWords = words(text)
        guard !resultWords.isEmpty else { return true }
        let promptWords = Set(words(promptBias))
        guard !promptWords.isEmpty else { return false }
        let fromPrompt = resultWords.filter { promptWords.contains($0) }.count
        let promptCovered = promptWords.intersection(Set(resultWords)).count
        return Double(fromPrompt) / Double(resultWords.count) >= 0.9
            && Double(promptCovered) / Double(promptWords.count) >= 0.6
    }

    /// Move a failed dictation's audio aside instead of deleting it. Pruned to
    /// the newest 10 files so the folder cannot grow unbounded.
    private static func keepFailedAudio(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".jarvis-voice/failed")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: url, to: dest)
            NSLog("Kept failed recording at \(dest.path)")
        } catch {
            NSLog("Could not keep failed recording: \(error)")
        }

        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let sorted = files.sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            for stale in sorted.dropFirst(10) { try? fm.removeItem(at: stale) }
        }
    }
}
