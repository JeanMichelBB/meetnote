import FluidAudio
import Foundation

struct SpeakerSpan {
    var id: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Works out who spoke when on the "Them" track, entirely on this Mac.
actor SpeakerSeparator {
    private var manager: OfflineDiarizerManager?

    func prepare() async throws {
        if manager != nil { return }
        let m = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await m.prepareModels()
        manager = m
    }

    func spans(in url: URL) async throws -> [SpeakerSpan] {
        try await prepare()
        guard let manager else { return [] }
        let result = try await manager.process(url)
        return result.segments.map {
            SpeakerSpan(
                id: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds))
        }
    }
}

enum SpeakerLabeler {
    /// One label per word: "Speaker 1", "Speaker 2"... numbered by who speaks first.
    /// With zero or one detected speaker the label is plain "Them".
    static func labels(for words: [WordTiming], spans: [SpeakerSpan]) -> [String] {
        let raw = words.map { speakerId(for: $0, spans: spans) }

        var order: [String] = []
        for id in raw where !order.contains(id) && id != "" { order.append(id) }
        if order.count <= 1 { return raw.map { _ in "Them" } }

        let names = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, "Speaker \($0 + 1)") })
        var lastKnown = "Them"
        return raw.map { id in
            if let name = names[id] {
                lastKnown = name
                return name
            }
            return lastKnown
        }
    }

    /// The span that overlaps the word the most, or the closest span if none overlaps.
    private static func speakerId(for word: WordTiming, spans: [SpeakerSpan]) -> String {
        guard !spans.isEmpty else { return "" }
        var best: (id: String, overlap: TimeInterval)?
        for span in spans {
            let overlap = min(word.endTime, span.end) - max(word.startTime, span.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (span.id, overlap) }
        }
        if let best { return best.id }

        let mid = (word.startTime + word.endTime) / 2
        let nearest = spans.min { distance(mid, $0) < distance(mid, $1) }
        if let nearest, distance(mid, nearest) < 1.5 { return nearest.id }
        return ""
    }

    private static func distance(_ t: TimeInterval, _ span: SpeakerSpan) -> TimeInterval {
        if t < span.start { return span.start - t }
        if t > span.end { return t - span.end }
        return 0
    }
}
