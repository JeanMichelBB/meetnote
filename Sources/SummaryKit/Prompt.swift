import Foundation

public enum Prompt {
    static let rules = """
        The transcript lines look like "[hh:mm:ss] Speaker: text". "Me" is the person who recorded the meeting. \
        "Speaker 1", "Speaker 2" and so on are the other participants, numbered by who spoke first, not named. \
        "Them" means the other side had a single voice. Write in the same language as the transcript \
        (if it is mixed, use the main language). Do not invent facts, names or deadlines. If it is unclear who \
        said something, say so. Never start a line with the ">" character. Output only Markdown.
        """

    public static let system = """
        You summarize meeting transcripts. Use exactly these sections, each with a "###" heading: \
        Summary (3 to 6 sentences), Decisions (bullets, or "None"), Action items (bullets: who, what, and the \
        deadline if one was stated, or "None"), Open questions (bullets, or "None").
        \(rules)
        """

    public static let partSystem = """
        You summarize one part of a long meeting transcript. List the key points, decisions, action items \
        (who, what, deadline) and open questions from this part as short Markdown bullets.
        \(rules)
        """

    public static let mergeSystem = """
        You are given notes taken from consecutive parts of one meeting. Combine them into one summary. \
        Use exactly these sections, each with a "###" heading: Summary (3 to 6 sentences), Decisions (bullets, \
        or "None"), Action items (bullets: who, what, and the deadline if one was stated, or "None"), \
        Open questions (bullets, or "None"). Remove duplicates.
        \(rules)
        """

    public static func user(title: String, transcript: String) -> String {
        "Meeting: \(title)\n\nTranscript:\n\(transcript)"
    }

    public static func userPart(title: String, index: Int, count: Int, text: String) -> String {
        "Meeting: \(title)\nPart \(index) of \(count).\n\nTranscript part:\n\(text)"
    }

    public static func userMerge(title: String, notes: [String]) -> String {
        let joined = notes.enumerated().map { "Notes from part \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        return "Meeting: \(title)\n\n\(joined)"
    }
}
