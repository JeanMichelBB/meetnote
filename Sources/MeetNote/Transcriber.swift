import FluidAudio
import Foundation
import SummaryKit

struct Segment {
    var start: TimeInterval
    var speaker: String
    var text: String
}

/// Local speech-to-text with Parakeet v3 (English, French and 23 other languages, detected automatically).
actor Transcriber {
    private var manager: AsrManager?

    var isReady: Bool { manager != nil }

    /// Downloads the model the first time (cached by FluidAudio afterwards) and loads it.
    func prepare() async throws {
        if manager != nil { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
    }

    /// Words with start and end times for one audio file.
    func words(url: URL) async throws -> [WordTiming] {
        try await prepare()
        guard let manager else { return [] }

        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(url, decoderState: &state)

        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [WordTiming(word: text, startTime: 0, endTime: 0)]
        }
        return buildWordTimings(from: timings)
    }

    /// Groups words into lines: a new line starts when the speaker changes, after a pause of
    /// 1 second, or at the end of a sentence. `labels[i]` is the speaker of `words[i]`.
    static func group(words: [WordTiming], labels: [String]) -> [Segment] {
        var segments: [Segment] = []
        var current: [WordTiming] = []
        var currentLabel = ""

        func flush() {
            guard let first = current.first else { return }
            let text = current.map(\.word).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(Segment(start: first.startTime, speaker: currentLabel, text: text))
            }
            current = []
        }

        for (word, label) in zip(words, labels) {
            if let last = current.last,
                word.startTime - last.endTime > 1.0 || label != currentLabel
            {
                flush()
            }
            currentLabel = label
            current.append(word)
            if let end = word.word.last, ".?!".contains(end) { flush() }
        }
        flush()
        return segments
    }
}

enum TranscriptWriter {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MeetNote", isDirectory: true)
    }

    /// All transcript files, in any month folder.
    static func allTranscripts() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
    }

    /// Where a transcript file belongs: <folder>/2026-11/2026-11-05/<name>.md
    static func home(forFileNamed name: String) -> URL? {
        guard name.count >= 10, name.prefix(10).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        else { return nil }
        return folder
            .appendingPathComponent(String(name.prefix(7)), isDirectory: true)
            .appendingPathComponent(String(name.prefix(10)), isDirectory: true)
    }

    /// Moves files that sit in the wrong place into month and day folders.
    static func organize() {
        let fm = FileManager.default
        for file in allTranscripts() {
            guard let dir = home(forFileNamed: file.lastPathComponent),
                file.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL
            else { continue }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.moveItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
        // Remove month folders left empty.
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            if (try? fm.contentsOfDirectory(atPath: item.path))?.isEmpty == true { try? fm.removeItem(at: item) }
        }
    }

    static func timestamp(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func write(segments: [Segment], started: Date, duration: TimeInterval) throws -> URL {
        let nameFormat = DateFormatter()
        nameFormat.dateFormat = "yyyy-MM-dd HH.mm"
        let fileName = "\(nameFormat.string(from: started)).md"
        let dayFolder = home(forFileNamed: fileName) ?? folder
        try FileManager.default.createDirectory(at: dayFolder, withIntermediateDirectories: true)
        let url = dayFolder.appendingPathComponent(fileName)

        let titleFormat = DateFormatter()
        titleFormat.dateStyle = .medium
        titleFormat.timeStyle = .short

        var out = "# Meeting \(titleFormat.string(from: started))\n"
        out += "Length: \(timestamp(duration))\n\n"
        out += "## Summary\n\(SummaryFile.section("Summary pending…"))\n\n"
        out += "\(SummaryFile.transcriptHeading)\n\n"
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            out += "[\(timestamp(segment.start))] \(segment.speaker): \(segment.text)\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
