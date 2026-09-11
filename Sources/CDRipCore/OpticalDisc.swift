import Foundation
import CryptoKit

public struct OpticalTrack: Codable, Equatable, Sendable {
    public let number: Int
    public let startSector: Int
    public let sectorCount: Int
}

public struct OpticalDiscInfo: Codable, Equatable, Sendable {
    public let device: String
    public let mountPath: String
    public let tracks: [OpticalTrack]
    public var rawDevice: String { "/dev/r" + device }
}

/// cddafs TOC uses absolute CD frames, including the 150-frame lead-in.
/// Mixed-mode, multisession and pre-emphasized discs require a separate policy.
public enum AudioTOC {
    public static func parse(_ data: Data, device: String, mountPath: String) throws -> DiscDescriptor {
        guard device.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let sessions = root["Sessions"] as? [[String: Any]], sessions.count == 1,
              let session = sessions.first, let first = session["First Track"] as? Int,
              let last = session["Last Track"] as? Int, first == 1, (1...99).contains(last),
              let leadout = session["Leadout Block"] as? Int,
              let rows = session["Track Array"] as? [[String: Any]], rows.count == last else {
            throw ConnectionError("Invalid table of contents or multisession CD. Reading was not started.")
        }
        var tracks: [OpticalTrack] = []
        for (index, row) in rows.enumerated() {
            guard row["Data"] as? Bool == false, row["Pre-Emphasis Enabled"] as? Bool == false,
                  row["Point"] as? Int == index + 1, let start = row["Start Block"] as? Int,
                  start >= 150,
                  let end = index + 1 < rows.count ? rows[index + 1]["Start Block"] as? Int : leadout,
                  end > start, end <= 450_150 else {
                throw ConnectionError("Data CD, invalid table of contents or pre-emphasis: this disc type is not supported yet.")
            }
            tracks.append(.init(number: index + 1, startSector: start - 150, sectorCount: end - start))
        }
        let identity = tracks.map { "\($0.number):\($0.startSector):\($0.sectorCount)" }.joined(separator: ";")
        let id = "cd-" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        var disc = DiscDescriptor(id: id, title: "Audio CD", source: .optical, tracks: tracks.map {
            SourceTrack(id: "\(id)-track-\($0.number)", number: $0.number, duration: Double($0.sectorCount) / 75)
        })
        disc.optical = OpticalDiscInfo(device: device, mountPath: mountPath, tracks: tracks)
        return disc
    }
}

public actor MacOpticalSource: DiscSource {
    private let runner: any CLIRunning
    public init(runner: any CLIRunning = LocalCLIRunner()) { self.runner = runner }
    public func loadDisc() async throws -> DiscDescriptor {
        let discs = try await scan()
        guard discs.count == 1, let disc = discs.first else {
            throw ConnectionError(discs.isEmpty ? "No audio CD is mounted. Insert a CD and wait for it to appear in Finder." : "Multiple audio CDs found. This version supports one connected source at a time.")
        }
        return disc
    }
    public func scan() async throws -> [DiscDescriptor] {
        let volumes = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)
        var discs: [DiscDescriptor] = []
        for volume in volumes {
            try Task.checkCancellation()
            let toc = volume.appendingPathComponent(".TOC.plist")
            let result = try await runner.run(path: "/usr/sbin/diskutil", arguments: ["info", "-plist", volume.path], directory: FileManager.default.temporaryDirectory, timeout: .seconds(120))
            guard result.code == 0,
                  let info = try PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any],
                  info["FilesystemType"] as? String == "cddafs", info["Content"] as? String == "CD_partition_scheme",
                  let device = info["DeviceIdentifier"] as? String else { continue }
            let data: Data
            do { data = try Data(contentsOf: toc) }
            catch {
                throw ConnectionError("Cannot read the audio CD table of contents. Allow CD Rip access to removable volumes in macOS, then click Detect again. " + error.localizedDescription)
            }
            discs.append(try AudioTOC.parse(data, device: device, mountPath: volume.path))
        }
        return discs
    }
    public func eject(_ disc: DiscDescriptor) async throws {
        guard let optical = disc.optical else { throw ConnectionError("The source is not a physical CD.") }
        let lock = try OpticalLock(device: optical.device)
        defer { withExtendedLifetime(lock) {} }
        let current = try await loadDisc()
        guard current.id == disc.id, current.optical?.device == optical.device else { throw ConnectionError("The source has changed. Detect the CD again.") }
        let result = try await runner.run(path: "/usr/sbin/diskutil", arguments: ["eject", "/dev/" + optical.device], directory: FileManager.default.temporaryDirectory, timeout: .seconds(20))
        guard result.code == 0 else { throw ConnectionError("Could not eject the CD. Check whether another app is using it.") }
    }
}
