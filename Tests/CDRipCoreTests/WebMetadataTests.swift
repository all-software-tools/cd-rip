import Foundation
import Testing
@testable import CDRipCore

private func webFixture() -> (RipSession, SessionTrack, [String: Any]) {
    let source = SourceTrack(id: "track-2", number: 2, duration: 200)
    let disc = DiscDescriptor(id: "cd", title: "CD", source: .optical, tracks: [source])
    var session = RipSession(disc: disc, selectedIDs: [source.id], profile: .mp3_320, destinationPath: "/tmp/unused")
    session.tracks[0].supplied.artist = "Operator"; session.tracks[0].supplied.title = "Song"
    let tags: [String: Any] = ["title": "Song", "artist": "Source artist", "genre": "Disco", "album": NSNull(), "albumArtist": NSNull(), "year": NSNull()]
    let raw: [String: Any] = ["trackId": source.id, "tags": tags,
        "sources": [["url": "https://example.org/record", "title": "Record source", "fields": ["title", "artist", "genre", "duration"]]],
        "duration": 205, "versionNote": NSNull(), "conflicts": [], "explanation": "Source proposal; edition uncertain.",
        "covers": [["pageURL": "https://example.org/album", "imageURL": NSNull(), "description": "Possible compilation cover"]]]
    return (session, session.tracks[0], raw)
}
@Test func webMetadataRequiresPerFieldSourcesAndRetainsConflicts() throws {
    let (session, track, raw) = webFixture()
    let result = try AIWebMetadataContract.validate(.init(data: JSONSerialization.data(withJSONObject: raw)), session: session, track: track)
    #expect(result.decision.status == .conflict)
    #expect(result.decision.conflicts.count == 2)
    #expect(result.covers.count == 1)
    #expect(result.decision.missingFields.contains("album"))
    for key in ["sources", "trackId", "extra"] {
        var changed = raw
        changed[key] = key == "sources" ? [] as Any : "bad"
        #expect(throws: ConnectionError.self) { try AIWebMetadataContract.validate(.init(data: JSONSerialization.data(withJSONObject: changed)), session: session, track: track) }
    }
    var bad = raw; bad["covers"] = [["pageURL": "http://127.0.0.1/", "imageURL": NSNull(), "description": "bad"]]
    #expect(throws: ConnectionError.self) { try AIWebMetadataContract.validate(.init(data: JSONSerialization.data(withJSONObject: bad)), session: session, track: track) }
}
@Test func webResearchRequiresActualToolInvocation() throws {
    let (_, _, raw) = webFixture()
    let final = try JSONSerialization.data(withJSONObject: ["type": "result", "subtype": "success", "is_error": false, "structured_output": raw])
    let text = String(decoding: final, as: UTF8.self)
    #expect(throws: ConnectionError.self) { try AIMetadataProvider.parseWeb(.init(code: 0, output: text), provider: .claudeCLI) }
    let event = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch"}]}}"#
    #expect(try AIMetadataProvider.parseWeb(.init(code: 0, output: event + "\n" + text), provider: .claudeCLI).data.count > 0)
}
@Test func webPromptIncludesAlbumContextAndNoLocalPaths() throws {
    var (session, track, _) = webFixture()
    session.metadataReferenceURL = "https://example.org/compilation"
    track.proposed.coverPath = "/private/secret/cover.jpg"
    let prompt = try AIWebMetadataContract.prompt(session: session, track: track)
    #expect(prompt.contains("albumTracklist"))
    #expect(prompt.contains("example.org"))
    #expect(!prompt.contains("/private/secret"))
    #expect(prompt.contains("USE YOUR WEB SEARCH"))
    var settings = AppSettings()
    settings.aiProvider = .azureFoundry
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.aiProvider == .codexCLI)
}
private actor RecordingWebRunner: CLIRunning {
    let file: URL
    init(file: URL) { self.file = file }
    func run(path: String, arguments: [String], directory: URL, timeout: Duration) async throws -> CLIResult {
        let result = try await LocalCLIRunner().run(path: path, arguments: arguments, directory: directory, timeout: timeout)
        if arguments.contains("--output-schema") || arguments.contains("--json-schema") {
            // Keep only tool/result events for integration diagnosis, never auth output.
            let events = result.output.split(separator: "\n").filter { !$0.contains("\"type\":\"system\"") }
            try Data(events.joined(separator: "\n").utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return result
    }
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_LIVE_WEB_RESEARCH"] == "1"))
func explicitLiveCLIWebResearch() async throws {
    let env = ProcessInfo.processInfo.environment
    let file = URL(fileURLWithPath: try #require(env["CDRIP_SAVED_WORKSPACE"]))
    let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: file))
    var session = try #require(state.sessions.first { $0.id == state.selectedSessionID })
    session.metadataReferenceURL = env["CDRIP_WEB_REFERENCE_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? (env["CDRIP_WEB_REFERENCE_URL"] == nil ? "https://bazar.bg/obiava-54599931/2-x-cd-disco-serie-gold" : nil)
    let number = Int(env["CDRIP_WEB_TRACK"] ?? "1") ?? 1
    let track = try #require(session.tracks.first { $0.number == number })
    var settings = state.settings
    settings.aiProvider = env["CDRIP_WEB_PROVIDER"] == "codex" ? .codexCLI : .claudeCLI
    let output = URL(fileURLWithPath: try #require(env["CDRIP_WEB_RESULT"]))
    let runner = RecordingWebRunner(file: output.appendingPathExtension("events.jsonl"))
    let result = try await AIMetadataProvider(runner: runner).research(session: session, track: track, settings: settings)
    var review = AIReviewRecord(usedAI: true, inputHash: try AIMetadataContract.fingerprint(session: session, track: track, settings: settings),
        provider: settings.aiProvider, model: settings.metadataModel, promptVersion: AIWebMetadataContract.version, createdAt: Date(),
        decision: result.decision, candidate: result.candidate, inputTokens: result.inputTokens, outputTokens: result.outputTokens)
    review.webCovers = result.covers
    try JSONEncoder().encode(review).write(to: output, options: .atomic)
    print("LIVE WEB: \(settings.aiProvider.title), sources: \(result.candidate?.evidence.count ?? 0), cover proposals: \(result.covers.count), status: \(result.decision.status)")
    #expect(result.candidate?.evidence.isEmpty == false)
}

private struct ForbiddenCatalog: AIMetadataCatalog {
    func candidates(session: RipSession, track: SessionTrack) async throws -> [AIMetadataCandidate] {
        Issue.record("CLI web mode must not require MusicBrainz")
        throw CatalogUnavailable(status: 503)
    }
}
private actor FixtureWebResearcher: AIMetadataGenerating, WebMetadataGenerating {
    var calls = 0
    func generate(input: AIMetadataInput, settings: AppSettings, azureKey: String) async throws -> AIStructuredResponse {
        Issue.record("Legacy catalog reconciliation must not run in web mode")
        throw ConnectionError("unexpected")
    }
    func research(session: RipSession, track: SessionTrack, settings: AppSettings) async throws -> WebMetadataResult {
        calls += 1
        var (_, _, raw) = webFixture(); raw["trackId"] = track.id
        return try AIWebMetadataContract.validate(.init(data: JSONSerialization.data(withJSONObject: raw)), session: session, track: track)
    }
}
@MainActor @Test func webPipelineBypassesCatalogCachesAndPreservesDraftAndCoversAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
    var state = try await store.load()
    let (session, track, _) = webFixture()
    state.sessions = [session]; state.selectedSessionID = session.id
    let researcher = FixtureWebResearcher()
    try await store.save(state)
    let model = AppModel(store: store, aiCatalog: ForbiddenCatalog(), aiGenerator: researcher)
    await model.bootstrap()
    await model.startAIReview(trackIDs: [track.id])
    while model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await researcher.calls == 1)
    #expect(model.currentSession?.tracks[0].supplied == track.supplied)
    #expect(model.currentSession?.tracks[0].aiReview?.webCovers?.count == 1)
    await model.startAIReview(trackIDs: [track.id])
    while model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await researcher.calls == 1)
    await model.saveMetadataReferenceURL("https://example.org/edition", sessionID: session.id)
    #expect(!model.aiReviewIsCurrent(try #require(model.currentSession?.tracks[0]), session: try #require(model.currentSession)))
    let restored = try await store.load()
    #expect(restored.sessions[0].tracks[0].aiReview?.webCovers?.count == 1)
    #expect(restored.sessions[0].metadataReferenceURL == "https://example.org/edition")
    #expect(restored.sessions[0].tracks[0].outputPaths == track.outputPaths)
}
@MainActor @Test func importedCoverAppliesOnlySelectedDraftsAndRetainsOrigin() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
    var state = try await store.load()
    let disc = try await DemoDiscSource().loadDisc()
    let session = RipSession(disc: disc, selectedIDs: Set(disc.tracks.prefix(2).map(\.id)), profile: .mp3_320, destinationPath: root.path)
    state.sessions = [session]; state.selectedSessionID = session.id
    try await store.save(state)
    let file = root.appendingPathComponent("cover.jpg"); try Data([1]).write(to: file)
    let cover = ImportedCover(filePath: file.path, pageURL: "https://example.org/album", imageURL: "https://example.org/front.jpg", width: 500, height: 500, retrievedAt: Date())
    let model = AppModel(store: store); await model.bootstrap()
    await model.applyImportedCover(cover, sessionID: session.id, trackIDs: [session.tracks[0].id], replaceExisting: false)
    let restored = try await store.load()
    #expect(restored.sessions[0].tracks[0].supplied.coverPath == file.path)
    #expect(restored.sessions[0].tracks[1].supplied.coverPath == nil)
    #expect(restored.sessions[0].tracks[0].coverImport?.pageURL == cover.pageURL)
    #expect(restored.sessions[0].tracks[0].outputPaths.isEmpty)
}

@Test func unrelatedCoverSourcesDoNotRejectSupportedTrackMetadata() throws {
    let (session, track, original) = webFixture()
    var raw = original
    var sources = raw["sources"] as! [[String: Any]]
    sources.append(["url": "https://example.org/cover", "title": "", "fields": ["cover", "edition", "extra_annotation"]])
    sources.append(["url": "https://example.org/context", "title": "Context", "fields": []])
    sources.append(["url": "not a URL", "title": "Unused reference", "fields": []])
    raw["sources"] = sources
    let result = try AIWebMetadataContract.validate(.init(data: JSONSerialization.data(withJSONObject: raw)), session: session, track: track)
    #expect(result.candidate?.tags["artist"] == "Source artist")
    #expect(result.candidate?.evidence.count == 3)
    #expect(result.decision.explanation.contains("Ignored 1"))
    // Unrelated sources cannot authorize invented tags.
    sources[0]["fields"] = ["duration"]
    raw["sources"] = sources
    #expect(throws: ConnectionError.self) { try AIWebMetadataContract.validate(.init(data: JSONSerialization.data(withJSONObject: raw)), session: session, track: track) }
}
private actor OneInvalidTrackResearcher: AIMetadataGenerating, WebMetadataGenerating {
    var calls: [String] = []
    func generate(input: AIMetadataInput, settings: AppSettings, azureKey: String) async throws -> AIStructuredResponse { throw ConnectionError("Unexpected legacy route") }
    func research(session: RipSession, track: SessionTrack, settings: AppSettings) async throws -> WebMetadataResult {
        calls.append(track.id)
        if track.number == 1 { throw WebMetadataValidationError(message: "Missing source for this track", responseJSON: "{\"diagnostic\":true}") }
        var (_, _, raw) = webFixture(); raw["trackId"] = track.id
        return try AIWebMetadataContract.validate(.init(data: JSONSerialization.data(withJSONObject: raw)), session: session, track: track)
    }
}
@MainActor @Test func webBatchContinuesPastInvalidTrackAndDoesNotReuseOldCatalogStatuses() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
    var state = try await store.load()
    let disc = try await DemoDiscSource().loadDisc()
    var session = RipSession(disc: disc, selectedIDs: Set(disc.tracks.prefix(3).map(\.id)), profile: .mp3_320, destinationPath: root.path)
    for t in session.tracks.indices {
        session.tracks[t].supplied.artist = "Artist"; session.tracks[t].supplied.title = "Song"
        session.tracks[t].aiError = "The catalog is unavailable (HTTP 503). Please try again."
    }
    state.sessions = [session]; state.selectedSessionID = session.id; try await store.save(state)
    let researcher = OneInvalidTrackResearcher()
    let model = AppModel(store: store, aiCatalog: ForbiddenCatalog(), aiGenerator: researcher); await model.bootstrap()
    #expect(model.aiReviewLabel(session.tracks[0], session: session) == "Awaiting web review")
    await model.startAIReview(trackIDs: Set(session.tracks.map(\.id)))
    while model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await researcher.calls.count == 3)
    let saved = try #require(model.currentSession)
    #expect(saved.tracks[0].aiErrorStage == "ai")
    #expect(saved.tracks[0].aiRejectedResponse == "{\"diagnostic\":true}")
    #expect(saved.tracks[1].aiReview != nil && saved.tracks[2].aiReview != nil)
    #expect(saved.tracks[1].aiError == nil && saved.tracks[2].aiError == nil)
    #expect(model.aiProgressText.contains("1 track errors"))
    #expect(saved.tracks.map(\.supplied) == session.tracks.map(\.supplied))
    await model.startAIReview(trackIDs: Set(session.tracks.map(\.id)))
    while model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await researcher.calls.count == 4) // Successful tracks are reused, only failed track is retried.
}
