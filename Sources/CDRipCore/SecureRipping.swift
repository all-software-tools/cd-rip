import Foundation
import CryptoKit
import Darwin

/// No AccurateRip lookup or offset calibration is claimed by this version.
public struct RipIntegrity: Codable, Equatable, Sendable {
    public let backend: String
    public let pcmSHA256: String
    public let logPath: String
    public let pcmPath: String
    public let accurateRip: String
    public let offsetSamples: Int
    public let readCompleted: Bool
    public let requiresReview: Bool
    public var pcmDeleted: Bool?
}

public struct OpticalRipEvent: Sendable {
    public let trackID: String
    public let phase: WorkPhase
    public let progress: Double
    public var paths: [String] = []
    public var integrity: RipIntegrity?
}

public enum ParanoiaReport {
    /// Fail closed: exit zero alone is insufficient. Completion marker is mandatory.
    /// Repaired jitter is not treated as an independent AccurateRip verification.
    public static func validate(code: Int32, console: String, summary: String) throws {
        let all = (console + "\n" + summary).lowercased()
        let lines = console.split(separator: "\n").filter { $0.hasPrefix("##:") }
        let pattern = try NSRegularExpression(pattern: #"^##: ([0-9]+) \[([a-z ]+)\] @ (-?[0-9]+)$"#)
        let allowed = [0: "read", 1: "verify", 2: "jitter", 3: "correction", 7: "drift", 8: "backoff", 9: "overlap", 14: "wrote", 15: "finished"]
        var callbacks: [Int] = []
        let recognized = lines.allSatisfy { line in
            let text = String(line) as NSString
            guard let match = pattern.firstMatch(in: String(line), range: NSRange(location: 0, length: text.length)),
                  let code = Int(text.substring(with: match.range(at: 1))),
                  allowed[code] == text.substring(with: match.range(at: 2)) else { return false }
            callbacks.append(code)
            return true
        }
        guard code == 0, console.contains("Done."), summary.contains(":^D"),
              callbacks.last == 15, callbacks.contains(0), callbacks.contains(1), callbacks.contains(14), recognized,
              summary.contains("Using paranoia library version: 10.2+2.0.2"),
              !["cache modelling", "read error", "unrecover", "aborted", "8-X", ";-("].contains(where: { all.contains($0.lowercased()) }) else {
            throw ConnectionError("The read report is incomplete or contains errors. WAV and logs are preserved; encoding and finalization are blocked.")
        }
    }
}

/// OS-level advisory lock prevents two instances of this app operating the same drive.
final class OpticalLock {
    let descriptor: Int32
    init(device: String) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("digital.mykey.cdrip-\(device).lock").path
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ConnectionError("Could not reserve the CD drive.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw ConnectionError("The drive is being used by another CD Rip session.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public actor SecureOpticalRipper {
    private let runner: any CLIRunning
    private let encoder: PCMEncoder
    public let backendPath: String
    private var active = false
    public init(runner: any CLIRunning = LocalCLIRunner(), encoder: PCMEncoder = PCMEncoder(), backendPath: String = AudioToolPaths.executable("cd-paranoia")) {
        self.runner = runner; self.encoder = encoder; self.backendPath = backendPath
    }
    public func rip(_ session: RipSession, report: @Sendable @escaping (OpticalRipEvent) async throws -> Void) async throws {
        guard !active else { throw ConnectionError("A read operation is already running.") }
        active = true
        defer { active = false }
        guard session.disc.source == .optical, let optical = session.disc.optical,
              !session.tracks.isEmpty,
              session.tracks.allSatisfy({ track in session.disc.tracks.contains { $0.id == track.id && $0.number == track.number } }) else {
            throw CDRipError.invalidSelection
        }
        let current = try await MacOpticalSource(runner: runner).loadDisc()
        guard current == session.disc else { throw ConnectionError("The CD or drive has changed. Detect the source again.") }
        guard FileManager.default.isExecutableFile(atPath: backendPath) else { throw ConnectionError("cd-paranoia is missing. Install libcdio-paranoia before ripping.") }
        let lock = try OpticalLock(device: optical.device)
        defer { withExtendedLifetime(lock) {} }
        let destination = URL(fileURLWithPath: session.destinationPath)
        _ = try OutputFiles.validateDestination(destination, requiredBytes: OutputFiles.requiredBytes(seconds: session.tracks.map(\.duration).reduce(0,+), profile: session.outputProfile))
        let routing: RipOutputFolders? = session.outputFolders ?? RipOutputFolders()
        if let routing {
            let formats = (routing.deleteWAVAfterConversion ? [] : ["wav"]) + EncodingPlan.outputs(profile: session.outputProfile, trackNumber: 1).map { URL(fileURLWithPath: $0.relativePath).pathExtension }
            for format in formats {
                let formatFolder = routing.base(for: format, fallback: session.destinationPath)
                if FileManager.default.fileExists(atPath: formatFolder.path) {
                    _ = try OutputFiles.validateDestination(formatFolder, requiredBytes: OutputFiles.requiredBytes(seconds: session.tracks.map(\.duration).reduce(0,+), profile: session.outputProfile))
                }
            }
        }
        let root = RipFileRouting.internalDirectory.appendingPathComponent(session.id.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(session).write(to: root.appendingPathComponent("session.json"), options: .atomic)
        try Data("Audio not confirmed by AccurateRip. Offset not calibrated. Files are not finalized for broadcast. Logs are retained. WAV retention follows the session settings.\n".utf8).write(to: root.appendingPathComponent("NEEDS-REVIEW.txt"))
        do {
            let unmount = try await runner.run(path: "/usr/sbin/diskutil", arguments: ["unmount", "/dev/" + optical.device], directory: root, timeout: .seconds(30))
        guard unmount.code == 0 else { throw ConnectionError("The CD is busy and could not be unmounted for direct reading.") }
            let toc = try await runner.run(path: backendPath, arguments: ["-d", optical.rawDevice, "-Q"], directory: root, timeout: .seconds(45))
            try Data(toc.output.utf8).write(to: root.appendingPathComponent("backend-toc.log"))
            try Self.validateTOC(toc, expected: optical.tracks)
            for track in session.tracks {
                try Task.checkCancellation()
                let folder = root.appendingPathComponent(String(format: "Track %02d", track.number))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let wavFolder = folder
                try FileManager.default.createDirectory(at: wavFolder, withIntermediateDirectories: true)
                let wav = wavFolder.appendingPathComponent(String(format: "Track %02d - ", track.number) + session.id.uuidString + ".wav")
                guard !FileManager.default.fileExists(atPath: wav.path) else { throw ConnectionError("The WAV already exists. It will not be overwritten.") }
                let expected = optical.tracks.first { $0.number == track.number }!
                let summary = folder.appendingPathComponent("read-summary.log")
                let console = folder.appendingPathComponent("read-console.log")
                try await report(.init(trackID: track.id, phase: .reading, progress: 0))
                // Default full paranoia, abort on any skip. No -Z/-Y, C2 shortcut or implicit offset.
                let runner = self.runner, backendPath = self.backendPath
                let read = try await TrackReadProgress.monitor(wav: wav, sectors: expected.sectorCount, read: {
                    try await runner.run(path: backendPath, arguments: ["-d", optical.rawDevice, "-X", "-e", "-l", summary.path, String(track.number), wav.path], directory: folder, timeout: .seconds(max(180, track.duration * 8)), logURL: console)
                }, progress: { fraction in
                    try await report(.init(trackID: track.id, phase: .reading, progress: fraction * 0.78))
                })
                try Data(read.output.utf8).write(to: console, options: .atomic)
                try ParanoiaReport.validate(code: read.code, console: read.output, summary: String(contentsOf: summary, encoding: .utf8))
                let after = try await runner.run(path: backendPath, arguments: ["-d", optical.rawDevice, "-Q"], directory: folder, timeout: .seconds(45))
                try Data(after.output.utf8).write(to: folder.appendingPathComponent("toc-after.log"))
                try Self.validateTOC(after, expected: optical.tracks)
                let pcm = try Self.wavePCM(wav, expectedBytes: expected.sectorCount * 2352)
                let hash = SHA256.hash(data: pcm).map { String(format: "%02x", $0) }.joined()
                try await report(.init(trackID: track.id, phase: .encoding, progress: 0.8))
                let encoded = folder.appendingPathComponent("Encoded")
                var files = try await encoder.encode(input: wav, profile: session.outputProfile, trackNumber: track.number, destination: encoded)
                // Untagged names include the session ID so another CD never overwrites them.
                files = try files.map { file in
                    let unique = file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + " - " + session.id.uuidString + "." + file.pathExtension)
                    try FileManager.default.moveItem(at: file, to: unique)
                    return unique
                }
                if let routing {
                    files = try await RipFileRouting.publish(files, folders: routing, fallback: session.destinationPath, sessionID: session.id)
                    try FileManager.default.removeItem(at: encoded)
                }
                var retainedWAV = wav
                if let routing, !routing.deleteWAVAfterConversion {
                    retainedWAV = try await RipFileRouting.publish([wav], folders: routing, fallback: session.destinationPath, sessionID: session.id)[0]
                }
                var integrity = RipIntegrity(backend: "libcdio-paranoia 10.2+2.0.2", pcmSHA256: hash, logPath: console.path, pcmPath: retainedWAV.path, accurateRip: "notChecked", offsetSamples: 0, readCompleted: true, requiresReview: true)
                try JSONEncoder().encode(integrity).write(to: folder.appendingPathComponent("integrity.json"), options: .atomic)
                try await report(.init(trackID: track.id, phase: .awaitingVerification, progress: 1, paths: files.map(\.path), integrity: integrity))
                if retainedWAV != wav { try FileManager.default.removeItem(at: wav) }
                if routing?.deleteWAVAfterConversion == true {
                    try RipFileRouting.cleanWAV(wav, enabled: true, outputs: files)
                    integrity.pcmDeleted = true
                    try JSONEncoder().encode(integrity).write(to: folder.appendingPathComponent("integrity.json"), options: .atomic)
                    try await report(.init(trackID: track.id, phase: .awaitingVerification, progress: 1, paths: files.map(\.path), integrity: integrity))
                }
            }
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: root.appendingPathComponent("failure.txt"), options: .atomic)
            let mounted = await remount(optical.device, directory: root)
            if !mounted { throw ConnectionError(error.localizedDescription + "\nThe CD could not be remounted. Reconnect the drive or mount the CD in Disk Utility. Files remain in " + root.path) }
            throw error
        }
        guard await remount(optical.device, directory: root) else { throw ConnectionError("Reading finished, but the CD could not be remounted. Check remount.log and mount it in Disk Utility.") }
    }
    private func remount(_ device: String, directory: URL) async -> Bool {
        let runner = self.runner
        // Cleanup must run even when the parent rip Task was cancelled.
        return await Task.detached {
            do {
                let info = try await runner.run(path: "/usr/sbin/diskutil", arguments: ["info", "-plist", "/dev/" + device], directory: directory, timeout: .seconds(15))
                guard info.code == 0,
                      let data = try PropertyListSerialization.propertyList(from: Data(info.output.utf8), format: nil) as? [String: Any],
                      data["Content"] as? String == "CD_partition_scheme" else { return false }
                let result = try await runner.run(path: "/usr/sbin/diskutil", arguments: ["mount", "/dev/" + device], directory: directory, timeout: .seconds(30))
                try Data(result.output.utf8).write(to: directory.appendingPathComponent("remount.log"), options: .atomic)
                return result.code == 0
            } catch { return false }
        }.value
    }
    static func validateTOC(_ result: CLIResult, expected: [OpticalTrack]) throws {
        let regex = try NSRegularExpression(pattern: #"(?m)^\s*(\d+)\.\s+(\d+)\s+\[[^\]]+\]\s+(\d+)\s+\["#)
        let text = result.output as NSString
        let rows = regex.matches(in: result.output, range: NSRange(location: 0, length: text.length)).compactMap { match -> OpticalTrack? in
            guard let number = Int(text.substring(with: match.range(at: 1))), let length = Int(text.substring(with: match.range(at: 2))), let start = Int(text.substring(with: match.range(at: 3))) else { return nil }
            return OpticalTrack(number: number, startSector: start, sectorCount: length)
        }
        guard result.code == 0, rows == expected else { throw ConnectionError("The table of contents read from the drive differs from the selected CD. Reading was blocked.") }
    }
    static func wavePCM(_ url: URL, expectedBytes: Int) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func word(_ offset: Int) -> Int { (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << (8 * $1)) } }
        guard data.count >= 44, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else { throw ConnectionError("Incomplete or invalid WAV.") }
        var offset = 12
        while offset + 8 <= data.count {
            let size = word(offset + 4)
            guard size <= data.count - offset - 8 else { break }
            if data[offset..<offset+4] == Data("data".utf8) {
                guard size == expectedBytes else { throw ConnectionError("Incomplete read: the sample count differs from the table of contents.") }
                return data.subdata(in: offset+8..<offset+8+size)
            }
            offset += 8 + size + size % 2
        }
        throw ConnectionError("Truncated WAV: PCM data is missing.")
    }
}
