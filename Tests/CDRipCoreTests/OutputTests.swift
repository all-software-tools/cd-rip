import Foundation
import Testing
@testable import CDRipCore

@Test func destinationSafetyHandlesMissingSpaceAndUnicode() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CD Rip ȘȚ - \(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try OutputFiles.validateDestination(root, requiredBytes: 1024).availableBytes > 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    #expect(throws: ConnectionError.self) { try OutputFiles.validateDestination(root, requiredBytes: Int64.max) }
    #expect(throws: ConnectionError.self) { try OutputFiles.validateDestination(root.appendingPathComponent("missing"), requiredBytes: 0) }
    #expect(OutputFiles.safeComponent("../Și: mâine/Again") == "_Și_ mâine_Again")
    #expect(!OutputFiles.filename(number: 7, artist: "A/B", title: "../X", extension: "mp3").contains("/"))
    #expect(OutputFiles.safeComponent(String(repeating: "🎵", count: 200)).utf8.count <= 160)
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
func realEncodingProfilesFromSyntheticPCM() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CDRip encoding Ș \(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = LocalCLIRunner()
    let input = root.appendingPathComponent("source.wav")
    let create = try await runner.run(path: "/opt/homebrew/bin/ffmpeg", arguments: ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=2", "-ac", "2", "-c:a", "pcm_s16le", input.path], directory: root, timeout: .seconds(10))
    #expect(create.code == 0)
    let original = try Data(contentsOf: input)
    for profile in OutputProfile.allCases {
        let destination = root.appendingPathComponent(profile.rawValue)
        let files = try await PCMEncoder().encode(input: input, profile: profile, trackNumber: 7, destination: destination)
        #expect(files.count == (profile == .mp3AndFlac ? 2 : 1))
        for file in files {
            let probe = try await runner.run(path: "/opt/homebrew/bin/ffprobe", arguments: ["-v", "error", "-show_streams", "-of", "json", file.path], directory: root, timeout: .seconds(10))
            let d = try #require(JSONSerialization.jsonObject(with: Data(probe.output.utf8)) as? [String: Any])
            let stream = try #require((d["streams"] as? [[String: Any]])?.first)
            #expect(stream["sample_rate"] as? String == "44100")
            #expect(stream["channels"] as? Int == 2)
            if file.pathExtension == "mp3" {
                #expect(stream["codec_name"] as? String == "mp3")
                let rate = [OutputProfile.mp3_192: "192000", .mp3_256: "256000", .mp3_320: "320000", .mp3AndFlac: "320000"][profile]
                if let rate { #expect(stream["bit_rate"] as? String == rate) }
            } else {
                #expect(stream["codec_name"] as? String == "flac")
                // Lossless preservation is checked on decoded PCM, not container bytes.
                var hashes: [String] = []
                for source in [input, file] {
                    let hash = try await runner.run(path: "/opt/homebrew/bin/ffmpeg", arguments: ["-v", "error", "-i", source.path, "-map", "0:a:0", "-f", "hash", "-hash", "sha256", "-"], directory: root, timeout: .seconds(10))
                    #expect(hash.code == 0); hashes.append(hash.output)
                }
                #expect(hashes[0] == hashes[1])
            }
        }
        await #expect(throws: ConnectionError.self) { try await PCMEncoder().encode(input: input, profile: profile, trackNumber: 7, destination: destination) }
        #expect(try Data(contentsOf: input) == original)
    }
}
