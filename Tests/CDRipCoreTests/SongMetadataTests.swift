import Foundation
import AppKit
import Testing
@testable import CDRipCore

private struct SongResearchFixture: AIMetadataGenerating, WebMetadataGenerating {
    var delay = false
    var failID: String? = nil
    func generate(input: AIMetadataInput, settings: AppSettings, azureKey: String) async throws -> AIStructuredResponse { throw ConnectionError("Not used") }
    func research(session: RipSession, track: SessionTrack, settings: AppSettings) async throws -> WebMetadataResult {
        if delay { try await Task.sleep(for: .seconds(30)) }
        if track.id == failID { throw ConnectionError("Fixture request failed") }
        let tags: [String: Any] = ["title": NSNull(), "artist": NSNull(), "year": "1978", "genre": "Disco", "album": "Source album", "albumArtist": track.supplied.artist]
        let raw: [String: Any] = ["trackId": track.id, "tags": tags,
            "sources": [["url": "https://example.org/release", "title": "Release source", "fields": AIMetadataContract.fields]],
            "duration": NSNull(), "versionNote": NSNull(), "conflicts": [], "explanation": "Original release metadata, not the compilation date.",
            "covers": [["pageURL": "https://example.org/release", "imageURL": "https://example.org/cover.png", "description": "Album cover"],
                       ["pageURL": "https://example.org/artist", "imageURL": "https://example.org/artist.png", "description": "Artist photo fallback, not an album cover"]]]
        return try AIWebMetadataContract.validate(.init(data: JSONSerialization.data(withJSONObject: raw)), session: session, track: track)
    }
}
private actor SongImageHTTP: CoverFetching {
    let png: Data
    var paths: [String] = []
    init(png: Data) { self.png = png }
    func get(_ url: URL) async throws -> CoverResource {
        paths.append(url.path)
        if url.path == "/cover.png" { throw ConnectionError("Cover unavailable") }
        return CoverResource(data: png, url: url, mimeType: "image/png")
    }
}
@MainActor @Test func songLookupFillsDraftPreservesManualFieldsAndUsesArtistPhotoFallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("unchanged.mp3")
    let original = Data("audio must not be touched by research".utf8); try original.write(to: file)
    let source = SourceTrack(id: "song", number: 1, duration: 200)
    let disc = DiscDescriptor(id: "disc", title: "Compilation", source: .optical, tracks: [source])
    var session = RipSession(disc: disc, selectedIDs: [source.id], profile: .mp3_320, destinationPath: root.path)
    session.tracks[0].supplied.artist = "Artist"; session.tracks[0].supplied.title = "Song"; session.tracks[0].supplied.genre = "My manual style"
    session.tracks[0].outputPaths = [file.path]
    var state = WorkspaceState(); state.sessions = [session]; state.selectedSessionID = session.id; state.settings.aiProvider = .claudeCLI
    let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")); _ = try await store.load(); try await store.save(state)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 50, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let http = SongImageHTTP(png: try #require(bitmap.representation(using: .png, properties: [:])))
    let loader = SongCoverLoader(service: CoverImportService(http: http), directory: root.appendingPathComponent("Covers"))
    let model = AppModel(store: store, aiGenerator: SongResearchFixture(), songCoverLoader: loader); await model.bootstrap()
    await model.findSongMetadata(trackID: source.id, sessionID: session.id)
    while model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    let track = try #require(model.currentSession?.tracks.first)
    #expect(track.supplied.year == "1978")
    #expect(track.supplied.album == "Source album")
    #expect(track.supplied.genre == "My manual style")
    #expect(track.supplied.title == "Song" && track.supplied.artist == "Artist")
    #expect(track.coverImport?.imageURL == "https://example.org/artist.png")
    #expect(await http.paths == ["/cover.png", "/artist.png"])
    #expect(track.aiReviewAppliedAt != nil && track.aiReview?.promptVersion == AIWebMetadataContract.songVersion)
    #expect(track.savedFileTags == nil && track.tagRevisions == nil)
    #expect(try Data(contentsOf: file) == original)
    #expect(try await store.load().sessions[0].tracks[0].supplied == track.supplied)
    let prompt = try AIWebMetadataContract.prompt(session: session, track: session.tracks[0], songLookup: true)
    #expect(prompt.contains("original release year"))
    #expect(prompt.contains("2–3 web actions"))
    #expect(!prompt.contains("albumTracklist"))
    var covered = session.tracks[0]; covered.supplied.coverPath = "/private/cover.jpg"
    let coveredPrompt = try AIWebMetadataContract.prompt(session: session, track: covered, songLookup: true)
    #expect(coveredPrompt.contains("\"needsImage\":false"))
    #expect(!coveredPrompt.contains("/private/cover.jpg"))
    #expect(prompt.contains("artist-photo fallback"))
    #expect(!prompt.contains("Leave album/albumArtist/year null when the CD edition is uncertain"))
    let calls = model.currentSession?.aiCallCount
    await model.findSongMetadata(trackID: source.id, sessionID: session.id)
    while model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.currentSession?.aiCallCount == calls)
    // A cancelled request cannot fill fields or touch audio.
    try await store.save(state)
    let cancelled = AppModel(store: store, aiGenerator: SongResearchFixture(delay: true), songCoverLoader: loader); await cancelled.bootstrap()
    await cancelled.findSongMetadata(trackID: source.id, sessionID: session.id)
    await cancelled.cancelAndWait()
    #expect(cancelled.currentSession?.tracks[0].supplied == session.tracks[0].supplied)
    #expect(try Data(contentsOf: file) == original)
    // Batch lookup continues after a failed song and keeps successful drafts.
    let batchSources = (1...3).map { SourceTrack(id: "batch-\($0)", number: $0, duration: 200) }
    let batchDisc = DiscDescriptor(id: "batch-disc", title: "Compilation", source: .optical, tracks: batchSources)
    var batch = RipSession(disc: batchDisc, selectedIDs: Set(batchSources.map(\.id)), profile: .mp3_320, destinationPath: root.path)
    for i in batch.tracks.indices {
        batch.tracks[i].supplied.artist = "Artist"; batch.tracks[i].supplied.title = "Song \(i)"
        batch.tracks[i].outputPaths = [file.path]
    }
    state.sessions = [batch]; state.selectedSessionID = batch.id
    try await store.save(state)
    let all = AppModel(store: store, aiGenerator: SongResearchFixture(failID: "batch-2"), songCoverLoader: loader); await all.bootstrap()
    await all.findAllSongMetadata(sessionID: batch.id)
    while all.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    let result = try #require(all.currentSession)
    #expect(result.tracks[0].supplied.year == "1978")
    #expect(result.tracks[1].aiError != nil && result.tracks[1].supplied.year.isEmpty)
    #expect(result.tracks[2].supplied.year == "1978")
    #expect(result.aiCallCount == 3)
    #expect(result.tracks.allSatisfy { $0.savedFileTags == nil && $0.tagRevisions == nil })
    #expect(try Data(contentsOf: file) == original)
    // A retry skips completed songs and spends one call on the failed one only.
    await all.findAllSongMetadata(sessionID: batch.id)
    while all.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(all.currentSession?.aiCallCount == 4)
    #expect(all.aiProgressText.contains("2 already complete"))

}
