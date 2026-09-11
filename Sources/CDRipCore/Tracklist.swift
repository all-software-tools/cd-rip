import Foundation

public enum TracklistFormat: String, CaseIterable, Identifiable, Sendable {
    case titles, artistTitle
    public var id: String { rawValue }
    public var title: String { self == .titles ? "Titles only" : "Artist — Title" }
}
public struct TracklistRow: Identifiable, Equatable, Sendable {
    public var id: Int { line }
    public let line: Int
    public var number: Int
    public var artist: String
    public var title: String
    public init(line: Int, number: Int, artist: String, title: String) {
        self.line = line; self.number = number; self.artist = artist; self.title = title
    }
}
public struct TracklistPreview: Sendable {
    public var rows: [TracklistRow]
    public var problems: [String]
    public var canApply: Bool { problems.isEmpty && !rows.isEmpty }
}

/// Deterministic offline parsing. A title containing a hyphen is never guessed to contain an artist.
public enum TracklistParser {
    public static func parse(_ text: String, format: TracklistFormat, session: RipSession) -> TracklistPreview {
        let lines = text.components(separatedBy: .newlines).enumerated().filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
        guard text.utf8.count <= 100_000, lines.count <= 200 else { return .init(rows: [], problems: ["The list is too long (maximum 200 lines / 100 KB)."] ) }
        let regex = try! NSRegularExpression(pattern: #"^([0-9]{1,3})(?:[.)]\s*|\s+[-–—]\s+|\t+)(.+)$"#)
        var numbered: [Bool] = []
        var rows: [TracklistRow] = []
        var issues: [String] = []
        for (offset, line) in lines {
            var body = line.trimmingCharacters(in: .whitespaces)
            var number = rows.count + 1
            if let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
               let n = Range(match.range(at: 1), in: body), let rest = Range(match.range(at: 2), in: body) {
                number = Int(body[n])!; body = String(body[rest]); numbered.append(true)
            } else { numbered.append(false) }
            var artist = ""
            if format == .artistTitle {
                let separators = [" — ", " – ", " - ", "\t"]
                let ranges = separators.compactMap { body.range(of: $0) }
                if let split = ranges.min(by: { $0.lowerBound < $1.lowerBound }) {
                    artist = String(body[..<split.lowerBound]).trimmingCharacters(in: .whitespaces)
                    body = String(body[split.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    issues.append("Line \(offset + 1): missing the Artist — Title separator. For albums, choose “Titles only”.")
                }
            }
            rows.append(.init(line: offset + 1, number: number, artist: artist, title: body.trimmingCharacters(in: .whitespaces)))
        }
        if numbered.contains(true) && numbered.contains(false) { issues.append("Number every line or remove all track numbers.") }
        if !numbered.contains(true) {
            if rows.count == session.disc.tracks.count {
                for i in rows.indices { rows[i].number = session.disc.tracks[i].number }
            } else if session.tracks.count == session.disc.tracks.count && rows.count == session.tracks.count {
                for i in rows.indices { rows[i].number = session.tracks[i].number }
            } else {
                issues.append("For a partial selection, use physical track numbers (for example 2. and 7.) or enter the complete CD tracklist.")
            }
        }
        issues += validate(rows, session: session)
        return .init(rows: rows, problems: issues)
    }
    public static func validate(_ rows: [TracklistRow], session: RipSession) -> [String] {
        var issues: [String] = []
        let physical = Set(session.disc.tracks.map(\.number))
        var seen: Set<Int> = []
        for row in rows {
            if !seen.insert(row.number).inserted { issues.append("Track \(row.number) appears more than once.") }
            if !physical.contains(row.number) { issues.append("Track \(row.number) does not exist on this CD.") }
            if row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Track \(row.number) has no title.") }
        }
        let missing = Set(session.tracks.map(\.number)).subtracting(seen).sorted()
        if !missing.isEmpty { issues.append("Missing selected tracks: \(missing.map(String.init).joined(separator: ", ")).") }
        return issues
    }
}
