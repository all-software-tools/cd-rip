import Foundation
import Testing
@testable import CDRipCore

private func sftpSettings() -> SFTPSettings {
    var settings = SFTPSettings()
    settings.host = "example.test"; settings.username = "music"
    settings.trustedHost = settings.endpoint
    settings.trustedKey = "ssh-ed25519 " + Data([0,0,0,11] + Array("ssh-ed25519".utf8) + [0,0,0,32] + Array(repeating: UInt8(1), count: 32)).base64EncodedString()
    return settings
}

@Test func sftpSettingsValidateTrustAndRejectBatchInjection() throws {
    var settings = sftpSettings()
    try settings.validate()
    settings.host = "another.test"
    #expect(throws: ConnectionError.self) { try settings.validate() }
    settings = sftpSettings(); settings.remoteDirectory = "/music\n!touch /tmp/injected"
    #expect(throws: ConnectionError.self) { try settings.validate() }
    settings = sftpSettings(); settings.username = "-oProxyCommand=evil"
    #expect(throws: ConnectionError.self) { try settings.validate() }
    #expect(SFTPService.fingerprint("ssh-ed25519 invalid") == nil)
    #expect(SFTPService.fingerprint(sftpSettings().trustedKey)?.hasPrefix("SHA256:") == true)
    let folder = URL(fileURLWithPath: "/tmp/sftp test")
    let args = SFTPService.arguments(sftpSettings(), folder: folder, batch: folder.appendingPathComponent("batch"))
    #expect(args.contains("StrictHostKeyChecking=yes"))
    #expect(args.contains("BatchMode=no"))
    #expect(args.contains("PreferredAuthentications=password"))
    #expect(!args.contains(sftpSettings().credentialID))
    #expect(throws: ConnectionError.self) { try SFTPService.quote("abc\rquit") }
}

@Test func sftpGenericNamesAndSettingsPersistence() throws {
    for name in ["Track01.mp3", "Track 02 - abc.flac", "TRACK_003.mp3", "track-4.mp3"] {
        #expect(SFTPUploadFile(path: "/tmp/" + name, trackID: "1").hasGenericName)
    }
    #expect(!SFTPUploadFile(path: "/tmp/Artist - Track of my tears.mp3", trackID: "1").hasGenericName)
    var settings = AppSettings(); settings.sftp = sftpSettings()
    let encoded = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(AppSettings.self, from: encoded).sftp == settings.sftp)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "sftp")
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy)).sftp == SFTPSettings())
}

/// Real SFTP protocol and batch parser, with a local subprocess server; no SSH/network/authentication.
private struct LocalSFTPProtocolRunner: CLIRunning {
    func run(path: String, arguments: [String], directory: URL, timeout: Duration) async throws -> CLIResult {
        let b = try #require(arguments.firstIndex(of: "-b"))
        return try await LocalCLIRunner().run(path: "/usr/bin/sftp", arguments: ["-D", "/usr/libexec/sftp-server", "-b", arguments[b + 1]], directory: directory, timeout: timeout)
    }
}
private actor SFTPProgress {
    var completed = 0
    func update(_ count: Int) { completed = count }
}

@Test func sftpRealProtocolPublishesExactTaggedBytesAndHandlesSpecialFilenames() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appendingPathComponent("local"), remote = root.appendingPathComponent("remote [music]")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    let names = ["Artist - A [live] \\\"song\\\" $`*.mp3", "Artist - Café & song.flac"]
    var files: [SFTPUploadFile] = []
    for (index, name) in names.enumerated() {
        let path = local.appendingPathComponent(name)
        try Data(("ID3 metadata cover and audio fixture " + String(index)).utf8).write(to: path)
        files.append(.init(path: path.path, trackID: String(index)))
    }
    var settings = sftpSettings(); settings.remoteDirectory = remote.path
    let service = SFTPService(runner: LocalSFTPProtocolRunner()), progress = SFTPProgress()
    try await service.test(settings)
    try await service.upload(files, settings: settings, directoryName: "CDRip-test") { count, _, _ in await progress.update(count) }
    #expect(await progress.completed == 2)
    for file in files {
        let destination = remote.appendingPathComponent("CDRip-test/\(file.format)/\(file.filename)")
        #expect(try Data(contentsOf: destination) == Data(contentsOf: URL(fileURLWithPath: file.path)))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
    do {
        try await service.upload(files, settings: settings, directoryName: "CDRip-test") { _, _, _ in }
        Issue.record("Existing upload directory should not be overwritten")
    } catch is ConnectionError {}
    let leftover = try FileManager.default.subpathsOfDirectory(atPath: remote.path).filter { $0.hasSuffix(".part") }
    #expect(leftover.isEmpty)
}

@Test func sftpRejectsInvalidInputsBeforeAnyServerMutation() async throws {
    actor NeverRunner: CLIRunning {
        var calls = 0
        func run(path: String, arguments: [String], directory: URL, timeout: Duration) async throws -> CLIResult { calls += 1; return .init(code: 0, output: "") }
    }
    let runner = NeverRunner(), service = SFTPService(runner: runner)
    do {
        try await service.upload([.init(path: "/nonexistent.mp3", trackID: "1")], settings: sftpSettings(), directoryName: "CDRip-test") { _, _, _ in }
        Issue.record("Missing file accepted")
    } catch {}
    #expect(await runner.calls == 0)
}

@Test func sftpFailureStopsBeforeNextFileAndCancellationPropagates() async throws {
    actor FailingRunner: CLIRunning {
        var calls = 0
        let cancel: Bool
        init(cancel: Bool) { self.cancel = cancel }
        func run(path: String, arguments: [String], directory: URL, timeout: Duration) async throws -> CLIResult {
            calls += 1
            if calls == 1 { return .init(code: 0, output: "") }
            if cancel { throw CancellationError() }
            return .init(code: 1, output: "Connection lost")
        }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-failure-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var files: [SFTPUploadFile] = []
    for name in ["a.mp3", "b.mp3"] {
        let url = root.appendingPathComponent(name); try Data([1,2,3]).write(to: url)
        files.append(.init(path: url.path, trackID: name))
    }
    for cancel in [false, true] {
        let runner = FailingRunner(cancel: cancel)
        do {
            try await SFTPService(runner: runner).upload(files, settings: sftpSettings(), directoryName: "CDRip-failure") { _, _, _ in }
            Issue.record("Failure was swallowed")
        } catch is CancellationError { #expect(cancel) }
        catch is ConnectionError { #expect(!cancel) }
        #expect(await runner.calls == 2)
        for file in files { #expect(try Data(contentsOf: URL(fileURLWithPath: file.path)) == Data([1,2,3])) }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_LOCAL_SSH_FIXTURE"] != nil))
func sftpLocalSSHAuthenticatesPasswordAndKeyAndRejectsChangedHostKey() async throws {
    struct AskpassFixtureRunner: CLIRunning {
        let password: String
        func run(path: String, arguments: [String], directory: URL, timeout: Duration) async throws -> CLIResult {
            let helper = directory.appendingPathComponent("fixture-askpass")
            // Fixed test values only. Production uses Keychain, which this fixture does not touch.
            let value = password == "correct" ? "local-test-only" : "wrong-test-password"
            try Data("#!/bin/sh\nprintf '%s\\n' '\(value)'\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            return try await LocalCLIRunner(environmentOverrides: ["SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "cdrip:0"]).run(path: path, arguments: arguments, directory: directory, timeout: timeout)
        }
    }
    let fixture = try #require(ProcessInfo.processInfo.environment["CDRIP_LOCAL_SSH_FIXTURE"])
    let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
    let values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var settings = SFTPSettings()
    settings.host = "127.0.0.1"; settings.username = "cdriptest"; settings.port = try #require(values["port"] as? Int)
    settings.trustedHost = settings.endpoint; settings.trustedKey = try #require(values["key"] as? String)
    let service = SFTPService(runner: AskpassFixtureRunner(password: "correct"))
    #expect(try await service.fetchHostKey(settings) == settings.trustedKey)
    try await service.test(settings)
    do { try await SFTPService(runner: AskpassFixtureRunner(password: "wrong")).test(settings); Issue.record("Wrong password accepted") } catch is ConnectionError {}
    var changed = settings; changed.trustedKey = sftpSettings().trustedKey
    do { try await service.test(changed); Issue.record("Changed host key accepted") } catch is ConnectionError {}
    let local = URL(fileURLWithPath: fixture).deletingLastPathComponent().appendingPathComponent("tagged.mp3")
    try Data("local SSH transfer fixture".utf8).write(to: local)
    let directoryName = "CDRip-" + UUID().uuidString
    try await service.upload([.init(path: local.path, trackID: "1")], settings: settings, directoryName: directoryName) { _, _, _ in }
    let remote = URL(fileURLWithPath: try #require(values["remote"] as? String)).appendingPathComponent("\(directoryName)/MP3/tagged.mp3")
    #expect(try Data(contentsOf: local) == Data(contentsOf: remote))
    settings.usePassword = false; settings.identityFile = try #require(values["identity"] as? String)
    try await SFTPService().test(settings)
}
