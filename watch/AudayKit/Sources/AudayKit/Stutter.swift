import Foundation

/// Repairs English words a speech model "stutters" on in mixed Chinese–English speech:
/// SenseVoice heard "transcription" as "transranscription" and "transscription" (a piece of the
/// word decoded twice). A word is changed only when it is not a word itself and dropping one
/// piece that repeats the piece right before it gives a real word; names are left alone.
public enum Stutter {
    public static func fix(_ text: String, isWord: (String) -> Bool) -> String {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z]{5,}") else { return text }
        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            if let fixed = repair(String(out[range]), isWord: isWord) { out.replaceSubrange(range, with: fixed) }
        }
        return out
    }

    static func repair(_ word: String, isWord: (String) -> Bool) -> String? {
        let lower = word.lowercased()
        guard !isWord(lower) else { return nil }
        let chars = Array(lower)
        for length in 1...6 where 2 * length < chars.count {
            for i in length...(chars.count - length) where chars[(i - length)..<i] == chars[i..<(i + length)] {
                let candidate = String(chars[..<i] + chars[(i + length)...])
                if isWord(candidate) {
                    return word.first?.isUppercase == true ? candidate.prefix(1).uppercased() + candidate.dropFirst() : candidate
                }
            }
        }
        return nil
    }
}
