import Foundation
import Testing
@testable import CDRipCore

private func arWord(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func arDisc() throws -> AccurateRipDiscID {
    try .init(tracks: (0..<3).map { .init(number: $0 + 1, startSector: $0 * 10000, sectorCount: 10000) })
}
private func arRecord(_ disc: AccurateRipDiscID, checksum: UInt32, offset: UInt32 = 0, confidence: UInt8 = 4) -> Data {
    var data = Data([UInt8(disc.trackCount)])
    for value in [disc.id1, disc.id2, disc.cddb] { data.append(arWord(value)) }
    for _ in 0..<disc.trackCount { data.append(confidence); data.append(arWord(checksum)); data.append(arWord(offset)) }
    return data
}

@Test func accurateRipDiscIdentityUsesFullPhysicalTOC() throws {
    let disc = try arDisc()
    #expect(disc.id1 == 60000)
    #expect(disc.id2 == 200001)
    // Track starts: 2, 135, 268 seconds; digit sums 2 + 9 + 16; duration 400 seconds.
    #expect(disc.cddb == 0x1b019003)
    #expect(disc.url.absoluteString == "https://www.accuraterip.com/accuraterip/0/6/a/dBAR-003-0000ea60-00030d41-1b019003.bin")
    #expect(throws: ConnectionError.self) { try AccurateRipDiscID(tracks: [.init(number: 2, startSector: 0, sectorCount: 300)]) }
    #expect(throws: ConnectionError.self) { try AccurateRipDiscID(tracks: [.init(number: 1, startSector: 0, sectorCount: 100), .init(number: 2, startSector: 101, sectorCount: 100)]) }
}

@Test func accurateRipChecksumsUseStereoWordsOverflowAndPhysicalEdges() throws {
    let words = arWord(0xffffffff) + arWord(0xffffffff) + arWord(0xffffffff)
    let sums = try AccurateRipChecksums.calculate(pcm: words, number: 2, trackCount: 3)
    #expect(sums.v1 == 0xfffffffa)
    #expect(sums.v2 == 0xfffffffd)
    let endian = try AccurateRipChecksums.calculate(pcm: Data([1,2,3,4]), number: 2, trackCount: 3)
    #expect(endian.v1 == 0x04030201)
    var boundary = Data(repeating: 0, count: 6000 * 4)
    for (frame, word) in [(2938, UInt32(7)), (2939, 11), (3059, 13), (3060, 17)] {
        boundary.replaceSubrange(frame*4..<frame*4+4, with: arWord(word))
    }
    let only = try AccurateRipChecksums.calculate(pcm: boundary, number: 1, trackCount: 1)
    #expect(only.v1 == 11 * 2940 + 13 * 3060)
    let first = try AccurateRipChecksums.calculate(pcm: boundary, number: 1, trackCount: 2)
    #expect(first.v1 == only.v1 + 17 * 3061)
    let last = try AccurateRipChecksums.calculate(pcm: boundary, number: 2, trackCount: 2)
    #expect(last.v1 == only.v1 + 7 * 2939)
    #expect(throws: ConnectionError.self) { try AccurateRipChecksums.calculate(pcm: Data([1]), number: 2, trackCount: 3) }
}

@Test func accurateRipRecordsRejectWrongDiscTruncationAndFalseVersionTwo() throws {
    let disc = try arDisc(), sums = AccurateRipChecksums(v1: 101, v2: 202)
    let offsetOnly = try AccurateRipRecords.parse(arRecord(disc, checksum: 303, offset: 202), disc: disc)
    #expect(try AccurateRipVerifier.verify(sums, disc: disc, number: 2, lookup: .records(offsetOnly)).status == .mismatch)
    let pressings = try AccurateRipRecords.parse(arRecord(disc, checksum: 101, confidence: 99) + arRecord(disc, checksum: 202, confidence: 3) + arRecord(disc, checksum: 202, confidence: 5), disc: disc)
    let match = try AccurateRipVerifier.verify(sums, disc: disc, number: 2, lookup: .records(pressings))
    #expect(match.version == 2)
    #expect(match.confidence == 5)
    #expect(match.pressing == 3)
    let absent = try AccurateRipRecords.parse(arRecord(disc, checksum: 202, confidence: 0), disc: disc)
    #expect(try AccurateRipVerifier.verify(sums, disc: disc, number: 2, lookup: .records(absent)).status == .notInDatabase)
    var wrong = arRecord(disc, checksum: 101); wrong[1] ^= 1
    for invalid in [wrong, Data(wrong.dropLast()), Data(), Data(repeating: 0, count: AccurateRipRecords.maximumBytes + 1)] {
        #expect(throws: ConnectionError.self) { try AccurateRipRecords.parse(invalid, disc: disc) }
    }
}

private actor ARTransportStub: AccurateRipTransport {
    var calls = 0
    let response: AccurateRipHTTPResponse
    init(status: Int, data: Data = Data()) { response = .init(status: status, data: data) }
    func fetch(_ url: URL) async throws -> AccurateRipHTTPResponse { calls += 1; return response }
}
@Test func accurateRipAccessGateNeverMakesARequestAndHTTPFailuresStayDistinct() async throws {
    let disc = try arDisc(), transport = ARTransportStub(status: 200)
    let gated = AccurateRipClient(transport: transport, approved: false)
    guard case .accessPending = try await gated.lookup(disc) else { Issue.record("Expected approval gate"); return }
    #expect(await transport.calls == 0)
    for (status, expected) in [(404, AccurateRipStatus.notInDatabase), (503, .unavailable), (200, .unavailable)] {
        let client = AccurateRipClient(transport: ARTransportStub(status: status), approved: true)
        let result = try AccurateRipVerifier.verify(.init(v1: 1, v2: 2), disc: disc, number: 1, lookup: await client.lookup(disc))
        #expect(result.status == expected)
    }
}

@Test func accurateRipLegacyEvidenceAndDriveProfilesRemainCompatible() throws {
    let legacy = Data(#"{"backend":"test","pcmSHA256":"hash","logPath":"log","pcmPath":"wav","accurateRip":"notChecked","offsetSamples":0,"readCompleted":true,"requiresReview":true}"#.utf8)
    let decoded = try JSONDecoder().decode(RipIntegrity.self, from: legacy)
    #expect(decoded.verification == nil)
    #expect(decoded.requiresReview)
    var oldSettings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
    oldSettings.removeValue(forKey: "audioVerification")
    var settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: oldSettings))
    #expect(settings.audioVerification == AudioVerificationSettings())
    settings.audioVerification.driveOffsets["Vendor | Drive | Firmware1"] = 6
    #expect(settings.audioVerification.offset(for: "Vendor | Drive | Firmware2") == nil)
    #expect(settings.audioVerification.offset(for: nil) == nil)
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    let args = SecureOpticalRipper.readArguments(device: "/dev/rdisk99", track: 2, offset: -6, summary: URL(fileURLWithPath: "/tmp/log"), wav: URL(fileURLWithPath: "/tmp/audio.wav"))
    #expect(args == ["-d", "/dev/rdisk99", "-X", "-e", "-O", "-6", "-l", "/tmp/log", "2", "/tmp/audio.wav"])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_AR_REFERENCE_PCM"] != nil))
func accurateRipIndependentLibarcstkReferenceVector() throws {
    let path = try #require(ProcessInfo.processInfo.environment["CDRIP_AR_REFERENCE_PCM"])
    let sums = try AccurateRipChecksums.calculate(pcm: Data(contentsOf: URL(fileURLWithPath: path)), number: 2, trackCount: 3)
    #expect(sums.v1 == 0x8FE8D29B)
    #expect(sums.v2 == 0xD15BB487)
}

@Test func accurateRipOffsetCandidatesRemainSuggestionsAndRejectRepetitiveAudio() throws {
    let frames = 450 * 588 + 588 + 2940
    var seed: UInt32 = 0x13579bdf
    var words: [UInt32] = []
    for _ in 0..<frames { seed = seed &* 1664525 &+ 1013904223; words.append(seed) }
    let delta = 37, start = 450 * 588 + delta
    var checksum: UInt32 = 0
    for i in 0..<588 { checksum = checksum &+ (words[start + i] &* UInt32(i + 1)) }
    let pcm = words.reduce(into: Data()) { $0.append(arWord($1)) }
    let candidates = try AccurateRipVerifier.offsetCandidates(pcm: pcm, references: [.init(confidence: 4, checksum: 1, offsetChecksum: checksum)], currentOffset: 6)
    #expect(candidates == [43])
    let repetitive = Data(repeating: 1, count: frames * 4)
    let repeatedCRC = UInt32(truncatingIfNeeded: UInt64(0x01010101) * UInt64(588 * 589 / 2))
    #expect(try AccurateRipVerifier.offsetCandidates(pcm: repetitive, references: [.init(confidence: 2, checksum: 1, offsetChecksum: repeatedCRC)], currentOffset: 0).isEmpty)
}

@Test func accurateRipCancellationDoesNotBecomeServiceUnavailable() async throws {
    actor CancelTransport: AccurateRipTransport {
        var started = false
        func fetch(_ url: URL) async throws -> AccurateRipHTTPResponse {
            started = true
            try await Task.sleep(for: .seconds(30))
            return .init(status: 404, data: Data())
        }
    }
    let transport = CancelTransport(), disc = try arDisc()
    let client = AccurateRipClient(transport: transport, approved: true)
    let task = Task { try await client.lookup(disc) }
    while !(await transport.started) { await Task.yield() }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancellation was swallowed") }
    catch is CancellationError {} // Cancellation must reach the rip pipeline.
}
