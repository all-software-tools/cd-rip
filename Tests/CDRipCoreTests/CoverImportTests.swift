import Foundation
import ImageIO
import AppKit
import Testing
@testable import CDRipCore

@Test func coverPageExtractsGalleryAndMetadataLinksWithoutExecutingHTML() throws {
    let html = #"""
    <meta content="//cdn.example.org/front.webp?a=1&amp;b=2" property="og:image">
    <img src="//cdn.example.org/front.webp?a=1&amp;b=2" itemprop="image">
    <a href="/large/back.webp">Back</a><img src='http://127.0.0.1/private.jpg'>
    <script>fetch('https://evil.example.com/x')</script><img src="file:///tmp/test.png">
    """#
    let rows = CoverImportService.images(in: html, pageURL: URL(string: "https://example.org/album")!)
    #expect(rows.count == 2)
    #expect(rows[0].url.absoluteString == "https://cdn.example.org/front.webp?a=1&b=2")
    #expect(rows[1].url.absoluteString == "https://example.org/large/back.webp")
    for value in ["http://example.com/a", "https://127.0.0.1/a", "https://test.local/a", "https://example.com:444/a", "https://user:pass@example.org/a"] {
        #expect(throws: ConnectionError.self) { try CoverAddress.validate(URL(string: value)!) }
    }
}
@Test func catalogRetriesBackOffAndRespectServerCooldown() {
    #expect(CatalogRetryPolicy.delay(status: 503, attempt: 0, retryAfter: nil) == 2)
    #expect(CatalogRetryPolicy.delay(status: 503, attempt: 2, retryAfter: nil) == 8)
    #expect(CatalogRetryPolicy.delay(status: 503, attempt: 3, retryAfter: nil) == nil)
    #expect(CatalogRetryPolicy.delay(status: 429, attempt: 0, retryAfter: "20") == 20)
    #expect(CatalogRetryPolicy.delay(status: 429, attempt: 0, retryAfter: "300") == nil)
    #expect(CatalogRetryPolicy.delay(status: 404, attempt: 0, retryAfter: nil) == nil)
}
@Test func coverRejectsInvalidBytesAndConvertsToDecodableJPEG() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = URL(string: "https://example.org/front.png")!
    #expect(throws: ConnectionError.self) { try CoverImportService.save(Data("<html>not an image</html>".utf8), pageURL: url, imageURL: url, directory: root) }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 50, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let cover = try CoverImportService.save(data, pageURL: url, imageURL: url, directory: root)
    #expect(cover.width == 40 && cover.height == 50)
    let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: cover.filePath) as CFURL, nil))
    #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_LIVE_COVER_IMPORT"] == "1"))
func explicitLiveBazarCoverImport() async throws {
    let service = CoverImportService()
    let page = try await service.discover("https://bazar.bg/obiava-54599931/2-x-cd-disco-serie-gold")
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CDRIP_COVER_TEST_DIR"]))
    print("LIVE COVER LINKS: " + page.candidates.map { $0.url.absoluteString }.joined(separator: " | "))
    let candidate = try #require(page.candidates.first { $0.url.path.contains("/large/") } ?? page.candidates.first)
    let result = try await service.download(candidate, pageURL: page.url, directory: root)
    print("LIVE COVER: \(page.candidates.count) image links, JPEG \(result.width)x\(result.height), saved: \(result.filePath)")
    #expect(result.width > 100)
}

@Test func capturedBazarGalleryExtractsFullSizeLinksWhenPresent() throws {
    guard let path = ProcessInfo.processInfo.environment["CDRIP_BAZAR_HTML"] else { return }
    let html = try String(contentsOfFile: path, encoding: .utf8)
    let rows = CoverImportService.images(in: html, pageURL: URL(string: "https://bazar.bg/obiava-54599931/2-x-cd-disco-serie-gold")!)
    print("CAPTURED BAZAR: " + rows.map { $0.url.absoluteString }.joined(separator: " | "))
    #expect(rows.contains { $0.url.path.contains("/large/") })
}
