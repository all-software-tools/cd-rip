import Foundation
import Testing
@testable import CDRipCore

@Test func bundledAudioToolsTakePriorityAndDevelopmentPathsStillWork() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CD Rip tools \(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Resources")
    let bundled = resources.appendingPathComponent("Tools/ffmpeg")
    let local = root.appendingPathComponent("local/ffmpeg")
    for file in [bundled, local] {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    let prefixes = [local.deletingLastPathComponent().path]
    #expect(AudioToolPaths.resolve("ffmpeg", resources: resources, prefixes: prefixes) == bundled.path)
    try FileManager.default.removeItem(at: bundled)
    #expect(AudioToolPaths.resolve("ffmpeg", resources: resources, prefixes: prefixes) == local.path)
    #expect(AudioToolPaths.resolve("ffmpeg", resources: nil, prefixes: prefixes) == local.path)
}
