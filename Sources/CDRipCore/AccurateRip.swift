import Foundation

public enum AccurateRipAccess {
    // Enable only in a release covered by Illustrate's third-party access agreement.
    // Noncommercial distribution alone does not grant database access.
    public static let databaseApproved = false
}

public struct AudioVerificationSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var mismatchRereads = 1
    public var driveOffsets: [String: Int] = [:]
    public init() {}
    public func offset(for drive: String?) -> Int? { drive.flatMap { driveOffsets[$0] } }
}

public struct AccurateRipDiscID: Codable, Equatable, Sendable {
    public let trackCount: Int
    public let id1: UInt32
    public let id2: UInt32
    public let cddb: UInt32
    public init(tracks: [OpticalTrack]) throws {
        guard (1...99).contains(tracks.count), tracks.enumerated().allSatisfy({ i, t in
            t.number == i + 1 && t.startSector >= 0 && t.sectorCount > 0 && t.startSector <= 450_150 - t.sectorCount &&
            (i == 0 || tracks[i - 1].startSector + tracks[i - 1].sectorCount == t.startSector)
        }), let first = tracks.first, let last = tracks.last else { throw ConnectionError("Invalid audio TOC for AccurateRip.") }
        trackCount = tracks.count
        let leadout = last.startSector + last.sectorCount
        let offsets = tracks.map(\.startSector) + [leadout]
        id1 = offsets.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        id2 = offsets.enumerated().reduce(UInt32(0)) { $0 &+ (UInt32(max(1, $1.element)) &* UInt32($1.offset + 1)) }
        let digits = tracks.reduce(0) { sum, t in sum + String((t.startSector + 150) / 75).compactMap(\.wholeNumberValue).reduce(0,+) }
        let seconds = (leadout + 150) / 75 - (first.startSector + 150) / 75
        cddb = UInt32(digits % 255) << 24 | UInt32(seconds) << 8 | UInt32(trackCount)
    }
    public var key: String { String(format: "%03d-%08x-%08x-%08x", trackCount, id1, id2, cddb) }
    public var url: URL {
        let hex = Array(String(format: "%08x", id1))
        return URL(string: "https://www.accuraterip.com/accuraterip/\(hex[7])/\(hex[6])/\(hex[5])/dBAR-\(key).bin")!
    }
}

public struct AccurateRipChecksums: Codable, Equatable, Sendable {
    public let v1: UInt32
    public let v2: UInt32
    public var v1Hex: String { String(format: "%08X", v1) }
    public var v2Hex: String { String(format: "%08X", v2) }
    /// Stereo signed 16-bit little-endian PCM, packed into one UInt32 per stereo frame.
    /// The first track excludes 2939 frames; the last excludes 2940 (AR's asymmetric convention).
    public static func calculate(pcm: Data, number: Int, trackCount: Int) throws -> Self {
        guard trackCount > 0, number > 0, number <= trackCount, pcm.count % 4 == 0 else { throw ConnectionError("Invalid PCM input for AccurateRip.") }
        let frames = pcm.count / 4, start = number == 1 ? 2939 : 0, end = frames - (number == trackCount ? 2940 : 0)
        guard end > start else { throw ConnectionError("Track is too short for AccurateRip boundary rules.") }
        var v1: UInt32 = 0, v2: UInt32 = 0
        try pcm.withUnsafeBytes { bytes in
            for frame in start..<end {
                if frame & 0xFFFF == 0 { try Task.checkCancellation() }
                let word = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: frame * 4, as: UInt32.self))
                let product = UInt64(word) * UInt64(frame + 1)
                let lo = UInt32(truncatingIfNeeded: product), hi = UInt32(truncatingIfNeeded: product >> 32)
                v1 = v1 &+ lo; v2 = v2 &+ lo &+ hi
            }
        }
        return .init(v1: v1, v2: v2)
    }
}

public struct AccurateRipTrackReference: Equatable, Sendable {
    public let confidence: Int
    public let checksum: UInt32
    public let offsetChecksum: UInt32 // NOT a v2 checksum; it covers one sector at frame 450.
}
public struct AccurateRipPressing: Equatable, Sendable {
    public let tracks: [AccurateRipTrackReference]
}
public enum AccurateRipRecords {
    public static let maximumBytes = 1_048_576
    public static func parse(_ data: Data, disc: AccurateRipDiscID) throws -> [AccurateRipPressing] {
        let recordSize = 13 + 9 * disc.trackCount
        guard !data.isEmpty, data.count <= maximumBytes, data.count % recordSize == 0 else { throw ConnectionError("Malformed AccurateRip response.") }
        func word(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        var result: [AccurateRipPressing] = []
        for start in stride(from: 0, to: data.count, by: recordSize) {
            guard Int(data[start]) == disc.trackCount, word(start + 1) == disc.id1, word(start + 5) == disc.id2, word(start + 9) == disc.cddb else {
                throw ConnectionError("AccurateRip response belongs to a different disc.")
            }
            var tracks: [AccurateRipTrackReference] = []
            for t in 0..<disc.trackCount {
                let p = start + 13 + t * 9
                tracks.append(.init(confidence: Int(data[p]), checksum: word(p + 1), offsetChecksum: word(p + 5)))
            }
            result.append(.init(tracks: tracks))
        }
        return result
    }
}

public enum AccurateRipStatus: String, Codable, Sendable {
    case verified, mismatch, notInDatabase, unavailable, accessPending, disabled
    public var title: String {
        switch self {
        case .verified: "AccurateRip verified"
        case .mismatch: "AccurateRip mismatch"
        case .notInDatabase: "Not in AccurateRip database"
        case .unavailable: "AccurateRip unavailable"
        case .accessPending: "AccurateRip access pending"
        case .disabled: "AccurateRip disabled"
        }
    }
}
public struct AccurateRipVerification: Codable, Equatable, Sendable {
    public let status: AccurateRipStatus
    public let discID: String
    public let checksums: AccurateRipChecksums
    public var confidence: Int? = nil
    public var version: Int? = nil
    public var pressing: Int? = nil
    public var driveID: String? = nil
    public var offsetSamples = 0
    public var offsetConfigured = false
    public var attempts = 1
    public var offsetCandidates: [Int] = []
    public var detail: String
    public var checkedAt = Date()
}
public enum AccurateRipLookup: Sendable {
    case records([AccurateRipPressing]), notFound, unavailable(String), accessPending, disabled
}
public protocol AccurateRipLookingUp: Sendable {
    func lookup(_ disc: AccurateRipDiscID) async throws -> AccurateRipLookup
}
public struct AccurateRipHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
}
public protocol AccurateRipTransport: Sendable {
    func fetch(_ url: URL) async throws -> AccurateRipHTTPResponse
}
private final class AccurateRipRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard request.url?.scheme == "https", request.url?.host == task.originalRequest?.url?.host else { return nil }
        return request
    }
}

public struct AccurateRipHTTPTransport: AccurateRipTransport {
    public init() {}
    public func fetch(_ url: URL) async throws -> AccurateRipHTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: AccurateRipRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("CDRip/0.5.0 (https://www.mykeydigital.ro/tools/cd-rip)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https", response.url?.host == url.host else { throw ConnectionError("Unexpected AccurateRip response or redirect.") }
        guard response.expectedContentLength <= AccurateRipRecords.maximumBytes else { throw ConnectionError("AccurateRip response is too large.") }
        if response.statusCode != 200 { return .init(status: response.statusCode, data: Data()) }
        var data = Data()
        for try await byte in bytes {
            if data.count & 0x7FFF == 0 { try Task.checkCancellation() }
            guard data.count < AccurateRipRecords.maximumBytes else { throw ConnectionError("AccurateRip response is too large.") }
            data.append(byte)
        }
        return .init(status: response.statusCode, data: data)
    }
}
public actor AccurateRipClient: AccurateRipLookingUp {
    private let transport: any AccurateRipTransport
    private let approved: Bool
    // One lookup per disc per rip; failures aren't silently turned into matches or cached forever.
    public init() { transport = AccurateRipHTTPTransport(); approved = AccurateRipAccess.databaseApproved }
    init(transport: any AccurateRipTransport, approved: Bool) { self.transport = transport; self.approved = approved }
    public func lookup(_ disc: AccurateRipDiscID) async throws -> AccurateRipLookup {
        try Task.checkCancellation()
        guard approved else { return .accessPending }
        do {
            let response = try await transport.fetch(disc.url)
            try Task.checkCancellation()
            if response.status == 404 { return .notFound }
            guard response.status == 200 else { return .unavailable("AccurateRip HTTP \(response.status).") }
            return .records(try AccurateRipRecords.parse(response.data, disc: disc))
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return .unavailable(error.localizedDescription)
        }
    }
}

public enum AccurateRipVerifier {
    public static func verify(_ sums: AccurateRipChecksums, disc: AccurateRipDiscID, number: Int, lookup: AccurateRipLookup) throws -> AccurateRipVerification {
        guard (1...disc.trackCount).contains(number) else { throw ConnectionError("Invalid physical track number for AccurateRip.") }
        switch lookup {
        case .records(let pressings):
            guard pressings.allSatisfy({ $0.tracks.count == disc.trackCount }) else { throw ConnectionError("Invalid AccurateRip reference track count.") }
            // v2 is preferred. Confidence is from one matching record, never summed across pressings/versions.
            for (version, sum) in [(2, sums.v2), (1, sums.v1)] {
                let matches = pressings.enumerated().filter { _, p in let r = p.tracks[number - 1]; return r.confidence > 0 && r.checksum != 0 && r.checksum == sum }
                if let best = matches.max(by: { $0.element.tracks[number - 1].confidence < $1.element.tracks[number - 1].confidence }) {
                    return .init(status: .verified, discID: disc.key, checksums: sums, confidence: best.element.tracks[number - 1].confidence, version: version, pressing: best.offset + 1, detail: "Matches an AccurateRip reference (v\(version)). Disc-edge samples excluded by the algorithm are not independently verified.")
                }
            }
            let hasReference = pressings.contains { $0.tracks[number - 1].confidence > 0 && $0.tracks[number - 1].checksum != 0 }
            return .init(status: hasReference ? .mismatch : .notInDatabase, discID: disc.key, checksums: sums, detail: hasReference ? "No matching checksum at the applied offset. This may be a read error, offset, modified audio or a different pressing. It does not prove an audio defect. WAV is retained and automatic conversion is paused for review." : "No usable reference for this track. This does not mean the read is faulty.")
        case .notFound: return .init(status: .notInDatabase, discID: disc.key, checksums: sums, detail: "Disc not found. Local read checks still apply.")
        case .unavailable(let why): return .init(status: .unavailable, discID: disc.key, checksums: sums, detail: why)
        case .accessPending: return .init(status: .accessPending, discID: disc.key, checksums: sums, detail: "Local checksums calculated. Online verification awaits third-party access approval from AccurateRip.")
        case .disabled: return .init(status: .disabled, discID: disc.key, checksums: sums, detail: "Local checksums retained; online lookup disabled in session settings.")
        }
    }
    /// Diagnostic offset suggestions only. A pressing offset is not automatically a drive calibration.
    public static func offsetCandidates(pcm: Data, references: [AccurateRipTrackReference], currentOffset: Int) throws -> [Int] {
        let targets = Set(references.filter { $0.confidence > 0 && $0.offsetChecksum != 0 }.map(\.offsetChecksum))
        guard !targets.isEmpty, pcm.count % 4 == 0 else { return [] }
        var candidates: [Int] = []
        try pcm.withUnsafeBytes { bytes in
            for delta in -2939...2939 {
                if delta % 128 == 0 { try Task.checkCancellation() }
                let start = 450 * 588 + delta
                guard start >= 0, start + 588 <= pcm.count / 4 else { continue }
                var crc: UInt32 = 0
                for i in 0..<588 {
                    let word = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: (start + i) * 4, as: UInt32.self))
                    crc = crc &+ (word &* UInt32(i + 1))
                }
                if targets.contains(crc) { candidates.append(currentOffset + delta) }
            }
        }
        return candidates.count <= 16 ? candidates : [] // Silence/repetition is not useful calibration evidence.
    }
}
