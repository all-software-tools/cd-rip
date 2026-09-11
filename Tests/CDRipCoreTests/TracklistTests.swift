import Foundation
import Testing
@testable import CDRipCore

private func session(_ numbers: [Int] = Array(1...8)) async throws -> RipSession {
    let disc = try await DemoDiscSource().loadDisc()
    return RipSession(disc: disc, selectedIDs: Set(disc.tracks.filter { numbers.contains($0.number) }.map(\.id)), profile: .mp3_320, destinationPath: "/tmp/test")
}
@Test func titlesKeepHyphensUnicodeAndDuplicateNames() async throws {
    let s = try await session()
    let titles = ["Love - Part II", "Și mâine", "Same", "Same", "Feat. Someone", "Six", "7 Years", "99 Luftballons"]
    let result = TracklistParser.parse(titles.joined(separator: "\n"), format: .titles, session: s)
    #expect(result.canApply)
    #expect(result.rows[0].title == titles[0])
    #expect(result.rows.allSatisfy { $0.artist.isEmpty })
    #expect(result.rows.map(\.number) == Array(1...8))
}
@Test func partialSelectionUsesPhysicalNumbersAndFullDiscList() async throws {
    let s = try await session([2, 7])
    let explicit = TracklistParser.parse("02. David Bowie & Queen — Under Pressure\n07. Queen - Love - Part II", format: .artistTitle, session: s)
    #expect(explicit.canApply)
    #expect(explicit.rows.map(\.number) == [2, 7])
    #expect(explicit.rows[1].title == "Love - Part II")
    #expect(!TracklistParser.parse("First\nSecond", format: .titles, session: s).canApply)
    let full = TracklistParser.parse((1...8).map { "Song \($0)" }.joined(separator: "\n"), format: .titles, session: s)
    #expect(full.canApply)
}
@Test func malformedTracklistRequiresCorrection() async throws {
    let s = try await session([2, 7])
    for text in ["2. A\n2. B", "2. A\n9. B", "2. A", "2. A\nB", ""] {
        #expect(!TracklistParser.parse(text, format: .titles, session: s).canApply)
    }
    #expect(!TracklistParser.parse("2. A\n7. B", format: .artistTitle, session: s).canApply)
}
@MainActor @Test func applyingTracklistKeepsSourceAndOtherMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
    var state = try await store.load()
    var s = try await session([2, 7]); s.tracks[0].supplied.album = "Album"
    state.sessions = [s]; state.selectedSessionID = s.id
    try await store.save(state)
    let model = AppModel(store: store); await model.bootstrap()
    let original = "2. Song Two\n\n7. Song Seven"
    let preview = TracklistParser.parse(original, format: .titles, session: s)
    await model.applyTracklist(preview.rows, original: original, commonArtist: "Queen", sessionID: s.id)
    let saved = try await store.load()
    #expect(saved.sessions[0].tracklist == original)
    #expect(saved.sessions[0].tracks.map(\.number) == [2, 7])
    #expect(saved.sessions[0].tracks[0].supplied.album == "Album")
    #expect(saved.sessions[0].tracks[0].supplied.artist.isEmpty)
    #expect(saved.sessions[0].effectiveArtist(for: saved.sessions[0].tracks[0]) == "Queen")
    #expect(saved.sessions[0].tracks.allSatisfy { $0.identification == .supplied && $0.evidence.isEmpty })
}
