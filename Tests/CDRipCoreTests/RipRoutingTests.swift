import Foundation
import Testing
@testable import CDRipCore

@Test func outputSettingsDecodeLegacyAndSessionKeepsSnapshot() throws {
    let json = #"{"destinationPath":"/tmp/old","profile":"mp3_320","azureEndpoint":"","azureDeployment":"metadata"}"#
    var settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    #expect(!settings.outputFolders.deleteWAVAfterConversion)
    #expect(settings.completionSound)
    #expect(settings.outputFolders.base(for: "wav", fallback: settings.destinationPath).path == "/tmp/old/WAV")
    settings.outputFolders.wavPath = "/tmp/wav"
    settings.outputFolders.mp3Path = "/tmp/mp3"
    settings.outputFolders.flacPath = "/tmp/flac"
    #expect(settings.outputFolders.base(for: "mp3", fallback: "/chosen").path == "/chosen/MP3")
    #expect(settings.outputFolders.base(for: "flac", fallback: "/chosen").path == "/chosen/FLAC")
    settings.outputFolders.deleteWAVAfterConversion = true
    let disc = DiscDescriptor(id: "test", title: "CD", source: .optical, tracks: [.init(id: "one", number: 1, duration: 1)])
    var session = RipSession(disc: disc, selectedIDs: ["one"], profile: .mp3AndFlac, destinationPath: "/tmp/logs")
    session.outputFolders = settings.outputFolders
    settings.outputFolders.wavPath = "/tmp/new"
    let restored = try JSONDecoder().decode(RipSession.self, from: JSONEncoder().encode(session))
    #expect(restored.outputFolders?.wavPath == "/tmp/wav")
    #expect(restored.outputFolders?.deleteWAVAfterConversion == true)
    let roundtrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(roundtrip == settings)
}

@Test func routingPreservesSourcesChecksCopiesAndOnlyDeletesWAVWhenEnabled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var folders = RipOutputFolders()
    folders.mp3Path = root.appendingPathComponent("MP3").path
    folders.flacPath = root.appendingPathComponent("FLAC").path
    folders.wavPath = root.appendingPathComponent("WAV").path
    for path in [folders.mp3Path, folders.flacPath, folders.wavPath] {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    let wav = URL(fileURLWithPath: folders.wavPath).appendingPathComponent("Track 07.wav")
    let mp3 = root.appendingPathComponent("Track 07.mp3"), flac = root.appendingPathComponent("Track 07.flac")
    try Data("original PCM".utf8).write(to: wav)
    try Data("validated MP3 fixture".utf8).write(to: mp3)
    try Data("validated FLAC fixture".utf8).write(to: flac)
    let id = UUID()
    let files = try await RipFileRouting.publish([mp3, flac], folders: folders, fallback: root.path, sessionID: id)
    #expect(files[0].deletingLastPathComponent().path == folders.mp3Path)
    #expect(files[1].deletingLastPathComponent().path == folders.flacPath)
    #expect(try Data(contentsOf: files[0]) == Data(contentsOf: mp3))
    #expect(try Data(contentsOf: files[1]) == Data(contentsOf: flac))
    try RipFileRouting.cleanWAV(wav, enabled: false, outputs: files)
    #expect(FileManager.default.fileExists(atPath: wav.path))
    #expect(throws: ConnectionError.self) { try RipFileRouting.cleanWAV(wav, enabled: true, outputs: []) }
    #expect(throws: ConnectionError.self) {
        try RipFileRouting.cleanWAV(wav, enabled: true, outputs: [root.appendingPathComponent("missing.mp3")])
    }
    await #expect(throws: ConnectionError.self) { try await RipFileRouting.publish([mp3, flac], folders: folders, fallback: root.path, sessionID: id) }
    #expect(try Data(contentsOf: files[0]) == Data(contentsOf: mp3))
    try RipFileRouting.cleanWAV(wav, enabled: true, outputs: files)
    #expect(!FileManager.default.fileExists(atPath: wav.path))
    #expect(FileManager.default.fileExists(atPath: files[0].path))
    #expect(FileManager.default.fileExists(atPath: files[1].path))
}

@Test func failedSecondDestinationRollsBackFirstCopyAndKeepsWAV() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let mp3 = root.appendingPathComponent("one.mp3"), flac = root.appendingPathComponent("one.flac"), wav = root.appendingPathComponent("one.wav")
    for file in [mp3, flac, wav] { try Data("source".utf8).write(to: file) }
    let folders = RipOutputFolders()
    // A file occupying FLAC prevents the second publication; the first must roll back.
    try Data("occupied".utf8).write(to: root.appendingPathComponent("FLAC"))
    let id = UUID()
    await #expect(throws: (any Error).self) { try await RipFileRouting.publish([mp3, flac], folders: folders, fallback: root.path, sessionID: id) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("MP3/one.mp3").path))
    for file in [mp3, flac, wav] { #expect(FileManager.default.fileExists(atPath: file.path)) }
}

@Test func progressTracksWrittenPCMAndStopsWithReader() async throws {
    #expect(TrackReadProgress.fraction(fileBytes: 44, sectors: 100) == 0)
    #expect(TrackReadProgress.fraction(fileBytes: 44 + 2352 * 50, sectors: 100) == 0.5)
    #expect(TrackReadProgress.fraction(fileBytes: 44 + 2352 * 100, sectors: 100) == 0.99)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let wav = root.appendingPathComponent("progress.wav")
    actor Fractions {
        var values: [Double] = []
        func add(_ v: Double) { values.append(v) }
    }
    let fractions = Fractions()
    let result = try await TrackReadProgress.monitor(wav: wav, sectors: 100, read: {
        try Data(repeating: 0, count: 44 + 2352 * 25).write(to: wav)
        try await Task.sleep(for: .milliseconds(650))
        try Data(repeating: 0, count: 44 + 2352 * 75).write(to: wav)
        try await Task.sleep(for: .milliseconds(650))
        return CLIResult(code: 0, output: "completed")
    }, progress: { await fractions.add($0) })
    #expect(result.code == 0)
    let values = await fractions.values
    #expect(values.contains(0.25))
    #expect(values.contains(0.75))
    let start = ContinuousClock.now
    await #expect(throws: ConnectionError.self) {
        try await TrackReadProgress.monitor(wav: wav, sectors: 100, read: {
            try await LocalCLIRunner().run(path: "/bin/sleep", arguments: ["10"], directory: root, timeout: .seconds(20))
        }, progress: { _ in throw ConnectionError("checkpoint failed") })
    }
    #expect(ContinuousClock.now - start < .seconds(3))
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
func realConversionRoutesSelectedFormatsAndRemainsDecodableAfterWAVDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var folders = RipOutputFolders()
    folders.mp3Path = root.appendingPathComponent("mp3 destination").path
    folders.flacPath = root.appendingPathComponent("flac destination").path
    for path in [folders.mp3Path, folders.flacPath] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
    let runner = LocalCLIRunner()
    for profile in [OutputProfile.mp3_320, .flac, .mp3AndFlac] {
        let wav = root.appendingPathComponent(profile.rawValue + ".wav")
        let create = try await runner.run(path: "/opt/homebrew/bin/ffmpeg", arguments: ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1", "-ac", "2", "-c:a", "pcm_s16le", wav.path], directory: root, timeout: .seconds(10))
        #expect(create.code == 0)
        let stage = root.appendingPathComponent("Encoding-" + profile.rawValue)
        let encoded = try await PCMEncoder().encode(input: wav, profile: profile, trackNumber: 9, destination: stage)
        let files = try await RipFileRouting.publish(encoded, folders: folders, fallback: root.path, sessionID: UUID())
        #expect(files.count == (profile == .mp3AndFlac ? 2 : 1))
        try FileManager.default.removeItem(at: stage)
        try RipFileRouting.cleanWAV(wav, enabled: true, outputs: files)
        #expect(!FileManager.default.fileExists(atPath: wav.path))
        for file in files {
            let decode = try await runner.run(path: "/opt/homebrew/bin/ffmpeg", arguments: ["-nostdin", "-v", "error", "-xerror", "-err_detect", "explode", "-i", file.path, "-map", "0:a:0", "-f", "null", "-"], directory: root, timeout: .seconds(10))
            #expect(decode.code == 0)
            #expect(decode.output.isEmpty)
            try FileManager.default.removeItem(at: file)
        }
    }
}

@Test func oneOutputRootCreatesOnlyPublishedFormatFolders() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("cd1")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let mp3 = root.appendingPathComponent("Song.mp3")
    try Data("verified audio fixture".utf8).write(to: mp3)
    var folders = RipOutputFolders(); folders.mp3Path = "/ignored/old/path"
    let files = try await RipFileRouting.publish([mp3], folders: folders, fallback: output.path, sessionID: UUID())
    #expect(files == [output.appendingPathComponent("MP3/Song.mp3")])
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["MP3"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("MP3").path) == ["Song.mp3"])
}
