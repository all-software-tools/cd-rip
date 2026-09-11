import Foundation
import CryptoKit

public struct DestinationReport: Sendable {
    public let availableBytes: Int64
    public let requiredBytes: Int64
}
public enum OutputFiles {
    /// Conservative: PCM plus staging/output, dual format overhead and 64 MiB reserve.
    public static func requiredBytes(seconds: TimeInterval, profile: OutputProfile) -> Int64 {
        let pcm = max(0, min(seconds.isFinite ? seconds : 0, 86400)) * 44100 * 4
        return Int64(pcm * (profile == .mp3AndFlac ? 4 : 3)) + 64 * 1024 * 1024
    }
    public static func validateDestination(_ url: URL, requiredBytes: Int64) throws -> DestinationReport {
        var directory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw ConnectionError("The output folder is unavailable. Reconnect the drive or choose an existing folder. The app will not switch folders automatically.")
        }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available >= requiredBytes else { throw ConnectionError("Not enough free space for audio, temporary files and final output.") }
        let probe = url.appendingPathComponent(".cdrip-write-test-\(UUID())")
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: probe)
        } catch { throw ConnectionError("Cannot write to the output folder. Check its permissions.") }
        return DestinationReport(availableBytes: available, requiredBytes: requiredBytes)
    }
    public static func safeComponent(_ text: String) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        let result = text.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let nonempty = result.isEmpty ? "Unknown" : result
        // Bound UTF-8 bytes (APFS/HFS filename limits); preserve whole graphemes.
        var safe = ""
        for character in nonempty { if safe.utf8.count + String(character).utf8.count > 160 { break }; safe.append(character) }
        return safe.isEmpty ? "Unknown" : safe
    }
    public static func filename(number: Int, artist: String, title: String, extension ext: String) -> String {
        let name = artist.isEmpty ? title : artist + " - " + title
        return String(format: "%02d", number) + " - " + safeComponent(name) + "." + safeComponent(ext)
    }
}

public struct EncodingOutput: Sendable {
    public let relativePath: String
    public let arguments: [String]
}
public enum EncodingPlan {
    /// Input contract: CD PCM, 44.1 kHz, 16-bit stereo. No resampling or loudness filters.
    public static func outputs(profile: OutputProfile, trackNumber: Int) -> [EncodingOutput] {
        let stem = String(format: "Track %02d", trackNumber)
        let mp3: [String]
        switch profile {
        case .mp3_192: mp3 = ["-b:a", "192k"]
        case .mp3_256: mp3 = ["-b:a", "256k"]
        case .mp3_v0: mp3 = ["-q:a", "0"]
        default: mp3 = ["-b:a", "320k"]
        }
        let compressed = EncodingOutput(relativePath: "MP3/\(stem).mp3", arguments: ["-c:a", "libmp3lame"] + mp3)
        let lossless = EncodingOutput(relativePath: "FLAC/\(stem).flac", arguments: ["-c:a", "flac", "-compression_level", "8"])
        switch profile {
        case .flac: return [lossless]
        case .mp3AndFlac: return [compressed, lossless]
        default: return [compressed]
        }
    }
}

/// A hardware-independent encoder for validated PCM input. Files remain in a private staging
/// directory until every requested output succeeds; publication refuses existing destinations.
public struct PCMEncoder: Sendable {
    public let ffmpegPath: String
    public let ffprobePath: String
    private let runner: any CLIRunning
    public init(ffmpegPath: String = AudioToolPaths.executable("ffmpeg"), ffprobePath: String = AudioToolPaths.executable("ffprobe"), runner: any CLIRunning = LocalCLIRunner()) {
        self.ffmpegPath = ffmpegPath; self.ffprobePath = ffprobePath; self.runner = runner
    }
    public func encode(input: URL, profile: OutputProfile, trackNumber: Int, destination: URL) async throws -> [URL] {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ConnectionError("This track’s output folder already exists. Choose a new name. Existing files will not be overwritten.") }
        let parent = destination.deletingLastPathComponent()
        _ = try OutputFiles.validateDestination(parent, requiredBytes: 64 * 1024 * 1024)
        let stage = parent.appendingPathComponent(".cdrip-encode-\(UUID())")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let info = try await runner.run(path: ffprobePath, arguments: ["-v", "error", "-show_streams", "-show_format", "-of", "json", input.path], directory: stage, timeout: .seconds(20))
        guard info.code == 0, let d = try? JSONSerialization.jsonObject(with: Data(info.output.utf8)) as? [String: Any],
              let streams = d["streams"] as? [[String: Any]], streams.count == 1, let audio = streams.first,
              ["pcm_s16le", "pcm_s16be"].contains(audio["codec_name"] as? String ?? ""),
              audio["sample_rate"] as? String == "44100", audio["channels"] as? Int == 2,
              let format = d["format"] as? [String: Any], let length = format["duration"] as? String, let seconds = Double(length), seconds.isFinite, seconds > 0, seconds <= 86400 else {
            throw ConnectionError("The source must be 16-bit stereo PCM at 44.1 kHz with a valid duration. No automatic resampling or conversion from MP3 is performed.")
        }
        _ = try OutputFiles.validateDestination(parent, requiredBytes: OutputFiles.requiredBytes(seconds: seconds, profile: profile))
        let sourcePCM = stage.appendingPathComponent("source-check.pcm")
        let sourceDecode = try await runner.run(path: ffmpegPath, arguments: ["-nostdin", "-v", "error", "-xerror", "-err_detect", "explode", "-i", input.path, "-map", "0:a:0", "-c:a", "pcm_s16le", "-f", "s16le", sourcePCM.path], directory: stage, timeout: .seconds(max(60, seconds * 2)))
        guard sourceDecode.code == 0, sourceDecode.output.isEmpty else { throw ConnectionError("The PCM source could not be decoded completely.") }
        let originalPCM = try Data(contentsOf: sourcePCM, options: .mappedIfSafe)
        let originalHash = SHA256.hash(data: originalPCM)
        let originalSize = originalPCM.count
        try FileManager.default.removeItem(at: sourcePCM)
        let outputs = EncodingPlan.outputs(profile: profile, trackNumber: trackNumber)
        for output in outputs {
            let file = stage.appendingPathComponent(output.relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", input.path, "-map", "0:a:0", "-map_metadata", "-1"] + output.arguments + [file.path]
            let result = try await runner.run(path: ffmpegPath, arguments: args, directory: stage, timeout: .seconds(max(60, seconds * 2)))
            guard result.code == 0, ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
                throw ConnectionError("Encoding failed. The source is preserved and no partial output was published.")
            }
            let probe = try await runner.run(path: ffprobePath, arguments: ["-v", "error", "-show_streams", "-of", "json", file.path], directory: stage, timeout: .seconds(20))
            guard probe.code == 0, let object = try JSONSerialization.jsonObject(with: Data(probe.output.utf8)) as? [String: Any],
                  let streams = object["streams"] as? [[String: Any]], streams.count == 1, let stream = streams.first,
                  stream["sample_rate"] as? String == "44100", stream["channels"] as? Int == 2,
                  stream["codec_name"] as? String == file.pathExtension else { throw ConnectionError("The encoded audio format does not match the selected profile.") }
            let decoded = stage.appendingPathComponent("output-check.pcm")
            let check = try await runner.run(path: ffmpegPath, arguments: ["-nostdin", "-v", "error", "-xerror", "-err_detect", "explode", "-i", file.path, "-map", "0:a:0", "-c:a", "pcm_s16le", "-f", "s16le", decoded.path], directory: stage, timeout: .seconds(max(60, seconds * 2)))
            let pcm = try Data(contentsOf: decoded, options: .mappedIfSafe)
            guard check.code == 0, check.output.isEmpty, !pcm.isEmpty,
                  abs(pcm.count - originalSize) <= (file.pathExtension == "flac" ? 0 : 2304 * 4),
                  file.pathExtension != "flac" || SHA256.hash(data: pcm) == originalHash else {
                throw ConnectionError("Audio validation failed: truncated output, decoding errors or FLAC that differs from the source PCM.")
            }
            try FileManager.default.removeItem(at: decoded)
        }
        try Task.checkCancellation()
        // FileManager.moveItem refuses collisions, including a concurrent destination creation.
        try FileManager.default.moveItem(at: stage, to: destination)
        return outputs.map { destination.appendingPathComponent($0.relativePath) }
    }
}
