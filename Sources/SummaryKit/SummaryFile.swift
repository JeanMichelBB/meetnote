import Foundation

/// The summary lives between two hidden markers inside the meeting's .md file,
/// so edits you make anywhere else in the file are never touched.
public enum SummaryFile {
    public static let startMarker = "<!-- summary:start -->"
    public static let endMarker = "<!-- summary:end -->"
    public static let transcriptHeading = "## Transcript"

    public enum WriteError: LocalizedError {
        case missingMarkers
        public var errorDescription: String? {
            "The summary markers are missing from the file, so it was left untouched."
        }
    }

    public static func section(_ body: String) -> String {
        "\(startMarker)\n\(body)\n\(endMarker)"
    }

    /// The text currently between the summary markers, if the file has them.
    public static func currentBody(of text: String) -> String? {
        guard let start = text.range(of: startMarker),
            let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func replaceSection(in url: URL, with body: String) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let start = text.range(of: startMarker),
            let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
        else { throw WriteError.missingMarkers }
        var result = text
        result.replaceSubrange(start.upperBound..<end.lowerBound, with: "\n\(body)\n")
        try result.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Everything after the "## Transcript" heading.
    public static func transcriptText(from fileText: String) -> String {
        guard let range = fileText.range(of: transcriptHeading) else { return fileText }
        return String(fileText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first heading, without the "# ".
    public static func title(from fileText: String) -> String {
        let first = fileText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
        return first.replacingOccurrences(of: "# ", with: "")
    }
}
