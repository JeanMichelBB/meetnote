import Foundation

/// When you use speakers, your mic hears the other people and the "Me" track repeats their words.
/// This finds the "Me" words that also appear on the "Them" track at about the same moment.
enum EchoFilter {
    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
    }

    /// `true` for every "Me" word that is probably an echo of the "Them" track.
    /// A word counts as echo when the same word was said on "Them" within `window` seconds.
    /// A lone short word (3 letters or fewer) with no echoed neighbor is kept: it's probably you
    /// saying "yes" or "I", not an echo.
    static func echoMask(
        me: [(word: String, time: Double)],
        them: [(word: String, time: Double)],
        window: Double = 2.0
    ) -> [Bool] {
        let themWords = them.map { (word: normalize($0.word), time: $0.time) }

        let raw: [Bool] = me.map { item in
            let word = normalize(item.word)
            guard !word.isEmpty else { return false }
            return themWords.contains { $0.word == word && abs($0.time - item.time) <= window }
        }

        var mask = raw
        for index in raw.indices where raw[index] {
            let word = normalize(me[index].word)
            guard word.count <= 3 else { continue }
            let previous = index > 0 && raw[index - 1]
            let next = index + 1 < raw.count && raw[index + 1]
            if !previous && !next { mask[index] = false }
        }
        return mask
    }
}
