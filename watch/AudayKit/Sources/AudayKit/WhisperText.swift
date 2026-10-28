import Foundation

/// Cleans Whisper's output into what Auday shows: speech only. Whisper writes sounds as captions
/// ("[MUSIC]", "[BLANK_AUDIO]", "(footsteps)", "♪") and, in quiet stretches, invents subtitle
/// credits ("Thanks for watching!", "字幕由Amara.org社区提供"); none of that is speech.
public enum WhisperText {
    /// Phrases Whisper is known to invent over silence or noise; dropped when they are the whole segment.
    static let invented = ["thanks for watching", "thank you for watching", "please subscribe",
                           "subtitles by the amara.org community", "字幕由amara.org社区提供",
                           "谢谢观看", "感谢观看", "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
                           "ご視聴ありがとうございました", "시청해주셔서 감사합니다"]
    /// Said for real often enough that they are only dropped when the model itself doubts speech.
    static let doubtful = ["thank you", "thanks", "谢谢", "you", "bye", "okay"]

    /// The segment's speech, or nil when nothing is left. `doubtsSpeech`: the model's no-speech
    /// probability was high enough that a lone "Thank you." is more likely invented than said.
    public static func clean(_ text: String, doubtsSpeech: Bool = false) -> String? {
        var t = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|（[^）]*）|\*[^*]*\*|[♪♫🎵🎶]"#,
                                          with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?。，！？…-"))
        if key.isEmpty || invented.contains(key) || (doubtsSpeech && doubtful.contains(key)) { return nil }
        if t.allSatisfy({ $0.isPunctuation || $0.isWhitespace || $0.isSymbol }) { return nil }
        // Letters outside the five transcription languages (Sinhala, Georgian … ) are Whisper
        // guessing at noise, not speech.
        if t.unicodeScalars.contains(where: { $0.properties.isAlphabetic && !spoken($0.value) }) { return nil }
        return t
    }

    /// Latin, CJK, kana and Hangul: what Mandarin, Cantonese, English, Japanese and Korean are written in.
    static func spoken(_ v: UInt32) -> Bool {
        switch v {
        case 0x0000...0x024F, 0x1E00...0x1EFF,            // Latin
             0x2E80...0x2FDF, 0x3005...0x3007, 0x3021...0x3029, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0x20000...0x3134F,          // Han
             0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,   // kana
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF,   // Hangul
             0xFF21...0xFF3A, 0xFF41...0xFF5A:            // full-width Latin
            return true
        default:
            return false
        }
    }
}
