import Foundation
import Testing
@testable import CDRipCore

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
func fileTagSaveRenamesEmbedsTagsRecoversAndPreservesAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CDRip-file-save-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let wav = root.appendingPathComponent("source.wav")
    let process = try await LocalCLIRunner().run(path: "/opt/homebrew/bin/ffmpeg", arguments: ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=500:sample_rate=44100:duration=1", "-ac", "2", "-c:a", "pcm_s16le", wav.path], directory: root, timeout: .seconds(10))
    #expect(process.code == 0)
    let inputs = try await PCMEncoder().encode(input: wav, profile: .mp3AndFlac, trackNumber: 7, destination: root.appendingPathComponent("Encoded"))
    let originals = try inputs.map { try Data(contentsOf: $0) }
    var tags = TrackMetadata(); tags.artist = "Artist Ș"; tags.title = "Song / title"
    let saver = FileTagSaver()
    let interrupted = try await saver.prepare(metadata: tags, number: 7, total: 15, inputs: inputs)
    let first = interrupted.files[0]
    try FileManager.default.moveItem(atPath: first.original, toPath: first.backup)
    try FileManager.default.moveItem(atPath: first.staged, toPath: first.output)
    #expect(try await saver.recover(interrupted) == false)
    #expect(try inputs.map { try Data(contentsOf: $0) } == originals)
    let plan = try await saver.prepare(metadata: tags, number: 7, total: 15, inputs: inputs)
    try await saver.commit(plan)
    #expect(try await saver.recover(plan))
    #expect(plan.files.allSatisfy { URL(fileURLWithPath: $0.output).lastPathComponent.hasPrefix("Artist Ș - Song _ title.") })
    #expect(plan.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.original) })
    #expect(try plan.files.map { try Data(contentsOf: URL(fileURLWithPath: $0.backup)) } == originals)
    for file in plan.files {
        let result = try await LocalCLIRunner().run(path: "/opt/homebrew/bin/ffprobe", arguments: ["-v", "error", "-show_format", "-of", "json", file.output], directory: root, timeout: .seconds(10))
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let format = try #require(object["format"] as? [String: Any]); let raw = try #require(format["tags"] as? [String: String])
        let values = Dictionary(raw.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(values["artist"] == tags.artist && values["title"] == tags.title)
        #expect(values["track"] == "7/15")
    }
    // Saving another revision at the same filename must preserve the prior version in backups.
    tags.genre = "Disco"
    let second = try await saver.prepare(metadata: tags, number: 7, total: 15, inputs: plan.files.map { URL(fileURLWithPath: $0.output) })
    try await saver.commit(second)
    #expect(try await saver.recover(second))
    // Name collisions must never overwrite another file.
    tags.title = "Occupied"
    let occupied = inputs[0].deletingLastPathComponent().appendingPathComponent(FileTagSaver.filename(metadata: tags, extension: "mp3"))
    try Data("Existing unrelated file".utf8).write(to: occupied)
    await #expect(throws: ConnectionError.self) { try await saver.prepare(metadata: tags, number: 7, total: 15, inputs: second.files.map { URL(fileURLWithPath: $0.output) }) }
    #expect(try String(contentsOf: occupied, encoding: .utf8) == "Existing unrelated file")
    let current = second.files.map { URL(fileURLWithPath: $0.output) }
    let targets = current.map { root.appendingPathComponent("Clean " + $0.pathExtension).appendingPathComponent($0.lastPathComponent) }
    let clean = try await saver.prepare(metadata: second.revision.metadata, number: 7, total: 15, inputs: current, destinations: targets, backupRoot: root.appendingPathComponent("Private backups"))
    // Crash after replacing only one format; untouched originals already have copied backups.
    try FileManager.default.removeItem(atPath: clean.files[0].original)
    try FileManager.default.moveItem(atPath: clean.files[0].staged, toPath: clean.files[0].output)
    #expect(try await saver.recover(clean) == false)
    #expect(current.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(targets.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    try await verifyFileSaveModel(root: root, inputs: second.files.map { URL(fileURLWithPath: $0.output) })
}
@MainActor private func verifyFileSaveModel(root: URL, inputs: [URL]) async throws {
    let source = SourceTrack(id: "physical-7", number: 7, duration: 1)
    let disc = DiscDescriptor(id: "fixture", title: "Fixture", source: .optical, tracks: (1...7).map { SourceTrack(id: "physical-\($0)", number: $0, duration: 1) })
    var session = RipSession(disc: disc, selectedIDs: [source.id], profile: .mp3AndFlac, destinationPath: root.appendingPathComponent("Final").path)
    session.tracks[0].phase = .awaitingVerification; session.tracks[0].outputPaths = inputs.map(\.path)
    session.tracks[0].integrity = RipIntegrity(backend: "TEST", pcmSHA256: "fixture", logPath: root.appendingPathComponent("report.log").path, pcmPath: root.appendingPathComponent("source.wav").path, accurateRip: "notChecked", offsetSamples: 0, readCompleted: true, requiresReview: true)
    var state = WorkspaceState()
    state.settings.destinationPath = root.appendingPathComponent("Final").path
    try FileManager.default.createDirectory(atPath: state.settings.destinationPath, withIntermediateDirectories: true)
    state.settings.outputFolders.mp3Path = "/ignored-legacy-mp3"
    state.settings.outputFolders.flacPath = "/ignored-legacy-flac"
    state.sessions = [session]; state.selectedSessionID = session.id
    let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")); _ = try await store.load(); try await store.save(state)
    let model = AppModel(store: store, fileBackupRoot: root.appendingPathComponent("InternalBackups")); await model.bootstrap()
    var otherSettings = model.workspace.settings; otherSettings.destinationPath = root.appendingPathComponent("CD2").path
    try FileManager.default.createDirectory(atPath: otherSettings.destinationPath, withIntermediateDirectories: true)
    await model.updateSettings(otherSettings)
    let rows = [TracklistRow(line: 1, number: 7, artist: "", title: "Reviewed title")]
    await model.applyTracklist(rows, original: "7. Reviewed title", commonArtist: "Shared artist", sessionID: session.id)
    await model.saveTagsAndFilenames(sessionID: session.id, trackIDs: [source.id])
    while model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    let saved = try #require(model.currentSession); let track = saved.tracks[0]
    #expect(track.fileTagError == nil)
    for path in track.outputPaths {
        let file = URL(fileURLWithPath: path)
        #expect(file.deletingLastPathComponent() == root.appendingPathComponent("Final").appendingPathComponent(file.pathExtension.uppercased()))
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == [file.lastPathComponent])
    }
    #expect(model.fileTagsAreCurrent(track, session: saved))
    #expect(track.outputPaths.allSatisfy { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("Shared artist - Reviewed title.") })
    #expect(track.integrity?.requiresReview == true)
    #expect(track.phase == .awaitingVerification)
    await model.saveTagsAndFilenames(sessionID: session.id, trackIDs: [source.id])
    while model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.currentSession?.tracks[0].tagRevisions?.count == 1)
    // Simulate a crash after committed files but before the workspace checkpoint.
    var reopened = try await store.load()
    var newTags = track.savedFileTags!; newTags.title = "Recovered title"
    let saver = FileTagSaver(); let plan = try await saver.prepare(metadata: newTags, number: 7, total: 7, inputs: track.outputPaths.map { URL(fileURLWithPath: $0) })
    reopened.sessions[0].tracks[0].pendingFileTagSave = plan; try await store.save(reopened)
    try await saver.commit(plan)
    let recovered = AppModel(store: store, fileBackupRoot: root.appendingPathComponent("InternalBackups")); await recovered.bootstrap()
    #expect(recovered.isReady && !recovered.persistenceFailed)
    #expect(recovered.currentSession?.tracks[0].outputPaths == plan.revision.outputPaths)
    #expect(recovered.currentSession?.tracks[0].pendingFileTagSave == nil)
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_LIVE_COPIED_FILE_SAVE"] == "1"))
func explicitSaveTagsOnCopiedRealTrack() async throws {
    let env = ProcessInfo.processInfo.environment
    let input = URL(fileURLWithPath: try #require(env["CDRIP_SAVED_WORKSPACE"]))
    let root = URL(fileURLWithPath: try #require(env["CDRIP_FILE_SAVE_QA"]))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: input))
    var session = try #require(original.sessions.first { $0.id == original.selectedSessionID })
    let track = try #require(session.tracks.first)
    let hashes = try track.outputPaths.map { try FileTagSaver.hash($0) }
    var copied = track
    copied.outputPaths = try track.outputPaths.map { path in
        let source = URL(fileURLWithPath: path)
        let folder = root.appendingPathComponent(source.pathExtension.uppercased()); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: target)
        return target.path
    }
    copied.pendingFileTagSave = nil; copied.savedFileTags = nil; copied.tagRevisions = nil
    session.tracks = [copied]
    var workspace = WorkspaceState(); workspace.settings.destinationPath = root.path; workspace.sessions = [session]; workspace.selectedSessionID = session.id
    let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")); _ = try await store.load(); try await store.save(workspace)
    let model = AppModel(store: store, fileBackupRoot: root.appendingPathComponent("InternalBackups")); await model.bootstrap()
    await model.saveTagsAndFilenames(sessionID: session.id, trackIDs: [track.id])
    while model.isBusy { try await Task.sleep(for: .milliseconds(50)) }
    let result = try #require(model.currentSession?.tracks.first)
    #expect(result.fileTagError == nil)
    #expect(result.pendingFileTagSave == nil)
    #expect(result.savedFileTags?.artist == session.effectiveArtist(for: copied))
    #expect(result.outputPaths.allSatisfy { !URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("01") })
    #expect(try track.outputPaths.map { try FileTagSaver.hash($0) } == hashes)
    print("REAL COPY FILE SAVE: " + result.outputPaths.joined(separator: " | "))
    print("REAL COPY FILE SAVE: artist/title embedded and payload/PCM verified by writer; original user files unchanged.")
}
