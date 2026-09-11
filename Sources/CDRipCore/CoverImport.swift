import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

public struct ImportedCover: Codable, Equatable, Sendable {
    public let filePath: String
    public let pageURL: String
    public let imageURL: String
    public let width: Int
    public let height: Int
    public let retrievedAt: Date
}
public struct CoverCandidate: Identifiable, Equatable, Sendable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let label: String
}
public struct CoverPage: Sendable {
    public let url: URL
    public let candidates: [CoverCandidate]
}

/// Public HTTPS only; no cookies, authorization, scripts or access to local services.
enum CoverAddress {
    static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(),
              host.count <= 253, host.contains("."), !host.hasSuffix("."),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              host.split(separator: ".").allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }),
              host.contains(where: { $0.isLetter }), url.absoluteString.count <= 4096 else {
            throw ConnectionError("Enter a public HTTPS page or image URL without credentials or a custom port.")
        }
    }
    static func checkPublicDNS(_ url: URL) async throws {
        try validate(url)
        // DNS resolution is blocking system I/O; keep it off the main actor.
        let safe = await Task.detached(priority: .utility) {
            var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(url.host!, nil, &hints, &result) == 0, let first = result else { return false }
            defer { freeaddrinfo(first) }
            var node: UnsafeMutablePointer<addrinfo>? = first
            while let current = node {
                let info = current.pointee
                if info.ai_family == AF_INET {
                    let address = UnsafeRawPointer(info.ai_addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
                    let a = address >> 24, b = (address >> 16) & 255
                    if a == 0 || a == 10 || a == 127 || a >= 224 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) { return false }
                } else if info.ai_family == AF_INET6 {
                    let address = UnsafeRawPointer(info.ai_addr).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    let bytes = withUnsafeBytes(of: address) { Array($0) }
                    // Public global unicast only. Reject loopback, link-local, mapped IPv4 and ULA.
                    if bytes[0] & 0xe0 != 0x20 { return false }
                } else { return false }
                node = info.ai_next
            }
            return true
        }.value
        try Task.checkCancellation()
        guard safe else { throw ConnectionError("The cover URL must resolve to a public internet address.") }
    }
}
private final class CoverRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard task.countOfBytesReceived < 8_000_000, let url = request.url else { completionHandler(nil); return }
        Task {
            do { try await CoverAddress.checkPublicDNS(url); completionHandler(request) }
            catch { completionHandler(nil) }
        }
    }
}
public struct CoverResource: Sendable {
    public let data: Data
    public let url: URL
    public let mimeType: String?
}
public protocol CoverFetching: Sendable {
    func get(_ url: URL) async throws -> CoverResource
}
public struct CoverHTTP: CoverFetching {
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = 45) { self.timeout = max(1, timeout) }
    public func get(_ url: URL) async throws -> CoverResource {
        try await CoverAddress.checkPublicDNS(url)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: CoverRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = min(25, timeout)
        request.setValue("CDRip/0.3.5 (cover import; https://mykey.digital)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, let final = response.url else {
            throw ConnectionError("The cover page or image could not be downloaded. Try a direct image URL or choose a local file.")
        }
        try CoverAddress.validate(final)
        let limit = response.mimeType?.contains("html") == true ? 2_000_000 : 8_000_000
        guard response.expectedContentLength <= limit else { throw ConnectionError("The cover download exceeds the size limit.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ConnectionError("The cover download exceeds the size limit.") }
            data.append(byte)
        }
        try Task.checkCancellation()
        return CoverResource(data: data, url: final, mimeType: response.mimeType)
    }
}

public struct CoverImportService: Sendable {
    private let http: any CoverFetching
    public init(http: any CoverFetching = CoverHTTP()) { self.http = http }
    public func discover(_ text: String) async throws -> CoverPage {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ConnectionError("Enter a valid HTTPS URL.") }
        try CoverAddress.validate(url)
        let resource = try await http.get(url)
        try Task.checkCancellation()
        if let imageSource = CGImageSourceCreateWithData(resource.data as CFData, nil),
           let type = CGImageSourceGetType(imageSource) as String?,
           ["public.jpeg", "public.png", "org.webmproject.webp"].contains(type), CGImageSourceGetCount(imageSource) > 0 {
            return CoverPage(url: resource.url, candidates: [.init(url: resource.url, label: "Direct image")])
        }
        guard resource.data.count <= 2_000_000, let html = String(data: resource.data, encoding: .utf8) else {
            throw ConnectionError("This is not a supported image or HTML page.")
        }
        let candidates = Self.images(in: html, pageURL: resource.url)
        guard !candidates.isEmpty else { throw ConnectionError("No image links found on this page. Paste a direct image URL or choose a local file.") }
        return CoverPage(url: resource.url, candidates: candidates)
    }
    public func download(_ candidate: CoverCandidate, pageURL: URL, directory: URL) async throws -> ImportedCover {
        let resource = try await http.get(candidate.url)
        try Task.checkCancellation()
        return try Self.save(resource.data, pageURL: pageURL, imageURL: resource.url, directory: directory)
    }
    static func save(_ data: Data, pageURL: URL, imageURL: URL, directory: URL) throws -> ImportedCover {
        guard data.count <= 8_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png", "org.webmproject.webp"].contains(type),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 6000, height <= 6000, width * height <= 25_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConnectionError("Choose a valid, still JPEG, PNG or WebP image: maximum 8 MB, 6000 pixels per side and 25 megapixels.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw ConnectionError("Could not prepare the cover image.") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 8_000_000 else { throw ConnectionError("Could not save a JPEG cover within the size limit.") }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + ".jpg")
        try (output as Data).write(to: file, options: .atomic)
        return ImportedCover(filePath: file.path, pageURL: pageURL.absoluteString, imageURL: imageURL.absoluteString, width: width, height: height, retrievedAt: Date())
    }
    /// Extract only image links, never execute HTML or use page content as AI instructions.
    static func images(in html: String, pageURL: URL) -> [CoverCandidate] {
        let nonContent = try! NSRegularExpression(pattern: #"<script\b[^>]*>[\s\S]*?</script\s*>|<style\b[^>]*>[\s\S]*?</style\s*>|<!--[\s\S]*?-->"#, options: [.caseInsensitive])
        let html = nonContent.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
        var ranked: [(Int, CoverCandidate)] = []
        let tagRE = try! NSRegularExpression(pattern: #"<(meta|img|a|link)\b[^>]*>"#, options: [.caseInsensitive])
        let attrRE = try! NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
        for match in tagRE.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(2000) {
            let tag = (html as NSString).substring(with: match.range)
            var attrs: [String: String] = [:]
            for a in attrRE.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                let key = (tag as NSString).substring(with: a.range(at: 1)).lowercased()
                let valueRange = (2...4).map { a.range(at: $0) }.first { $0.location != NSNotFound }!
                attrs[key] = entities((tag as NSString).substring(with: valueRange))
            }
            let kind = (html as NSString).substring(with: match.range(at: 1)).lowercased()
            let marker = (attrs["property"] ?? attrs["name"] ?? "").lowercased()
            var values: [(Int, String)] = []
            if kind == "meta", ["og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src"].contains(marker), let content = attrs["content"] { values.append((0, content)) }
            if kind == "a", let href = attrs["href"], isImage(href) { values.append((1, href)) }
            if kind == "link", attrs["rel"] == "image_src", let href = attrs["href"] { values.append((0, href)) }
            if kind == "img" {
                for key in ["data-src", "src"] { if let value = attrs[key], !["svg", "gif", "ico"].contains(URL(string: value)?.pathExtension.lowercased() ?? "") { values.append((attrs["itemprop"] == "image" ? 2 : 3, value)) } }
            }
            for (rank, value) in values {
                guard let url = URL(string: value, relativeTo: pageURL)?.absoluteURL, (try? CoverAddress.validate(url)) != nil else { continue }
                let label = attrs["alt"] ?? attrs["title"] ?? (rank == 0 ? "Page preview image" : "Image from page")
                ranked.append((rank, .init(url: url, label: String(label.prefix(160)))))
            }
        }
        var seen = Set<String>()
        return ranked.enumerated().sorted { $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0 }
            .map { $0.element.1 }.filter { seen.insert($0.id).inserted }.prefix(24).map { $0 }
    }
    private static func isImage(_ text: String) -> Bool {
        guard let url = URL(string: text) else { return false }
        return ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased())
    }
    private static func entities(_ text: String) -> String {
        var result = text
        for (key, value) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">") ] { result = result.replacingOccurrences(of: key, with: value) }
        let regex = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#)
        for m in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            let raw = (result as NSString).substring(with: m.range(at: 1))
            let value = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
            if let value, let scalar = UnicodeScalar(value), let range = Range(m.range, in: result) { result.replaceSubrange(range, with: String(scalar)) }
        }
        return result
    }
}
