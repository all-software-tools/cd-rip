import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import CDRipCore

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
func tagMP3AndFLACWithCoverPreservesAudioAndOriginals() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CDRip tags Ș \(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = LocalCLIRunner()
    let wav = root.appendingPathComponent("source.wav")
    let result = try await runner.run(path: "/opt/homebrew/bin/ffmpeg", arguments: ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=44100:duration=2", "-ac", "2", "-c:a", "pcm_s16le", wav.path], directory: root, timeout: .seconds(10))
    #expect(result.code == 0)
    let inputs = try await PCMEncoder().encode(input: wav, profile: .mp3AndFlac, trackNumber: 7, destination: root.appendingPathComponent("Encoded"))
    let originals = try inputs.map { try Data(contentsOf: $0) }
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0, green: 0.8, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = try #require(context.makeImage())
    for (index, type) in ["public.png", "public.jpeg"].enumerated() {
        let cover = root.appendingPathComponent(index == 0 ? "cover.png" : "cover.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(cover as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
        var metadata = TrackMetadata()
        metadata.artist = "Artist Ș / invitat"; metadata.title = "7 Years: remix"; metadata.album = "Compilație"
        metadata.albumArtist = "Artiști diverși"; metadata.year = "2026"; metadata.genre = "Pop"
        metadata.discNumber = 2; metadata.discTotal = 3; metadata.coverPath = cover.path
        let revision = try await AudioTagWriter().write(metadata: metadata, number: 7, total: 15, inputs: inputs, destination: root.appendingPathComponent("Tagged-\(index)"))
        #expect(revision.outputPaths.count == 2)
        for path in revision.outputPaths { #expect(try frontPictureType(URL(fileURLWithPath: path)) == 3) }
        #expect(revision.outputPaths.allSatisfy { $0.contains("Artiști diverși/Compilație/Disc 02/07 - Artist Ș _ invitat - 7 Years_ remix") })
        #expect(try inputs.map { try Data(contentsOf: $0) } == originals)
        await #expect(throws: ConnectionError.self) { try await AudioTagWriter().write(metadata: metadata, number: 7, total: 15, inputs: inputs, destination: root.appendingPathComponent("Tagged-\(index)")) }
        // A new version without a cover must remove it and clear blank fields, preserving the previous version.
        metadata.coverPath = nil; metadata.genre = ""; metadata.albumArtist = ""; metadata.year = ""
        _ = try await AudioTagWriter().write(metadata: metadata, number: 7, total: 15, inputs: revision.outputPaths.map { URL(fileURLWithPath: $0) }, destination: root.appendingPathComponent("No-cover-\(index)"))
        #expect(revision.outputPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }
    try await verifyModelTagging(root: root, inputs: inputs)
}

@MainActor private func verifyModelTagging(root: URL, inputs: [URL]) async throws {
    // Synthetic optical session fixture: this does not access or certify a physical CD.
    let disc = DiscDescriptor(id: "test-optical-fixture", title: "Test fixture", source: .optical,
        tracks: (1...7).map { SourceTrack(id: "fixture-\($0)", number: $0, duration: 2) })
    var session = RipSession(disc: disc, selectedIDs: ["fixture-7"], profile: .mp3AndFlac, destinationPath: root.path)
    session.commonArtist = "Artist comun Ș"
    session.tracks[0].phase = .awaitingVerification
    session.tracks[0].outputPaths = inputs.map(\.path)
    session.tracks[0].integrity = RipIntegrity(backend: "TEST FIXTURE", pcmSHA256: "fixture", logPath: root.appendingPathComponent("fixture.log").path,
        pcmPath: root.appendingPathComponent("source.wav").path, accurateRip: "notChecked", offsetSamples: 0, readCompleted: true, requiresReview: true)
    var workspace = WorkspaceState(); workspace.sessions = [session]; workspace.selectedSessionID = session.id
    let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
    _ = try await store.load(); try await store.save(workspace)
    let model = AppModel(store: store)
    await model.bootstrap()
    var metadata = TrackMetadata(); metadata.title = "Titlu test"
    await model.writeTags(metadata: metadata, trackID: "fixture-7", sessionID: session.id)
    let deadline = ContinuousClock.now + .seconds(20)
    while model.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    if model.isBusy { await model.cancelAndWait() }
    #expect(model.message == nil)
    #expect(!model.isTagging)
    let saved = try await store.load()
    let track = try #require(saved.sessions.first?.tracks.first)
    #expect(track.phase == .awaitingVerification)
    #expect(track.integrity?.requiresReview == true)
    #expect(track.outputPaths == inputs.map(\.path))
    #expect(track.tagRevisions?.count == 1)
    #expect(track.tagRevisions?.first?.metadata.artist == "Artist comun Ș")
    #expect(track.supplied.artist.isEmpty)
}

private func frontPictureType(_ file: URL) throws -> Int? {
    let data = try Data(contentsOf: file)
    func big(_ offset: Int, _ count: Int) -> Int { (0..<count).reduce(0) { ($0 << 8) | Int(data[offset + $1]) } }
    if file.pathExtension == "flac" {
        guard data.prefix(4) == Data("fLaC".utf8) else { return nil }
        var offset = 4
        while offset + 4 <= data.count {
            let type = data[offset] & 127
            let size = big(offset + 1, 3)
            guard size <= data.count - offset - 4 else { return nil }
            if type == 6, size >= 4 { return big(offset + 4, 4) }
            if data[offset] & 128 != 0 { return nil }
            offset += 4 + size
        }
    } else {
        guard data.count >= 10, data.prefix(3) == Data("ID3".utf8), data[3] == 3 else { return nil }
        var offset = 10
        while offset + 10 <= data.count {
            let size = big(offset + 4, 4)
            guard size > 0, size <= data.count - offset - 10 else { return nil }
            if data[offset..<offset+4] == Data("APIC".utf8) {
                let start = offset + 11
                guard let end = data[start..<offset+10+size].firstIndex(of: 0), end + 1 < offset + 10 + size else { return nil }
                return Int(data[end + 1])
            }
            offset += 10 + size
        }
    }
    return nil
}
