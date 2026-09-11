import Foundation
import Testing
@testable import CDRipCore

private func fixture() async throws -> DiscDescriptor { try await DemoDiscSource().loadDisc() }
private func temporaryStore() -> (URL, JSONWorkspaceStore) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CDRip-tests-\(UUID())")
    return (folder, JSONWorkspaceStore(fileURL: folder.appendingPathComponent("workspace.json")))
}

@Test func partialSelectionPreservesTrackIdentityAndProfileSnapshot() async throws {
    let disc = try await fixture()
    var settings = AppSettings(); settings.profile = .mp3_320; settings.destinationPath = "/tmp/Radio music"
    let selected = Set([disc.tracks[1].id, disc.tracks[6].id])
    let session = RipSession(disc: disc, selectedIDs: selected, profile: settings.profile, destinationPath: settings.destinationPath)
    settings.profile = .flac; settings.destinationPath = "/another-folder"
    #expect(session.tracks.map(\.number) == [2, 7])
    #expect(Set(session.tracks.map(\.id)) == selected)
    #expect(session.outputProfile == .mp3_320)
    #expect(session.destinationPath == "/tmp/Radio music")
}

@Test func storeRoundtripIncludesSettingsSessionAndDrafts() async throws {
    let (folder, store) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: folder) }
    var state = try await store.load()
    state.settings.destinationPath = "/Volumes/Muzică/Arhivă"
    state.settings.profile = .mp3AndFlac
    let disc = try await fixture()
    var session = RipSession(disc: disc, selectedIDs: Set(disc.tracks.map(\.id)), profile: state.settings.profile, destinationPath: state.settings.destinationPath)
    session.tracklist = "1. Artist – Titlu cu diacritice: ȘȚĂ"
    session.commonArtist = "Artistul albumului"
    session.tracks[0].supplied.artist = "Artist diferit"
    session.tracks[0].supplied.albumArtist = "Various Artists"
    state.sessions = [session]; state.selectedSessionID = session.id
    try await store.save(state)
    let restored = try await JSONWorkspaceStore(fileURL: folder.appendingPathComponent("workspace.json")).load()
    #expect(restored == state)
}

@Test func futureVersionAndCorruptFileAreNeverOverwritten() async throws {
    for content in ["{\"schemaVersion\":999}", "not JSON"] {
        let (folder, store) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("workspace.json")
        try Data(content.utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await store.load() }
        await #expect(throws: (any Error).self) { try await store.save(WorkspaceState()) }
        #expect(try String(contentsOf: url, encoding: .utf8) == content)
    }
}

@Test func interruptedTracksRecoverWithoutClaimingSuccess() async throws {
    let (folder, store) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: folder) }
    var state = try await store.load()
    let disc = try await fixture()
    var session = RipSession(disc: disc, selectedIDs: Set(disc.tracks.map(\.id)), profile: .flac, destinationPath: "/tmp/output")
    session.tracks[0].phase = .ripped; session.tracks[0].progress = 1
    session.tracks[1].phase = .encoding; session.tracks[1].progress = 0.7
    state.sessions = [session]
    try await store.save(state)
    let recovered = try await store.load()
    #expect(recovered.sessions[0].tracks[0].phase == .ripped)
    #expect(recovered.sessions[0].tracks[1].phase == .cancelled)
    #expect(recovered.sessions[0].tracks[2].phase == .pending)
    #expect(!recovered.sessions[0].hasFinishedSimulation)
}

@MainActor @Test func simulatedWorkflowPersistsAndMakesNoMediaOrAIClaims() async throws {
    let (folder, store) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: store, ripper: DemoRippingService(delay: .zero))
    await model.bootstrap()
    #expect(model.isReady)
    #expect(!model.canStart)
    var settings = model.workspace.settings; settings.destinationPath = folder.appendingPathComponent("untouched-output").path
    await model.updateSettings(settings)
    model.selectedTrackIDs = Set([try #require(model.disc?.tracks[1].id)])
    await model.startSimulation()
    await model.startSimulation() // Double start must not duplicate the session.
    let deadline = ContinuousClock.now + .seconds(3)
    while model.isBusy && ContinuousClock.now < deadline { await Task.yield() }
    #expect(!model.isBusy)
    #expect(model.workspace.sessions.count == 1)
    #expect(model.currentSession?.tracks.map(\.number) == [2])
    #expect(model.currentSession?.hasFinishedSimulation == true)
    #expect(model.currentSession?.tracks[0].identification == .notChecked)
    #expect(model.currentSession?.tracks[0].outputPaths.isEmpty == true)
    #expect(!FileManager.default.fileExists(atPath: settings.destinationPath))
    var draft = TrackMetadata(); draft.title = "Test"; draft.artist = "Artist"; draft.albumArtist = "Compilație"
    await model.saveMetadata(draft, trackID: try #require(model.currentSession?.tracks[0].id))
    let restored = try await store.load()
    #expect(restored.sessions[0].tracks[0].supplied.title == "Test")
    #expect(restored.sessions[0].tracks[0].identification == .supplied)
    #expect(restored.sessions[0].tracks[0].evidence.isEmpty)
}

@MainActor @Test func cancelStopsWorkerAndPersistsIncompleteState() async throws {
    let (folder, store) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: store, ripper: DemoRippingService(delay: .milliseconds(100)))
    await model.bootstrap()
    var settings = AppSettings(); settings.destinationPath = "/tmp/example"
    await model.updateSettings(settings)
    await model.startSimulation()
    await model.cancelAndWait()
    #expect(!model.isBusy)
    #expect(model.currentSession?.hasFinishedSimulation == false)
    #expect(model.currentSession?.tracks.allSatisfy { $0.phase == .cancelled } == true)
    let restored = try await store.load()
    #expect(restored.sessions[0].tracks.allSatisfy { $0.phase == .cancelled })
}

@MainActor @Test func invalidSelectionDoesNotCreateSession() async throws {
    let (folder, store) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(store: store)
    await model.bootstrap()
    var settings = AppSettings(); settings.destinationPath = "/tmp/example"
    await model.updateSettings(settings)
    model.selectedTrackIDs = ["not-in-this-disc"]
    await model.startSimulation()
    #expect(model.workspace.sessions.isEmpty)
    #expect(model.message != nil)
}

@Test func unconfiguredIntegrationsFailExplicitly() async {
    await #expect(throws: (any Error).self) { try await UnconfiguredRecognition().identify(audioURL: URL(fileURLWithPath: "/tmp/no.mp3")) }
    await #expect(throws: (any Error).self) { try await UnconfiguredTagWriter().apply(metadata: TrackMetadata(), to: URL(fileURLWithPath: "/tmp/no.mp3")) }
}

@MainActor @Test func delayedDraftSavesStayInOriginalSession() async throws {
    let (folder, store) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: folder) }
    var state = try await store.load()
    let disc = try await fixture()
    let first = RipSession(disc: disc, selectedIDs: [disc.tracks[0].id], profile: .mp3_320, destinationPath: "/tmp/a")
    let second = RipSession(disc: disc, selectedIDs: [disc.tracks[0].id], profile: .flac, destinationPath: "/tmp/b")
    state.sessions = [first, second]; state.selectedSessionID = second.id
    try await store.save(state)
    let model = AppModel(store: store)
    await model.bootstrap()
    var draft = TrackMetadata(); draft.title = "Only first session"
    await model.saveMetadata(draft, trackID: disc.tracks[0].id, sessionID: first.id)
    await model.saveTracklist("First session list", sessionID: first.id)
    #expect(model.currentSession?.id == second.id)
    #expect(model.currentSession?.tracks[0].supplied.title == "")
    #expect(model.currentSession?.tracklist == "")
    #expect(model.workspace.sessions[0].tracks[0].supplied.title == "Only first session")
}

private actor FailingStore: WorkspaceStoring {
    func load() async throws -> WorkspaceState { WorkspaceState() }
    func save(_ state: WorkspaceState) async throws { throw CocoaError(.fileWriteOutOfSpace) }
}

@MainActor @Test func failedPersistenceBlocksSimulation() async {
    let model = AppModel(store: FailingStore())
    await model.bootstrap()
    var settings = AppSettings(); settings.destinationPath = "/tmp/test"
    await model.updateSettings(settings)
    #expect(model.persistenceFailed)
    #expect(!model.canStart)
    await model.startSimulation()
    #expect(model.workspace.sessions.isEmpty)
}

@Test func commonAlbumArtistFillsOnlyMissingTrackArtists() async throws {
    let disc = try await fixture()
    var session = RipSession(disc: disc, selectedIDs: Set(disc.tracks.map(\.id)), profile: .mp3_320, destinationPath: "/tmp/demo")
    session.commonArtist = "Queen"
    session.tracks[1].supplied.artist = "David Bowie & Queen"
    #expect(session.effectiveArtist(for: session.tracks[0]) == "Queen")
    #expect(session.effectiveArtist(for: session.tracks[1]) == "David Bowie & Queen")
    session.commonArtist = "Alt artist"
    #expect(session.effectiveArtist(for: session.tracks[0]) == "Alt artist")
    #expect(session.effectiveArtist(for: session.tracks[1]) == "David Bowie & Queen")
    #expect(session.tracks[0].supplied.artist.isEmpty) // Inheritance must not erase provenance.
}

@Test func schemaOneWithoutCommonArtistStillLoads() async throws {
    let (folder, store) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: folder) }
    var state = try await store.load()
    let disc = try await fixture()
    state.sessions = [RipSession(disc: disc, selectedIDs: [disc.tracks[0].id], profile: .mp3_320, destinationPath: "/tmp/demo")]
    try await store.save(state)
    let data = try Data(contentsOf: folder.appendingPathComponent("workspace.json"))
    #expect(!String(decoding: data, as: UTF8.self).contains("commonArtist"))
    let loaded = try await store.load()
    #expect(loaded.sessions[0].commonArtist == nil)
}

@MainActor @Test func backgroundRefreshKeepsControlsEnabledAndSelectionIntact() async throws {
    actor ControlledSource: DiscSource {
        var continuation: CheckedContinuation<DiscDescriptor, Error>?
        var shouldWait = false
        var waiting: Bool { continuation != nil }
        func pause() { shouldWait = true }
        func loadDisc() async throws -> DiscDescriptor {
            if shouldWait { return try await withCheckedThrowingContinuation { continuation = $0 } }
            return try await DemoDiscSource().loadDisc()
        }
        func finish(missing: Bool = false) async throws {
            let value = continuation; continuation = nil; shouldWait = false
            if missing { value?.resume(throwing: ConnectionError("CD scos")) }
            else { value?.resume(returning: try await DemoDiscSource().loadDisc()) }
        }
    }
    let (folder, store) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = ControlledSource()
    let model = AppModel(store: store, source: source)
    await model.bootstrap()
    var settings = model.workspace.settings; settings.destinationPath = folder.path
    await model.updateSettings(settings)
    model.selectAllTracks(false)
    #expect(!model.allTracksSelected)
    model.selectAllTracks(true)
    #expect(model.allTracksSelected)
    let selected = try #require(model.disc?.tracks.first?.id)
    model.selectedTrackIDs = [selected]
    #expect(!model.allTracksSelected)
    await source.pause()
    let refresh = Task { await model.refreshSource(background: true) }
    while !(await source.waiting) { await Task.yield() }
    #expect(!model.isDetecting)
    #expect(model.canStart)
    try await source.finish()
    await refresh.value
    #expect(model.selectedTrackIDs == [selected])
    #expect(model.canStart)
    await source.pause()
    let removal = Task { await model.refreshSource(background: true) }
    while !(await source.waiting) { await Task.yield() }
    let manual = Task { await model.refreshSource() }
    while !model.isDetecting { await Task.yield() }
    try await source.finish(missing: true)
    await removal.value
    await manual.value
    #expect(model.disc != nil) // Manual Detect retries after the background failure.
    #expect(!model.isDetecting)
    await source.pause()
    let finalRemoval = Task { await model.refreshSource(background: true) }
    while !(await source.waiting) { await Task.yield() }
    try await source.finish(missing: true)
    await finalRemoval.value
    #expect(model.disc == nil)
    #expect(!model.canStart)
    #expect(!model.allTracksSelected)
}
