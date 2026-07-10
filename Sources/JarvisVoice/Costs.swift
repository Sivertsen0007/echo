import Foundation

/// Centralised pricing for Echo's API calls. Update these if OpenAI/Anthropic
/// change their published rates - all cost displays read from here.
enum Costs {
    /// Default fallback (OpenAI). For accurate historical billing use the
    /// per-row provider attribution stored in the transcriptions table.
    static let whisperUSDPerMinute: Double = 0.003

    /// Claude Haiku rough rates (per 1M tokens) - tune in Settings if prices move.
    static let haikuInputUSDPerMTokens: Double = 1.0
    static let haikuOutputUSDPerMTokens: Double = 5.0

    /// Token ≈ char heuristic. Good enough for spend estimates.
    static let charsPerToken: Double = 4.0

    static func whisperCost(audioSeconds: Double) -> Double {
        (audioSeconds / 60.0) * whisperUSDPerMinute
    }

    static func transcribeCost(audioSeconds: Double, provider: String?, model: String? = nil) -> Double {
        guard let p = TranscriptionProvider(rawValue: provider ?? "") else {
            return (audioSeconds / 60.0) * whisperUSDPerMinute
        }
        // Prefer the row's actual model rate; fall back to the provider default
        // for legacy rows recorded before we stored the model.
        let rate = model.map { p.price(forModel: $0) } ?? p.pricePerMinute
        return (audioSeconds / 60.0) * rate
    }

    /// LLM cost is only incurred when a non-Raw style or a transform was used.
    /// We estimate tokens from character counts (input ≈ raw_text + style prompt,
    /// output ≈ final_text).
    static func llmCost(inputChars: Int, outputChars: Int) -> Double {
        let inTokens = Double(inputChars) / charsPerToken
        let outTokens = Double(outputChars) / charsPerToken
        return (inTokens / 1_000_000.0) * haikuInputUSDPerMTokens
             + (outTokens / 1_000_000.0) * haikuOutputUSDPerMTokens
    }
}
