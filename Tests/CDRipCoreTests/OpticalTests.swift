import Foundation
import Testing
@testable import CDRipCore

private func fixtureTOC(preEmphasis: Bool = false, dataTrack: Bool = false) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: ["Sessions": [["First Track": 1, "Last Track": 2, "Leadout Block": 36533, "Track Array": [
        ["Point": 1, "Start Block": 150, "Data": dataTrack, "Pre-Emphasis Enabled": preEmphasis],
        ["Point": 2, "Start Block": 16490, "Data": false, "Pre-Emphasis Enabled": false]
    ]]]], format: .xml, options: 0)
}

@Test func tocFramesIdentityAndUnsupportedMedia() throws {
    let a = try AudioTOC.parse(fixtureTOC(), device: "disk24", mountPath: "/Volumes/Audio CD")
    let b = try AudioTOC.parse(fixtureTOC(), device: "disk41", mountPath: "/Volumes/Audio CD 1")
    #expect(a.id == b.id)
    #expect(a.tracks[1].id == b.tracks[1].id)
    #expect(a.optical?.tracks[0].startSector == 0)
    #expect(a.optical?.tracks[0].sectorCount == 16340)
    #expect(a.tracks[1].duration == Double(20043) / 75)
    #expect(throws: ConnectionError.self) { try AudioTOC.parse(fixtureTOC(preEmphasis: true), device: "disk24", mountPath: "/Volumes/CD") }
    #expect(throws: ConnectionError.self) { try AudioTOC.parse(fixtureTOC(dataTrack: true), device: "disk24", mountPath: "/Volumes/CD") }
    #expect(throws: ConnectionError.self) { try AudioTOC.parse(fixtureTOC(), device: "disk1s1", mountPath: "/Volumes/CD") }
    let direct = CLIResult(code: 0, output: "  1.    16340 [03:37.65]        0 [00:00.00]    no   no  2\n  2.    20043 [04:27.18]    16340 [03:37.65]    no   no  2")
    try SecureOpticalRipper.validateTOC(direct, expected: a.optical!.tracks)
    #expect(throws: ConnectionError.self) { try SecureOpticalRipper.validateTOC(.init(code: 0, output: ""), expected: a.optical!.tracks) }
}

@Test func readReportNeverEquatesExitZeroWithVerifiedAudio() throws {
    let summary = "Using paranoia library version: 10.2+2.0.2 aarch64-apple-darwin25.6.0\n(== PROGRESS == [ | 016339 00 ] == :^D * ==)"
    let completed = "##: 0 [read] @ 1176\n##: 1 [verify] @ 1176\n##: 14 [wrote] @ 1176\n##: 15 [finished] @ 19215839\nDone."
    try ParanoiaReport.validate(code: 0, console: completed, summary: summary)
    for console in ["Done.", "", "##: 6 [skip] @ 1176\n" + completed, completed + "\nRead error", "##: 13 [cache error] @ 1176\n" + completed] {
        #expect(throws: ConnectionError.self) { try ParanoiaReport.validate(code: 0, console: console, summary: summary) }
    }
    #expect(throws: ConnectionError.self) { try ParanoiaReport.validate(code: 1, console: completed, summary: summary) }
    #expect(throws: ConnectionError.self) { try ParanoiaReport.validate(code: 0, console: completed, summary: "") }
}

@Test func missingHardwareDoesNotBlockSavedWorkspace() async throws {
    struct MissingSource: DiscSource {
        func loadDisc() async throws -> DiscDescriptor { throw ConnectionError("No disc") }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = await AppModel(store: JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")), source: MissingSource())
    await model.bootstrap()
    #expect(await model.isReady)
    #expect(await !model.persistenceFailed)
    #expect(await model.disc == nil)
}

@Test func cancelledProcessRetainsDiagnosticLog() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = root.appendingPathComponent("cancelled.log")
    let operation = Task {
        try await LocalCLIRunner().run(path: "/bin/sleep", arguments: ["30"], directory: root, timeout: .seconds(60), logURL: log)
    }
    try await Task.sleep(for: .milliseconds(200))
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(FileManager.default.fileExists(atPath: log.path))
}

// Explicit opt-in only. Reads track 1 and leaves the evidence under the caller's QA folder.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_LIVE_OPTICAL"] == "1"))
func liveSecureOpticalPipeline() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CDRIP_QA_DIRECTORY"]))
    let disc = try await MacOpticalSource().loadDisc()
    let first = try #require(disc.tracks.first)
    let session = RipSession(disc: disc, selectedIDs: [first.id], profile: .mp3AndFlac, destinationPath: root.path)
    actor Events {
        var all: [OpticalRipEvent] = []
        func add(_ value: OpticalRipEvent) { all.append(value) }
    }
    let events = Events()
    try await SecureOpticalRipper().rip(session) { await events.add($0) }
    let final = try #require(await events.all.last)
    #expect(final.phase == .awaitingVerification)
    #expect(final.paths.count == 2)
    #expect(final.integrity?.verification?.status == .accessPending)
    #expect(final.integrity?.requiresReview == true)
    for path in final.paths { #expect(FileManager.default.fileExists(atPath: path)) }
    #expect(try await MacOpticalSource().loadDisc().id == disc.id)
}

@Test func opticalLockRefusesASecondOwner() throws {
    let key = "test-\(UUID())"
    let first = try OpticalLock(device: key)
    defer { withExtendedLifetime(first) {} }
    #expect(throws: ConnectionError.self) { try OpticalLock(device: key) }
}

@Test func truncatedOrWrongLengthPCMIsRejected() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    var wav = Data("RIFF".utf8)
    func word(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    wav.append(word(40)); wav.append(Data("WAVEfmt ".utf8)); wav.append(word(16))
    wav.append(contentsOf: [1,0,2,0,68,172,0,0,16,177,2,0,4,0,16,0])
    wav.append(Data("data".utf8)); wav.append(word(4)); wav.append(contentsOf: [0,0,0,0])
    try wav.write(to: file)
    #expect(try SecureOpticalRipper.wavePCM(file, expectedBytes: 4).count == 4)
    #expect(throws: ConnectionError.self) { try SecureOpticalRipper.wavePCM(file, expectedBytes: 2352) }
    try wav.dropLast().write(to: file)
    #expect(throws: ConnectionError.self) { try SecureOpticalRipper.wavePCM(file, expectedBytes: 4) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_LIVE_CANCEL"] == "1"))
func liveOpticalCancellationRemountsAndKeepsLogs() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CDRIP_QA_DIRECTORY"]))
    let disc = try await MacOpticalSource().loadDisc()
    let first = try #require(disc.tracks.first)
    let session = RipSession(disc: disc, selectedIDs: [first.id], profile: .mp3_320, destinationPath: root.path)
    actor State {
        var reading = false
        func set(_ value: Bool) { reading = value }
    }
    let state = State()
    let task = Task { try await SecureOpticalRipper().rip(session) { event in if event.phase == .reading { await state.set(true) } } }
    let deadline = ContinuousClock.now + .seconds(60)
    while !(await state.reading) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
    let started = await state.reading
    try await Task.sleep(for: .seconds(2))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(started)
    #expect(try await MacOpticalSource().loadDisc().id == disc.id)
    let folder = RipFileRouting.internalDirectory.appendingPathComponent(session.id.uuidString)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Track 01/read-console.log").path))
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Track 01/Encoded").path))
}
