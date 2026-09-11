import Foundation
import ImageIO

public struct TagRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let metadata: TrackMetadata
    public let outputPaths: [String]
    public let originalPaths: [String]
}

/// Writes a new, versioned copy. It never changes originals or approves audio for broadcast.
public struct AudioTagWriter: Sendable {
    private let runner: any CLIRunning
    private let ffmpeg: String
    private let ffprobe: String
    public init(runner: any CLIRunning = LocalCLIRunner(), ffmpeg: String = AudioToolPaths.executable("ffmpeg"), ffprobe: String = AudioToolPaths.executable("ffprobe")) {
        self.runner = runner; self.ffmpeg = ffmpeg; self.ffprobe = ffprobe
    }
    public static func relativePath(metadata: TrackMetadata, number: Int, extension ext: String) -> String {
        let artist = metadata.albumArtist.isEmpty ? metadata.artist : metadata.albumArtist
        let folder = ext.uppercased() + "/" + OutputFiles.safeComponent(artist.isEmpty ? "Artist not provided" : artist) + "/" + OutputFiles.safeComponent(metadata.album.isEmpty ? "Album not provided" : metadata.album)
        return folder + (metadata.discTotal > 1 ? String(format: "/Disc %02d", metadata.discNumber) : "") + "/" + OutputFiles.filename(number: number, artist: metadata.artist, title: metadata.title, extension: ext)
    }
    public func write(metadata: TrackMetadata, number: Int, total: Int, inputs: [URL], destination: URL) async throws -> TagRevision {
        guard !metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !metadata.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...99).contains(number), total >= number, total <= 99,
              metadata.discNumber >= 1, metadata.discTotal >= metadata.discNumber, metadata.discTotal <= 99,
              !inputs.isEmpty, inputs.count <= 2, Set(inputs.map(\.pathExtension)).count == inputs.count,
              inputs.allSatisfy({ $0.isFileURL && ["mp3", "flac"].contains($0.pathExtension) }),
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw ConnectionError("Enter the artist/title and check track numbering. The destination must be new and the MP3/FLAC sources available.")
        }
        let size = try inputs.reduce(Int64(0)) { sum, file in
            let value = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard value.isRegularFile == true, let bytes = value.fileSize, bytes > 0 else { throw ConnectionError("Missing or invalid audio file.") }
            return sum + Int64(bytes)
        }
        let parent = destination.deletingLastPathComponent()
        _ = try OutputFiles.validateDestination(parent, requiredBytes: size * 2 + 32 * 1024 * 1024)
        let stage = parent.appendingPathComponent(".cdrip-tags-\(UUID())")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        var cover: URL?
        if let path = metadata.coverPath {
            let source = URL(fileURLWithPath: path)
            let bytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard bytes <= 8_000_000 else { throw ConnectionError("The cover must be no larger than 8 MB.") }
            let data = try Data(contentsOf: source)
            guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) == 1,
                  let type = CGImageSourceGetType(image) as String?, ["public.jpeg", "public.png"].contains(type),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 6000, height <= 6000, width * height <= 25_000_000,
                  CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else { throw ConnectionError("The cover must be a valid JPEG/PNG within the supported size limits.") }
            let file = stage.appendingPathComponent(type == "public.jpeg" ? "cover.jpg" : "cover.png")
            try data.write(to: file, options: .withoutOverwriting)
            cover = file
        }
        let tags = ["title": metadata.title, "artist": metadata.artist, "album": metadata.album,
                    "album_artist": metadata.albumArtist, "date": metadata.year, "genre": metadata.genre,
                    "track": "\(number)/\(total)", "disc": "\(metadata.discNumber)/\(metadata.discTotal)"]
        var outputPaths: [String] = []
        for input in inputs {
            try Task.checkCancellation()
            let before = try await hashes(input, directory: stage)
            let relative = Self.relativePath(metadata: metadata, number: number, extension: input.pathExtension)
            let file = stage.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var args = ["-nostdin", "-v", "error", "-n", "-i", input.path]
            if let cover { args += ["-i", cover.path] }
            args += ["-map", "0:a:0", "-map_metadata", "-1", "-c:a", "copy"]
            if cover != nil { args += ["-map", "1:v:0", "-c:v", "copy", "-disposition:v:0", "attached_pic", "-metadata:s:v:0", "title=Album cover", "-metadata:s:v:0", "comment=Cover (front)"] }
            if input.pathExtension == "mp3" { args += ["-id3v2_version", "3"] }
            for key in tags.keys.sorted() where !tags[key]!.isEmpty { args += ["-metadata", key + "=" + tags[key]!] }
            args.append(file.path)
            let result = try await runner.run(path: ffmpeg, arguments: args, directory: stage, timeout: .seconds(90))
            guard result.code == 0, result.output.isEmpty else { throw ConnectionError("Tag writing failed. Originals are preserved.") }
            let after = try await hashes(file, directory: stage)
            guard before == after else { throw ConnectionError("Audio changed after tagging. The copy was not finalized; originals are preserved.") }
            try await validate(file, tags: tags, cover: cover, directory: stage)
            outputPaths.append(destination.appendingPathComponent(relative).path)
        }
        if let cover { try FileManager.default.removeItem(at: cover) }
        let revision = TagRevision(id: UUID(), createdAt: Date(), metadata: metadata, outputPaths: outputPaths, originalPaths: inputs.map(\.path))
        try JSONEncoder().encode(revision).write(to: stage.appendingPathComponent("tag-revision.json"), options: .atomic)
        try Data("Tagged copies. The source audio verification status is unchanged. Originals and previous versions are preserved.\n".utf8).write(to: stage.appendingPathComponent("NEEDS-REVIEW.txt"))
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: destination)
        return revision
    }
    private func hashes(_ file: URL, directory: URL) async throws -> [String] {
        var values: [String] = []
        for codec in ["copy", "pcm_s16le"] {
            let result = try await runner.run(path: ffmpeg, arguments: ["-nostdin", "-v", "error", "-xerror", "-err_detect", "explode", "-i", file.path, "-map", "0:a:0", "-c:a", codec, "-f", "hash", "-hash", "sha256", "-"], directory: directory, timeout: .seconds(120))
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.code == 0, text.range(of: #"^SHA256=[0-9a-f]{64}$"#, options: .regularExpression) != nil else { throw ConnectionError("The file could not be fully verified before/after tagging.") }
            values.append(text)
        }
        return values
    }
    private func validate(_ file: URL, tags: [String: String], cover: URL?, directory: URL) async throws {
        let result = try await runner.run(path: ffprobe, arguments: ["-v", "error", "-show_format", "-show_streams", "-of", "json", file.path], directory: directory, timeout: .seconds(20))
        guard result.code == 0, let object = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              let format = object["format"] as? [String: Any], let actual = format["tags"] as? [String: String],
              let streams = object["streams"] as? [[String: Any]],
              streams.filter({ $0["codec_type"] as? String == "audio" }).count == 1 else { throw ConnectionError("The written tags could not be verified.") }
        let normalized = Dictionary(actual.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        guard tags.allSatisfy({ key, value in value.isEmpty ? (normalized[key] ?? "").isEmpty : normalized[key] == value }) else { throw ConnectionError("The saved tags differ from the approved draft.") }
        let pictures = streams.filter { $0["codec_type"] as? String == "video" }
        if let cover {
            guard pictures.count == 1, let picture = pictures.first,
                  (picture["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1 else { throw ConnectionError("The cover was not embedded correctly.") }
            let extracted = directory.appendingPathComponent("check-cover-\(UUID())." + cover.pathExtension)
            defer { try? FileManager.default.removeItem(at: extracted) }
            let extract = try await runner.run(path: ffmpeg, arguments: ["-nostdin", "-v", "error", "-i", file.path, "-map", "0:v:0", "-c:v", "copy", "-frames:v", "1", "-update", "1", extracted.path], directory: directory, timeout: .seconds(20))
            guard extract.code == 0, try Data(contentsOf: extracted) == Data(contentsOf: cover) else { throw ConnectionError("The embedded cover differs from the selected image.") }
        } else if !pictures.isEmpty { throw ConnectionError("The copy contains a cover that was not selected.") }
    }
}
