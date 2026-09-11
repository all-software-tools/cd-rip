import Foundation
import Testing
@testable import CDRipCore

private func pipelineWord(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func pipelineWAV(_ pcm: Data) -> Data {
    var wav = Data("RIFF".utf8) + pipelineWord(UInt32(pcm.count + 36)) + Data("WAVEfmt ".utf8) + pipelineWord(16)
    wav.append(contentsOf: [1,0,2,0,68,172,0,0,16,177,2,0,4,0,16,0])
    wav.append(Data("data".utf8)); wav.append(pipelineWord(UInt32(pcm.count))); wav.append(pcm)
    return wav
}
private struct PipelineSource: DiscSource {
    let disc: DiscDescriptor
    func loadDisc() async throws -> DiscDescriptor { disc }
}
private struct PipelineLookup: AccurateRipLookingUp {
    let result: AccurateRipLookup
    func lookup(_ disc: AccurateRipDiscID) async throws -> AccurateRipLookup { result }
}
private actor PipelineRunner: CLIRunning {
    let attempts: [Data]
    var reads = 0
    var remounted = false
    init(attempts: [Data]) { self.attempts = attempts }
    func run(path: String, arguments: [String], directory: URL, timeout: Duration) async throws -> CLIResult {
        if arguments.first == "info" {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Content": "CD_partition_scheme"], format: .xml, options: 0)
            return .init(code: 0, output: String(decoding: data, as: UTF8.self))
        }
        if arguments.first == "mount" { remounted = true; return .init(code: 0, output: "mounted") }
        if arguments.first == "unmount" { return .init(code: 0, output: "unmounted") }
        if arguments.contains("-Q") { return .init(code: 0, output: " 1. 12 [00:00.12] 0 [00:00.00] no no 2") }
        let pcm = attempts[min(reads, attempts.count - 1)]
        reads += 1
        let logIndex = try #require(arguments.firstIndex(of: "-l"))
        try Data("Using paranoia library version: 10.2+2.0.2\n:^D".utf8).write(to: URL(fileURLWithPath: arguments[logIndex + 1]))
        try pipelineWAV(pcm).write(to: URL(fileURLWithPath: try #require(arguments.last)))
        return .init(code: 0, output: "##: 0 [read] @ 0\n##: 1 [verify] @ 0\n##: 14 [wrote] @ 0\n##: 15 [finished] @ 0\nDone.")
    }
}
private actor PipelineEncoder: PCMEncoding {
    var calls = 0
    func encode(input: URL, profile: OutputProfile, trackNumber: Int, destination: URL) async throws -> [URL] {
        calls += 1
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = destination.appendingPathComponent("Track 01.mp3")
        // Tests routing/control flow only; real codec validation lives in OutputTests.
        try Data("encoded fixture".utf8).write(to: file)
        return [file]
    }
}
private actor PipelineEvents {
    var values: [OpticalRipEvent] = []
    func add(_ event: OpticalRipEvent) { values.append(event) }
}

@Test(arguments: ["match", "notFound", "unavailable", "pending", "disabled", "mismatch", "retryMatch", "cancel"])
func accurateRipPipelineKeepsMissingReferencesSeparateFromMismatch(_ scenario: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cdrip-ar-test-\(UUID())")
    let output = root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let track = SourceTrack(id: "1", number: 1, duration: 12.0 / 75)
    var disc = DiscDescriptor(id: "fixture", title: "Fixture", source: .optical, tracks: [track])
    disc.optical = .init(device: "test-\(UUID())", mountPath: root.path, tracks: [.init(number: 1, startSector: 0, sectorCount: 12)], driveID: "Fixture | Drive | 1")
    var session = RipSession(disc: disc, selectedIDs: ["1"], profile: .mp3_320, destinationPath: output.path)
    var settings = AppSettings()
    settings.audioVerification.driveOffsets["Fixture | Drive | 1"] = 6
    settings.outputFolders.deleteWAVAfterConversion = true
    session.settingsSnapshot = settings; session.outputFolders = settings.outputFolders
    let pcm = Data(repeating: 1, count: 12 * 2352), wrong = Data(repeating: 2, count: 12 * 2352)
    let sums = try AccurateRipChecksums.calculate(pcm: pcm, number: 1, trackCount: 1)
    let reference: AccurateRipLookup = .records([.init(tracks: [.init(confidence: 3, checksum: sums.v2, offsetChecksum: 0)])])
    let lookup: AccurateRipLookup
    switch scenario {
    case "notFound": lookup = .notFound
    case "unavailable": lookup = .unavailable("offline")
    case "pending": lookup = .accessPending
    case "disabled": lookup = .disabled
    default: lookup = reference
    }
    let runner = PipelineRunner(attempts: scenario == "mismatch" ? [wrong] : scenario == "retryMatch" ? [wrong, pcm] : [pcm])
    let encoder = PipelineEncoder(), events = PipelineEvents()
    let ripper = SecureOpticalRipper(runner: runner, encoder: encoder, backendPath: "/usr/bin/true", accurateRip: PipelineLookup(result: lookup), source: PipelineSource(disc: disc), evidenceRoot: root.appendingPathComponent("evidence"))
    do {
        try await ripper.rip(session) { event in
            await events.add(event)
            if scenario == "cancel", event.phase == .encoding { throw CancellationError() }
        }
        #expect(scenario != "cancel")
    } catch is CancellationError {
        #expect(scenario == "cancel")
        #expect(await runner.remounted)
        #expect(await encoder.calls == 0)
        let evidence = root.appendingPathComponent("evidence/\(session.id)/Track 01")
        #expect(try FileManager.default.contentsOfDirectory(atPath: evidence.path).contains { $0.hasSuffix(".wav") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        return
    }
    let final = try #require(await events.values.last)
    let integrity = try #require(final.integrity), verification = try #require(integrity.verification)
    #expect(await runner.remounted)
    #expect(verification.offsetSamples == 6)
    #expect(verification.offsetConfigured)
    #expect(await runner.reads == (scenario == "mismatch" || scenario == "retryMatch" ? 2 : 1))
    if scenario == "mismatch" {
        #expect(final.phase == .failed)
        #expect(verification.status == .mismatch)
        #expect(final.paths.isEmpty)
        #expect(await encoder.calls == 0)
        #expect(FileManager.default.fileExists(atPath: integrity.pcmPath))
        let evidence = root.appendingPathComponent("evidence/\(session.id)/Track 01")
        #expect(try FileManager.default.contentsOfDirectory(atPath: evidence.path).filter { $0.hasSuffix(".wav") }.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    } else {
        #expect(final.phase == .awaitingVerification)
        #expect(await encoder.calls == 1)
        #expect(final.paths.count == 1)
        #expect(FileManager.default.fileExists(atPath: try #require(final.paths.first)))
        #expect(integrity.pcmDeleted == true)
        #expect(!FileManager.default.fileExists(atPath: integrity.pcmPath))
        let verified = scenario == "match" || scenario == "retryMatch"
        #expect(integrity.requiresReview == !verified)
        if verified { #expect(verification.status == .verified) }
        if scenario == "notFound" { #expect(verification.status == .notInDatabase) }
        if scenario == "unavailable" { #expect(verification.status == .unavailable) }
    }
}

@Test func accurateRipRejectsWrongWAVFormatDespiteCorrectLength() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("ar-wav-\(UUID())")
    defer { try? FileManager.default.removeItem(at: file) }
    let valid = pipelineWAV(Data(repeating: 0, count: 4))
    for position in [20, 22, 24, 28, 32, 34] {
        var invalid = valid; invalid[position] ^= 1
        try invalid.write(to: file)
        #expect(throws: ConnectionError.self) { try SecureOpticalRipper.wavePCM(file, expectedBytes: 4) }
    }
}
