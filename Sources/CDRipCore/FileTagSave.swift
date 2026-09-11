import Foundation
import CryptoKit

public struct FileTagSavePlan: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let original: String
        public let output: String
        public let staged: String
        public let backup: String
        public let originalHash: String
        public let taggedHash: String
        public var backupCopied: Bool? = nil
    }
    public let revision: TagRevision
    public let files: [File]
}

/// Verified replacements in the existing MP3/FLAC folders, with persistent recovery information.
public actor FileTagSaver {
    public init() {}
    public func checkFiles(_ tracks: [SessionTrack]) -> [String: String] {
        var issues: [String: String] = [:]
        for track in tracks { for path in track.outputPaths {
            do {
                let url = URL(fileURLWithPath: path)
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ConnectionError("Not a regular audio file.") }
                if let expected = track.savedFileHashes?[path], try Self.hash(path) != expected {
                    issues[path] = "Audio file changed outside CD Rip: " + url.lastPathComponent + ". It will not be overwritten."
                }
            } catch { issues[path] = "Audio file missing or unreadable: " + path + ". Locate or restore it before saving." }
        } }
        return issues
    }
    public nonisolated static func filename(metadata: TrackMetadata, extension ext: String) -> String {
        OutputFiles.safeComponent(metadata.artist + " - " + metadata.title) + "." + OutputFiles.safeComponent(ext)
    }
    public func prepare(metadata: TrackMetadata, number: Int, total: Int, inputs: [URL], destinations: [URL]? = nil, backupRoot: URL? = nil) async throws -> FileTagSavePlan {
        let fm = FileManager.default, id = UUID()
        guard let first = inputs.first else { throw ConnectionError("No extracted files to save.") }
        let outputs = destinations ?? inputs.map { $0.deletingLastPathComponent().appendingPathComponent(Self.filename(metadata: metadata, extension: $0.pathExtension)) }
        if destinations != nil {
            for output in outputs {
                _ = try OutputFiles.validateDestination(output.deletingLastPathComponent().deletingLastPathComponent(), requiredBytes: 0)
            }
        }
        guard outputs.count == inputs.count else { throw ConnectionError("Invalid output destinations.") }
        for (input, output) in zip(inputs, outputs) {
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard try input.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ConnectionError("Save requires regular audio files, not symbolic links.") }
            guard !fm.fileExists(atPath: output.path) || Self.sameFile(input, output) else { throw ConnectionError("A file already exists with the new name: \(output.lastPathComponent). Nothing was overwritten.") }
        }
        let work = (backupRoot ?? first.deletingLastPathComponent()).appendingPathComponent(".cdrip-save-work-\(id)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let before = try inputs.map { try Self.hash($0.path) }
        let tagged = try await AudioTagWriter().write(metadata: metadata, number: number, total: total, inputs: inputs, destination: work.appendingPathComponent("Verified"))
        var files: [FileTagSavePlan.File] = []
        do {
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                guard try Self.hash(input.path) == before[index] else { throw ConnectionError("An audio file changed while preparing tags. Please retry.") }
                let hidden = (backupRoot ?? input.deletingLastPathComponent().appendingPathComponent(".cdrip-backups")).appendingPathComponent(id.uuidString)
                try fm.createDirectory(at: hidden, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let source = tagged.outputPaths[index]
                let staged = backupRoot == nil ? hidden.appendingPathComponent("prepared." + input.pathExtension) : outputs[index].deletingLastPathComponent().appendingPathComponent(".cdrip-prepared-" + id.uuidString + "." + input.pathExtension)
                let backup = hidden.appendingPathComponent("original." + input.pathExtension)
                try fm.copyItem(atPath: source, toPath: staged.path)
                let taggedHash = try Self.hash(source)
                guard try Self.hash(staged.path) == taggedHash else { throw ConnectionError("Prepared tags could not be copied safely.") }
                if backupRoot != nil {
                    try fm.copyItem(at: input, to: backup)
                    guard try Self.hash(backup.path) == before[index] else { throw ConnectionError("Original backup verification failed.") }
                }
                files.append(.init(original: input.path, output: outputs[index].path, staged: staged.path, backup: backup.path, originalHash: before[index], taggedHash: taggedHash, backupCopied: backupRoot == nil ? nil : true))
            }
            return FileTagSavePlan(revision: .init(id: id, createdAt: Date(), metadata: metadata,
                outputPaths: files.map(\.output), originalPaths: files.map(\.backup)), files: files)
        } catch {
            for file in files { try? fm.removeItem(atPath: file.staged) }
            throw error
        }
    }
    public func commit(_ plan: FileTagSavePlan) throws {
        let fm = FileManager.default
        do {
            try Task.checkCancellation()
            for file in plan.files {
                guard try Self.hash(file.original) == file.originalHash, try Self.hash(file.staged) == file.taggedHash,
                      (file.backupCopied == true ? try Self.hash(file.backup) == file.originalHash : !fm.fileExists(atPath: file.backup)), !fm.fileExists(atPath: file.output) || Self.sameFile(URL(fileURLWithPath: file.original), URL(fileURLWithPath: file.output)) else { throw ConnectionError("A file changed or its new name is already taken. Save stopped without overwriting it.") }
            }
            // No suspension/cancellation boundary between the moves; persisted plan handles process interruption.
            for file in plan.files {
                if file.backupCopied == true { try fm.removeItem(atPath: file.original) }
                else { try fm.moveItem(atPath: file.original, toPath: file.backup) }
                try fm.moveItem(atPath: file.staged, toPath: file.output)
            }
            guard try committed(plan) else { throw ConnectionError("Saved file verification failed.") }
        } catch {
            do { try rollback(plan) }
            catch { throw ConnectionError("Save recovery needs attention. Backups are preserved: \(plan.files.first?.backup ?? ""). \(error.localizedDescription)") }
            throw error
        }
    }
    /// Called on startup for a plan checkpointed before any replacement. True means committed.
    public func recover(_ plan: FileTagSavePlan) throws -> Bool {
        if try committed(plan) { return true }
        try rollback(plan)
        return false
    }
    private func committed(_ plan: FileTagSavePlan) throws -> Bool {
        for file in plan.files {
            guard FileManager.default.fileExists(atPath: file.output), FileManager.default.fileExists(atPath: file.backup),
                  try Self.hash(file.output) == file.taggedHash, try Self.hash(file.backup) == file.originalHash else { return false }
        }
        return !plan.files.isEmpty
    }
    private func rollback(_ plan: FileTagSavePlan) throws {
        let fm = FileManager.default
        for file in plan.files.reversed() {
            if fm.fileExists(atPath: file.backup) {
                guard try Self.hash(file.backup) == file.originalHash else { throw ConnectionError("Backup content changed; manual recovery required.") }
                if file.backupCopied == true, fm.fileExists(atPath: file.original), try Self.hash(file.original) == file.originalHash {
                    if file.output != file.original, fm.fileExists(atPath: file.output) {
                        guard try Self.hash(file.output) == file.taggedHash else { throw ConnectionError("Output changed; manual recovery required.") }
                        try fm.removeItem(atPath: file.output)
                    }
                    if fm.fileExists(atPath: file.staged) { try fm.removeItem(atPath: file.staged) }
                    continue
                }
                if fm.fileExists(atPath: file.output) {
                    guard try Self.hash(file.output) == file.taggedHash else { throw ConnectionError("The output was changed by another program; it was preserved.") }
                    try fm.removeItem(atPath: file.output)
                }
                guard !fm.fileExists(atPath: file.original) else { throw ConnectionError("The original filename is occupied; backup was preserved.") }
                if file.backupCopied == true { try fm.copyItem(atPath: file.backup, toPath: file.original) }
                else { try fm.moveItem(atPath: file.backup, toPath: file.original) }
            } else {
                guard fm.fileExists(atPath: file.original), try Self.hash(file.original) == file.originalHash else { throw ConnectionError("Original file missing or changed; manual recovery required.") }
            }
            if fm.fileExists(atPath: file.staged) { try fm.removeItem(atPath: file.staged) }
        }
    }
    private static func sameFile(_ first: URL, _ second: URL) -> Bool {
        if first.standardizedFileURL == second.standardizedFileURL { return true }
        guard let a = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
              let b = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject else { return false }
        return a.isEqual(b)
    }
    static func hash(_ path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
