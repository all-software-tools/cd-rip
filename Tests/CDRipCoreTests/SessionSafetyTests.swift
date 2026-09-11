import Foundation
import Testing
@testable import CDRipCore

private func safetySession(root: URL) -> RipSession {
    let disc = DiscDescriptor(id: "disc", title: "Disc", source: .optical, tracks: [.init(id: "one", number: 1, duration: 1)])
    return RipSession(disc: disc, selectedIDs: ["one"], profile: .mp3_320, destinationPath: root.path)
}

@Test func staleWorkspaceWriterIsRejectedAndOwnerLeaseIsExclusive() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("workspace.json")
    do {
        let lease = try WorkspaceLease(fileURL: file)
        #expect(throws: ConnectionError.self) { try WorkspaceLease(fileURL: file) }
        withExtendedLifetime(lease) {}
    }
    let reopenedLease = try WorkspaceLease(fileURL: file)
    defer { withExtendedLifetime(reopenedLease) {} }
    let a = JSONWorkspaceStore(fileURL: file), b = JSONWorkspaceStore(fileURL: file)
    var first = try await a.load(), second = try await b.load()
    let one = safetySession(root: root), two = safetySession(root: root)
    first.sessions = [one]; second.sessions = [two]
    try await a.save(first)
    await #expect(throws: ConnectionError.self) { try await b.save(second) }
    #expect(try await JSONWorkspaceStore(fileURL: file).load().sessions.map(\.id) == [one.id])
}

@MainActor @Test func sessionSelectionRestoresSnapshotAndLegacyDestinationIndependentlyOfGlobalOutput() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var cd1 = safetySession(root: root.appendingPathComponent("CD1"))
    let cd2 = safetySession(root: root.appendingPathComponent("CD2"))
    var settings = AppSettings(); settings.destinationPath = cd1.destinationPath; settings.aiProvider = .claudeCLI; settings.claudeModel = "custom"; settings.outputFolders.deleteWAVAfterConversion = true
    cd1.settingsSnapshot = settings; cd1.outputFolders = settings.outputFolders
    let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
    var state = try await store.load(); state.sessions = [cd1, cd2]; state.selectedSessionID = cd2.id; state.settings.destinationPath = cd2.destinationPath
    try await store.save(state)
    let model = AppModel(store: store); await model.bootstrap(); await model.selectSession(cd1.id)
    #expect(model.workspace.settings.destinationPath == cd1.destinationPath)
    #expect(model.workspace.settings.claudeModel == "custom")
    #expect(model.workspace.settings.outputFolders.deleteWAVAfterConversion)
    var changed = model.workspace.settings; changed.destinationPath = cd2.destinationPath; changed.profile = .flac
    await model.updateSettings(changed)
    var tags = TrackMetadata(); tags.artist = "Artist"; tags.title = "Title"
    #expect(model.fileSaveDestination("/wrong/track.mp3", metadata: tags, session: cd1).path == root.appendingPathComponent("CD1/MP3/Artist - Title.mp3").path)
    await model.selectSession(cd2.id)
    #expect(model.workspace.settings.destinationPath == cd2.destinationPath)
    #expect(model.workspace.settings.profile == cd2.outputProfile)
    #expect(!model.workspace.settings.outputFolders.deleteWAVAfterConversion)
    await model.selectSession(cd1.id)
    #expect(model.workspace.settings.destinationPath == cd1.destinationPath)
    #expect(model.workspace.settings.profile == cd1.outputProfile)
}

@MainActor @Test func missingSavedMediaIsNotSkippedAndExternalChangesAreReported() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var session = safetySession(root: root)
    var tags = TrackMetadata(); tags.artist = "Artist"; tags.title = "Title"
    let media = root.appendingPathComponent("MP3/Artist - Title.mp3")
    session.tracks[0].supplied = tags; session.tracks[0].savedFileTags = tags
    session.tracks[0].phase = .awaitingVerification; session.tracks[0].outputPaths = [media.path]
    session.tracks[0].integrity = .init(backend: "TEST", pcmSHA256: "fixture", logPath: root.appendingPathComponent("log").path, pcmPath: root.appendingPathComponent("wav").path, accurateRip: "notChecked", offsetSamples: 0, readCompleted: true, requiresReview: true)
    let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
    var state = try await store.load(); state.sessions = [session]; state.selectedSessionID = session.id
    try await store.save(state)
    let model = AppModel(store: store); await model.bootstrap()
    #expect(!model.fileTagsAreCurrent(session.tracks[0], session: session))
    await model.saveTagsAndFilenames(sessionID: session.id, trackIDs: ["one"])
    while model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.currentSession?.tracks[0].fileTagError?.contains("missing") == true)
    #expect(!model.tagProgressText.contains("already saved"))
    try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture original".utf8).write(to: media)
    session.tracks[0].savedFileHashes = [media.path: try FileTagSaver.hash(media.path)]
    try Data("fixture changed".utf8).write(to: media)
    let issues = await FileTagSaver().checkFiles(session.tracks)
    #expect(issues[media.path]?.contains("changed outside") == true)
}

@MainActor @Test func pendingDraftsArePersistedBeforeQuitOrSessionSwitchAndRetainedOnFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = safetySession(root: root), b = safetySession(root: root)
    let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
    var state = try await store.load(); state.sessions = [a, b]; state.selectedSessionID = a.id; try await store.save(state)
    let model = AppModel(store: store); await model.bootstrap()
    var tags = TrackMetadata(); tags.title = "Unsaved title"; tags.genre = "Soul"
    model.stageMetadataEdit(tags, trackID: "one", sessionID: a.id)
    #expect(model.hasUnsavedMetadataEdits)
    await model.selectSession(b.id)
    #expect(!model.hasUnsavedMetadataEdits)
    let persisted = try await JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")).load()
    #expect(persisted.sessions[0].tracks[0].supplied == tags)
    tags.year = "1982"; model.stageMetadataEdit(tags, trackID: "one", sessionID: b.id)
    #expect(await model.flushMetadataEdits())
    let saved = try await store.load(); #expect(saved.sessions[1].tracks[0].supplied.year == "1982")
    let failed = AppModel(store: FailingDraftStore(state: state)); await failed.bootstrap()
    failed.stageMetadataEdit(tags, trackID: "one", sessionID: a.id)
    #expect(!(await failed.flushMetadataEdits()))
    #expect(failed.hasUnsavedMetadataEdits && failed.persistenceFailed)
    failed.discardAllMetadataEdits(); #expect(!failed.hasUnsavedMetadataEdits)
}

private actor FailingDraftStore: WorkspaceStoring {
    let state: WorkspaceState
    init(state: WorkspaceState) { self.state = state }
    func load() async throws -> WorkspaceState { state }
    func save(_ state: WorkspaceState) async throws { throw CocoaError(.fileWriteOutOfSpace) }
}
