import Foundation
import CryptoKit

/// Copies validated outputs across volumes, verifies the copy, then exposes each file.
/// On failure only files created by this call are removed; sources remain available.
public enum RipFileRouting {
    public static var internalDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CDRip/AudioSessions", isDirectory: true)
    }
    public static func publish(_ files: [URL], folders: RipOutputFolders, fallback: String,
                               sessionID: UUID, subfolder: String = "") async throws -> [URL] {
        var published: [URL] = []
        do {
            for file in files {
                try Task.checkCancellation()
                let ext = file.pathExtension
                guard ["mp3", "flac", "wav"].contains(ext) else { throw ConnectionError("Unsupported output format.") }
                let base = folders.base(for: ext, fallback: fallback)
                let source = try Data(contentsOf: file, options: .mappedIfSafe)
                _ = try OutputFiles.validateDestination(URL(fileURLWithPath: fallback), requiredBytes: Int64(source.count) + 64 * 1024 * 1024)
                if !FileManager.default.fileExists(atPath: base.path) {
                    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
                }
                _ = try OutputFiles.validateDestination(base, requiredBytes: Int64(source.count) + 64 * 1024 * 1024)
                var parent = base
                if !subfolder.isEmpty { parent.appendPathComponent(subfolder) }
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let output = parent.appendingPathComponent(file.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: output.path) else { throw ConnectionError("An output file already exists. It will not be overwritten.") }
                let stage = parent.appendingPathComponent(".cdrip-copy-\(UUID())")
                defer { try? FileManager.default.removeItem(at: stage) }
                try FileManager.default.copyItem(at: file, to: stage)
                let copied = try Data(contentsOf: stage, options: .mappedIfSafe)
                guard copied.count == source.count, SHA256.hash(data: copied) == SHA256.hash(data: source) else {
                    throw ConnectionError("The copied audio file failed verification. The WAV is preserved.")
                }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: stage, to: output)
                published.append(output)
            }
            return published
        } catch {
            for file in published { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    /// Called only after every selected format has passed encoding, copying and checkpointing.
    public static func cleanWAV(_ wav: URL, enabled: Bool, outputs: [URL]) throws {
        guard enabled else { return }
        try Task.checkCancellation()
        guard !outputs.isEmpty, outputs.allSatisfy({ $0 != wav && FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ConnectionError("WAV cleanup was blocked because converted files are missing.")
        }
        try FileManager.default.removeItem(at: wav)
    }
}

public enum TrackReadProgress {
    /// cd-paranoia writes a 44-byte WAV header followed by stereo PCM (2352 bytes/sector).
    public static func fraction(fileBytes: Int, sectors: Int) -> Double {
        guard sectors > 0 else { return 0 }
        return min(0.99, max(0, Double(fileBytes - min(fileBytes, 44)) / (Double(sectors) * 2352)))
    }
    static func monitor(wav: URL, sectors: Int, read: @escaping @Sendable () async throws -> CLIResult,
                        progress: @escaping @Sendable (Double) async throws -> Void) async throws -> CLIResult {
        try await withThrowingTaskGroup(of: CLIResult?.self) { group in
            group.addTask { try await read() }
            group.addTask {
                var previous = -1
                while true {
                    try await Task.sleep(for: .milliseconds(500))
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? NSNumber)?.intValue ?? 0
                    let fraction = fraction(fileBytes: bytes, sectors: sectors)
                    let percent = Int(fraction * 100)
                    if percent != previous { try await progress(fraction); previous = percent }
                }
            }
            defer { group.cancelAll() }
            while let result = try await group.next() { if let result { return result } }
            throw CancellationError()
        }
    }
}
