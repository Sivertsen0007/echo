import Foundation

/// Posts audio to the active transcription provider (OpenAI or Groq).
/// Both providers expose an OpenAI-compatible /audio/transcriptions endpoint
/// so the request body is identical - only URL, auth, and model name change.
final class Transcriber {
    private var promptBias: String { VocabStore.shared.promptBias() }

    /// Result includes which provider + model was used so the caller can
    /// attribute cost and compare latency across models.
    struct Result {
        let text: String?
        let provider: TranscriptionProvider
        let model: String
    }

    func transcribe(audioURL: URL, completion: @escaping (Result) -> Void) {
        let provider = ConfigStore.shared.activeProvider
        let model = ConfigStore.shared.model(for: provider)
        guard let apiKey = ConfigStore.shared.apiKey(for: provider) else {
            NSLog("Missing \(provider.displayName) API key. Configure it in Settings.")
            completion(Result(text: nil, provider: provider, model: model))
            return
        }
        guard let audioData = try? Data(contentsOf: audioURL) else {
            completion(Result(text: nil, provider: provider, model: model))
            return
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: provider.endpoint)
        req.httpMethod = "POST"
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
        URLSession.shared.dataTask(with: req) { data, _, error in
            defer { try? FileManager.default.removeItem(at: audioURL) }
            if let error = error {
                NSLog("Transcribe error (\(provider.displayName)): \(error)")
                completion(Result(text: nil, provider: provider, model: model)); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(Result(text: nil, provider: provider, model: model)); return
            }
            let elapsed = Date().timeIntervalSince(started)
            if let text = json["text"] as? String {
                NSLog("Transcribed via \(provider.displayName) in \(String(format: "%.2f", elapsed))s: \(text)")
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let promptTrim = self.promptBias.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned == promptTrim {
                    NSLog("Discarded echoed prompt")
                    completion(Result(text: nil, provider: provider, model: model)); return
                }
                completion(Result(text: text, provider: provider, model: model))
            } else {
                NSLog("Transcribe response from \(provider.displayName): \(json)")
                completion(Result(text: nil, provider: provider, model: model))
            }
        }.resume()
    }
}
