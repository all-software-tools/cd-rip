import Foundation
import ImageIO

public struct ArtistCredit: Decodable, Sendable {
    public let name: String
    public let joinphrase: String?
    static func text(_ credits: [ArtistCredit]?) -> String { credits?.map { $0.name + ($0.joinphrase ?? "") }.joined() ?? "" }
}
public struct CatalogGenre: Decodable, Sendable {
    public let name: String
    public let count: Int
}
public struct CatalogRecording: Decodable, Sendable {
    public let id: String
    public let title: String
    public let length: Int?
    public let artistCredit: [ArtistCredit]?
    public let genres: [CatalogGenre]?
    public let disambiguation: String?
    public var artist: String { ArtistCredit.text(artistCredit) }
    enum CodingKeys: String, CodingKey { case id, title, length, genres, disambiguation; case artistCredit = "artist-credit" }
}
public struct CatalogTrack: Decodable, Identifiable, Sendable {
    public let id: String
    public let position: Int
    public let title: String?
    public let length: Int?
    public let artistCredit: [ArtistCredit]?
    public let recording: CatalogRecording
    enum CodingKeys: String, CodingKey { case id, position, title, length, recording; case artistCredit = "artist-credit" }
    public var trackTitle: String { title ?? recording.title }
    public var duration: Double? { (length ?? recording.length).map { Double($0) / 1000 } }
    public func artist(albumArtist: String) -> String {
        let track = ArtistCredit.text(artistCredit)
        let recording = ArtistCredit.text(recording.artistCredit)
        return !track.isEmpty ? track : (!recording.isEmpty ? recording : albumArtist)
    }
}
public struct CatalogDisc: Decodable, Sendable {
    public let id: String
}
public struct CatalogMedium: Decodable, Identifiable, Sendable {
    public var id: Int { position }
    public let position: Int
    public let format: String?
    public let tracks: [CatalogTrack]?
    public let discs: [CatalogDisc]?
    public func contains(discID: String) -> Bool { discs?.contains { $0.id == discID } == true }
    enum CodingKeys: String, CodingKey { case position, format, tracks, discs }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Search summaries omit medium position; lookup responses must supply it before use.
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        format = try c.decodeIfPresent(String.self, forKey: .format)
        tracks = try c.decodeIfPresent([CatalogTrack].self, forKey: .tracks)
        discs = try c.decodeIfPresent([CatalogDisc].self, forKey: .discs)
    }
}
public struct CatalogRelease: Decodable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let date: String?
    public let country: String?
    public let disambiguation: String?
    public let artistCredit: [ArtistCredit]?
    public let media: [CatalogMedium]?
    enum CodingKeys: String, CodingKey { case id, title, date, country, disambiguation, media; case artistCredit = "artist-credit" }
    public var artist: String { ArtistCredit.text(artistCredit) }
    public var edition: String { [date, country, disambiguation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
}

private final class CatalogRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, let host = url.host else { return false }
        return ["musicbrainz.org", "coverartarchive.org", "archive.org"].contains(host) || host.hasSuffix(".archive.org")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.allowed(request.url) ? request : nil)
    }
}
public protocol CatalogFetching: Sendable {
    func get(_ url: URL, limit: Int) async throws -> Data
}

public struct CatalogNotFound: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "No metadata or cover art is available for this catalog entry." }
}

public struct CatalogUnavailable: LocalizedError, Sendable {
    public let status: Int
    public init(status: Int) { self.status = status }
    public var errorDescription: String? { "MusicBrainz / catalog unavailable (HTTP \(status)). This is a service error, not an unrecognized song. Retry unfinished tracks later." }
}

struct CatalogRetryPolicy {
    static func delay(status: Int, attempt: Int, retryAfter: String?, now: Date = Date()) -> Double? {
        guard [429, 500, 502, 503, 504].contains(status), attempt < 3 else { return nil }
        var delay = pow(2, Double(attempt + 1))
        if let retryAfter {
            if let seconds = Double(retryAfter), seconds.isFinite { delay = max(delay, seconds) }
            else {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                if let date = formatter.date(from: retryAfter) { delay = max(delay, date.timeIntervalSince(now)) }
            }
        }
        // Long server cooldowns are surfaced, never retried earlier than requested.
        return delay <= 30 ? delay : nil
    }
}

/// Shared across catalog views: reserves rate-limit slots before suspending and caches responses.
public actor CatalogHTTP: CatalogFetching {
    public static let shared = CatalogHTTP()
    private var nextSlot = ContinuousClock.now
    private var cache: [URL: (Date, Data)] = [:]
    public init() {}
    public func get(_ url: URL, limit: Int) async throws -> Data {
        guard CatalogRedirects.allowed(url) else { throw ConnectionError("This catalog address is not allowed.") }
        if let (date, data) = cache[url], Date().timeIntervalSince(date) < 3600, data.count <= limit { return data }
        for attempt in 0..<4 {
            let slot = max(ContinuousClock.now, nextSlot)
            nextSlot = slot + .milliseconds(1500)
            try await ContinuousClock().sleep(until: slot)
            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            request.setValue("CDRip/0.3.5 (local macOS CD metadata; https://mykey.digital)", forHTTPHeaderField: "User-Agent")
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 35
            let session = URLSession(configuration: config, delegate: CatalogRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let delay = CatalogRetryPolicy.delay(status: status, attempt: attempt,
                retryAfter: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")) {
                session.invalidateAndCancel()
                nextSlot = max(nextSlot, ContinuousClock.now + .seconds(delay))
                continue
            }
            if status == 404 { throw CatalogNotFound() }
            guard status == 200 else { throw CatalogUnavailable(status: status) }
            guard response.expectedContentLength <= Int64(limit) else { throw ConnectionError("The catalog response exceeds the download limit.") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw ConnectionError("The catalog response exceeds the download limit.") }
                data.append(byte)
            }
            try Task.checkCancellation()
            if cache.count >= 128, let oldest = cache.min(by: { $0.value.0 < $1.value.0 }) { cache.removeValue(forKey: oldest.key) }
            cache[url] = (Date(), data)
            return data
        }
        throw ConnectionError("The catalog is busy. Please try again later.")
    }
}

public struct MusicCatalog: Sendable {
    private let http: any CatalogFetching
    public init(http: any CatalogFetching = CatalogHTTP.shared) { self.http = http }
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    public func lookupDisc(_ disc: OpticalDiscInfo) async throws -> [CatalogRelease] {
        let id = try MusicBrainzDiscID.calculate(disc)
        var url = URLComponents(string: "https://musicbrainz.org/ws/2/discid/\(id)")!
        // Exact lookup only: no fuzzy TOC fallback or unreviewed CD stubs.
        url.queryItems = [.init(name: "inc", value: "artist-credits"), .init(name: "fmt", value: "json"), .init(name: "cdstubs", value: "no")]
        struct Response: Decodable { let id: String; let releases: [CatalogRelease] }
        do {
            let response = try JSONDecoder().decode(Response.self, from: await http.get(url.url!, limit: 2_000_000))
            guard response.id == id, response.releases.allSatisfy({ UUID(uuidString: $0.id) != nil }),
                  Set(response.releases.map(\.id)).count == response.releases.count else {
                throw ConnectionError("The catalog returned an invalid CD lookup response.")
            }
            return response.releases
        } catch is CatalogNotFound { return [] }
    }
    public func search(artist: String, album: String) async throws -> [CatalogRelease] {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty || !album.isEmpty, artist.count < 500, album.count < 500 else { throw ConnectionError("Enter an artist or album (maximum 500 characters).") }
        let terms = [("artist", artist), ("release", album)].filter { !$0.1.isEmpty }.map { $0.0 + ":" + Self.quoted($0.1) }
        var url = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        url.queryItems = [.init(name: "query", value: terms.joined(separator: " AND ")), .init(name: "fmt", value: "json"), .init(name: "limit", value: "25")]
        struct Search: Decodable { let releases: [CatalogRelease] }
        return try JSONDecoder().decode(Search.self, from: await http.get(url.url!, limit: 2_000_000)).releases
    }
    public func release(_ id: String) async throws -> CatalogRelease {
        guard UUID(uuidString: id) != nil else { throw ConnectionError("Invalid release ID.") }
        var url = URLComponents(string: "https://musicbrainz.org/ws/2/release/\(id)")!
        url.queryItems = [.init(name: "inc", value: "recordings+artist-credits+discids"), .init(name: "fmt", value: "json")]
        let release = try JSONDecoder().decode(CatalogRelease.self, from: await http.get(url.url!, limit: 2_000_000))
        guard release.id == id, release.media?.allSatisfy({ $0.position > 0 }) == true else { throw ConnectionError("The catalog returned a different release.") }
        return release
    }
    public func recordings(artist: String, title: String) async throws -> [CatalogRecording] {
        guard !artist.isEmpty, !title.isEmpty, artist.count <= 500, title.count <= 500 else { throw ConnectionError("Enter an artist and title, each no longer than 500 characters.") }
        var url = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")!
        url.queryItems = [.init(name: "query", value: "artist:" + Self.quoted(artist) + " AND recording:" + Self.quoted(title)), .init(name: "fmt", value: "json"), .init(name: "limit", value: "100")]
        struct Search: Decodable { let recordings: [CatalogRecording] }
        let rows = try JSONDecoder().decode(Search.self, from: await http.get(url.url!, limit: 2_000_000)).recordings
        guard rows.allSatisfy({ UUID(uuidString: $0.id) != nil }), Set(rows.map(\.id)).count == rows.count else { throw ConnectionError("Invalid catalog recording IDs.") }
        return rows
    }
    public func recording(_ id: String) async throws -> CatalogRecording {
        guard UUID(uuidString: id) != nil else { throw ConnectionError("Invalid recording ID.") }
        var url = URLComponents(string: "https://musicbrainz.org/ws/2/recording/\(id)")!
        url.queryItems = [.init(name: "inc", value: "artist-credits+genres"), .init(name: "fmt", value: "json")]
        let row = try JSONDecoder().decode(CatalogRecording.self, from: await http.get(url.url!, limit: 2_000_000))
        guard row.id == id else { throw ConnectionError("The catalog returned a different recording.") }
        return row
    }
    public func cover(releaseID: String, directory: URL) async throws -> URL {
        guard UUID(uuidString: releaseID) != nil else { throw ConnectionError("Invalid release ID.") }
        let data = try await http.get(URL(string: "https://coverartarchive.org/release/\(releaseID)/front-500")!, limit: 8_000_000)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png"].contains(type),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 6000, height <= 6000, width * height <= 25_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw ConnectionError("The cover must be a valid JPEG/PNG within the supported size limits.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(releaseID + (type == "public.jpeg" ? ".jpg" : ".png"))
        try data.write(to: file, options: .atomic)
        return file
    }
}
