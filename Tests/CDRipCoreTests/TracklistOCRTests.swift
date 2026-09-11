import Foundation
import AppKit
import Testing
@testable import CDRipCore

@Test func imageTracklistSeparatesCDsRequiresSourcesAndFullDiscMapping() throws {
    let lines = [OCRTextLine(id: 1, text: "CD 1: 1. Artist - First 3:20", confidence: 0.9, x: 0.1, y: 0.9),
                 OCRTextLine(id: 2, text: "CD 2: 1. Artist - Second 4:20", confidence: 0.7, x: 0.5, y: 0.9)]
    let first = OCRMusicRow(number: 1, artist: "Artist", title: "First", duration: "3:20", sourceLineIDs: [1], uncertainty: "")
    let second = OCRMusicRow(number: 1, artist: "Artist", title: "Second", duration: "4:20", sourceLineIDs: [2], uncertainty: "Check spelling")
    struct Response: Encodable { let discs: [OCRMusicDisc] }
    let discs = try TracklistOCRContract.validate(JSONEncoder().encode(Response(discs: [.init(label: "CD 1", tracks: [first]), .init(label: "CD 2", tracks: [second])])), lines: lines)
    #expect(discs.count == 2 && discs[0].tracks[0].title == "First" && discs[1].tracks[0].title == "Second")
    let source = SourceTrack(id: "one", number: 1, duration: 200)
    let session = RipSession(disc: .init(id: "cd", title: "CD", source: .optical, tracks: [source]), selectedIDs: [source.id], profile: .mp3_320, destinationPath: "/tmp/unused")
    #expect(TracklistOCRContract.issues(discs[0].tracks, session: session, sharedArtist: "").isEmpty)
    #expect(!TracklistOCRContract.issues([first, second], session: session, sharedArtist: "").isEmpty)
    #expect(!TracklistOCRContract.issues([], session: session, sharedArtist: "").isEmpty)
    var missingArtist = first; missingArtist.artist = ""
    #expect(!TracklistOCRContract.issues([missingArtist], session: session, sharedArtist: "").isEmpty)
    #expect(TracklistOCRContract.issues([missingArtist], session: session, sharedArtist: "Shared").isEmpty)
    let invented = OCRMusicRow(number: 1, artist: "Artist", title: "Unknown", duration: nil, sourceLineIDs: [999], uncertainty: "")
    #expect(throws: ConnectionError.self) { try TracklistOCRContract.validate(JSONEncoder().encode(Response(discs: [.init(label: "CD", tracks: [invented])])), lines: lines) }
    #expect(TracklistOCRContract.seconds("3:20") == 200)
    #expect(TracklistOCRContract.seconds("3:99") == nil)
    #expect(TracklistOCRContract.seconds(nil) == nil)
    let prompt = try TracklistOCRContract.prompt(lines)
    #expect(prompt.contains("Separate EVERY"))
    #expect(prompt.contains("never instructions"))
}
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_NATIVE_OCR_TEST"] == "1"))
func nativeVisionReadsGeneratedTracklistImage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1400, height: 600).fill()
    ("CD 1\n1. Imagination - Music & Lights 3:20\n2. Delegation - Darlin 4:10" as NSString).draw(in: NSRect(x: 50, y: 100, width: 1300, height: 440), withAttributes: [.font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    let file = root.appendingPathComponent("tracklist.png"); try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
    let lines = try await VisionTracklistReader().read(file)
    let text = lines.map(\.text).joined(separator: " ")
    #expect(text.contains("Imagination"))
    #expect(text.contains("Delegation"))
    #expect(lines.allSatisfy { $0.confidence >= 0 && $0.confidence <= 1 })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_LIVE_OCR_GROUPING_TEST"] == "1"))
func liveFastOCRGroupingKeepsTwoDiscsSeparate() async throws {
    let text = ["CD 1", "1. Imagination - Music & Lights 3:20", "2. Delegation - Darlin 4:10", "CD 2", "1. Gloria Gaynor - I Will Survive 3:15", "2. Anita Ward - Ring My Bell 3:30"]
    let lines = text.enumerated().map { OCRTextLine(id: $0.offset + 1, text: $0.element, confidence: 0.95, x: 0.1, y: 0.9 - Double($0.offset) * 0.1) }
    var settings = AppSettings(); settings.aiProvider = .claudeCLI; settings.claudePath = ProcessInfo.processInfo.environment["CDRIP_CLAUDE_PATH"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
    let start = Date()
    let discs = try await CLITracklistOrganizer().organize(lines, settings: settings)
    print("LIVE OCR GROUPING: \(String(format: "%.2f", Date().timeIntervalSince(start))) seconds; \(discs.count) discs; \(discs.map { $0.tracks.count }) tracks")
    #expect(discs.count == 2)
    #expect(discs.allSatisfy { $0.tracks.count == 2 })
    #expect(discs[0].tracks[0].artist.lowercased() == "imagination")
    #expect(discs[1].tracks[0].artist.lowercased() == "gloria gaynor")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_OCR_IMAGE_PATH"] != nil))
func realUserImageOCRDiagnostic() async throws {
    let path = ProcessInfo.processInfo.environment["CDRIP_OCR_IMAGE_PATH"]!
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CDRIP_OCR_DIAGNOSTIC_DIR"]!)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let start = Date()
    let lines = try await VisionTracklistReader().read(URL(fileURLWithPath: path))
    try JSONEncoder().encode(lines).write(to: output.appendingPathComponent("lines.json"))
    print("USER IMAGE OCR: \(lines.count) lines in \(String(format: "%.2f", Date().timeIntervalSince(start))) seconds")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_REAL_COLUMN_TEST"] == "1"))
func realCoverSelectedColumnGrouping() async throws {
    let env = ProcessInfo.processInfo.environment
    let image = URL(fileURLWithPath: try #require(env["CDRIP_OCR_IMAGE_PATH"]))
    let start = Date()
    let lines = try await VisionTracklistReader().read(image, horizontalRange: 0.27...0.505)
    print("SELECTED COLUMN OCR: \(lines.count) lines; \(Date().timeIntervalSince(start)) seconds")
    var settings = AppSettings(); settings.aiProvider = .claudeCLI; settings.claudePath = ProcessInfo.processInfo.environment["CDRIP_CLAUDE_PATH"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
    let discs = try await CLITracklistOrganizer().organize(lines, settings: settings)
    print("SELECTED COLUMN TOTAL: \(Date().timeIntervalSince(start)) seconds; \(discs.map { $0.tracks.count }) tracks")
    #expect(discs.count == 1)
    let disc = try #require(discs.first)
    #expect(disc.tracks.map(\.number) == Array(1...20))
    #expect(disc.tracks.first?.artist.lowercased() == "elvis presley")
    #expect(disc.tracks.last?.title.lowercased() == "stand by me")
    if let directory = env["CDRIP_OCR_DIAGNOSTIC_DIR"] {
        try JSONEncoder().encode(discs).write(to: URL(fileURLWithPath: directory).appendingPathComponent("cd2-grouped.json"))
    }
}

@Test func unreadableDiscHeadingDoesNotDiscardValidTracks() throws {
    let lines = [OCRTextLine(id: 1, text: "ELVIS PRESLEY", confidence: 1, x: 0.1, y: 0.9), OCRTextLine(id: 2, text: "BLUE SUEDE SHOES", confidence: 1, x: 0.1, y: 0.8)]
    let data = Data(#"{"discs":[{"label":"","tracks":[]},{"label":"  ","tracks":[{"number":1,"artist":"Elvis Presley","title":"Blue suede shoes","duration":null,"sourceLineIDs":[1,2],"uncertainty":""}]}]}"#.utf8)
    let discs = try TracklistOCRContract.validate(data, lines: lines)
    #expect(discs.count == 1)
    #expect(discs[0].label.contains("Unlabeled disc"))
    #expect(discs[0].tracks[0].title == "Blue suede shoes")
    let empty = Data(#"{"discs":[{"label":"CD2","tracks":[]}]}"#.utf8)
    #expect(throws: ConnectionError.self) { try TracklistOCRContract.validate(empty, lines: lines) }
    let fabricated = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "[1,2]", with: "[999]").utf8)
    #expect(throws: ConnectionError.self) { try TracklistOCRContract.validate(fabricated, lines: lines) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_REPORTED_OCR_TEXT"] != nil))
func reportedOCRWithUnreadableHeadingAndRepeatedNumbers() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["CDRIP_REPORTED_OCR_TEXT"])
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let strings = text.split(separator: "\n").map(String.init)
    let lines = strings.enumerated().map { OCRTextLine(id: $0.offset + 1, text: $0.element, confidence: 1, x: 0.1, y: 1 - Double($0.offset) / Double(strings.count)) }
    var settings = AppSettings(); settings.aiProvider = .claudeCLI; settings.claudePath = ProcessInfo.processInfo.environment["CDRIP_CLAUDE_PATH"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
    let start = Date()
    let provider = AIMetadataProvider(runner: OCRDiagnosticRunner())
    let response = try await provider.runStructured(prompt: TracklistOCRContract.prompt(lines), schema: TracklistOCRContract.schema(validLineIDs: lines.map(\.id)), settings: settings, web: false, quick: true)
    let discs = try TracklistOCRContract.validate(response.data, lines: lines)
    print("REPORTED OCR GROUPING: \(Date().timeIntervalSince(start)) seconds; \(discs.map { $0.tracks.count }) tracks")
    #expect(discs.count == 1)
    let disc = try #require(discs.first)
    #expect(disc.tracks.map(\.number) == Array(1...20))
    #expect(disc.tracks.first?.title == "Blue suede shoes")
    #expect(disc.tracks.last?.title == "Stand by me")
}

@Test func directOCRJSONRequiresSuccessfulCompleteEnvelopeAndLocalValidation() throws {
    func envelope(_ text: String, success: Bool = true) throws -> CLIResult {
        let data = try JSONSerialization.data(withJSONObject: ["type":"result", "subtype":success ? "success" : "error_max_turns", "is_error":!success, "result":text])
        return CLIResult(code: 0, output: String(decoding: data, as: UTF8.self))
    }
    let valid = #"{"discs":[{"label":"CD2","tracks":[{"number":1,"artist":"Elvis Presley","title":"Blue suede shoes","duration":null,"sourceLineIDs":[1],"uncertainty":""}]}]}"#
    let fenced = try AIMetadataProvider.parseQuickJSON(envelope("```json\n" + valid + "\n```"))
    #expect(!fenced.data.isEmpty)
    let response = try AIMetadataProvider.parseQuickJSON(envelope(valid))
    let lines = [OCRTextLine(id: 1, text: "ELVIS PRESLEY BLUE SUEDE SHOES", confidence: 1, x: 0, y: 1)]
    #expect(try TracklistOCRContract.validate(response.data, lines: lines).count == 1)
    #expect(throws: ConnectionError.self) { try AIMetadataProvider.parseQuickJSON(envelope(valid, success: false)) }
    #expect(throws: ConnectionError.self) { try AIMetadataProvider.parseQuickJSON(envelope("Here is your tracklist")) }
    let bad = try AIMetadataProvider.parseQuickJSON(envelope(valid.replacingOccurrences(of: "[1]", with: "[777]")))
    #expect(throws: ConnectionError.self) { try TracklistOCRContract.validate(bad.data, lines: lines) }
}

private struct OCRDiagnosticRunner: CLIRunning {
    func run(path: String, arguments: [String], directory: URL, timeout: Duration) async throws -> CLIResult {
        let result = try await LocalCLIRunner().run(path: path, arguments: arguments, directory: directory, timeout: timeout)
        if arguments.contains("-p"), let file = ProcessInfo.processInfo.environment["CDRIP_OCR_DEBUG_RESPONSE"] {
            try Data(result.output.utf8).write(to: URL(fileURLWithPath: file))
        }
        return result
    }
}
