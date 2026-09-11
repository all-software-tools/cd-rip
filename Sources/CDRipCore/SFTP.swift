import Foundation
import CryptoKit
import Security

public struct SFTPSettings: Codable, Equatable, Sendable {
    public var host = ""
    public var port = 22
    public var username = ""
    public var remoteDirectory = "/"
    public var usePassword = true
    public var identityFile = ""
    public var trustedHost = ""
    public var trustedKey = ""
    public init() {}
    public var endpoint: String { "[\(host.lowercased())]:\(port)" }
    public var credentialID: String { SHA256.hash(data: Data((endpoint + "/" + username).utf8)).map { String(format: "%02x", $0) }.joined() }
    public func validate(requireTrust: Bool = true) throws {
        guard !host.isEmpty, host.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9.:-]*$"#, options: .regularExpression) != nil,
              (1...65535).contains(port), !username.isEmpty,
              username.range(of: #"^[a-zA-Z0-9_][a-zA-Z0-9_.@-]*$"#, options: .regularExpression) != nil,
              remoteDirectory.hasPrefix("/") else { throw ConnectionError("Enter a valid SFTP host, port, username and absolute remote folder.") }
        _ = try SFTPService.quote(remoteDirectory)
        if requireTrust {
            guard trustedHost == endpoint, SFTPService.fingerprint(trustedKey) != nil else { throw ConnectionError("Fetch and confirm this server’s SSH fingerprint in Settings first.") }
        }
        if !usePassword, !identityFile.isEmpty {
            guard identityFile.hasPrefix("/"), !identityFile.contains("\n") else { throw ConnectionError("Choose an absolute SSH private-key path.") }
        }
    }
}

public enum SFTPPassword {
    static let service = "digital.mykey.cdrip.sftp"
    public static func save(_ password: String, settings: SFTPSettings) throws {
        try settings.validate(requireTrust: false)
        guard !password.isEmpty, !password.contains("\n"), !password.contains("\r") else { throw ConnectionError("Enter a nonempty single-line password.") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: settings.credentialID]
        let data = Data(password.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var create = query; create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(create as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConnectionError("Could not save the SFTP password in Keychain (\(status)).") }
    }
}

public struct SFTPUploadFile: Sendable, Identifiable {
    public let path: String
    public let trackID: String
    public var id: String { path }
    public var filename: String { URL(fileURLWithPath: path).lastPathComponent }
    public var format: String { URL(fileURLWithPath: path).pathExtension.uppercased() }
    public init(path: String, trackID: String) { self.path = path; self.trackID = trackID }
    public var hasGenericName: Bool {
        filename.range(of: #"(?i)^track[ _-]*0*\d+(?:[ ._-]|$)"#, options: .regularExpression) != nil
    }
}

/// System OpenSSH SFTP; no shell evaluation of server names, paths or batch commands.
public struct SFTPService: Sendable {
    private let runner: (any CLIRunning)?
    public init() { runner = nil }
    init(runner: any CLIRunning) { self.runner = runner }
    static func quote(_ path: String) throws -> String {
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ConnectionError("SFTP paths cannot contain control characters.") }
        // Quote the batch command argument; control characters cannot introduce another command.
        return "\"" + path.reduce(into: "") { result, char in
            if "\\\"".contains(char) { result.append("\\") }
            result.append(char)
        } + "\""
    }
    public static func fingerprint(_ key: String) -> String? {
        let parts = key.split(separator: " ")
        guard parts.count == 2, parts[0] == "ssh-ed25519", let data = Data(base64Encoded: String(parts[1])), data.count == 51,
              data.prefix(19) == Data([0,0,0,11] + Array("ssh-ed25519".utf8) + [0,0,0,32]) else { return nil }
        return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cdrip-sftp-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }
    public func fetchHostKey(_ settings: SFTPSettings) async throws -> String {
        try settings.validate(requireTrust: false)
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await (runner ?? LocalCLIRunner()).run(path: "/usr/bin/ssh-keyscan", arguments: ["-T", "10", "-p", String(settings.port), "-t", "ed25519", settings.host], directory: folder, timeout: .seconds(15))
        let keys = Set(result.output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3 else { return nil }
            let key = fields[1...2].joined(separator: " ")
            return Self.fingerprint(key) == nil ? nil : key
        })
        guard result.code == 0, keys.count == 1, let key = keys.first else { throw ConnectionError("Could not obtain a unique Ed25519 server key. Check the host, port and server support.") }
        return key
    }
    static func arguments(_ settings: SFTPSettings, folder: URL, batch: URL) -> [String] {
        var args = ["-F", "/dev/null", "-o", "BatchMode=\(settings.usePassword ? "no" : "yes")", "-o", "StrictHostKeyChecking=yes",
                    "-o", "UserKnownHostsFile=\(folder.appendingPathComponent("known_hosts").path)", "-o", "GlobalKnownHostsFile=/dev/null",
                    "-o", "HostKeyAlgorithms=ssh-ed25519", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                    "-o", "NumberOfPasswordPrompts=1", "-o", "KbdInteractiveAuthentication=no", "-o", "PreferredAuthentications=\(settings.usePassword ? "password" : "publickey")",
                    "-P", String(settings.port), "-b", batch.path]
        if !settings.usePassword, !settings.identityFile.isEmpty { args += ["-i", settings.identityFile, "-o", "IdentitiesOnly=yes"] }
        args += ["\(settings.username)@\(settings.host.contains(":") ? "[\(settings.host)]" : settings.host)"]
        return args
    }
    private func execute(_ commands: String, settings: SFTPSettings, timeout: Duration) async throws {
        try settings.validate()
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let batch = folder.appendingPathComponent("batch")
        try Data(commands.utf8).write(to: batch)
        // Both standard-port and nonstandard-port host spellings, pinned to the same explicit key.
        try Data("\(settings.host.lowercased()),\(settings.endpoint) \(settings.trustedKey)\n".utf8).write(to: folder.appendingPathComponent("known_hosts"))
        var environment: [String: String] = [:]
        if settings.usePassword {
            let helper = folder.appendingPathComponent("askpass")
            let script = "#!/bin/sh\nexec /usr/bin/security find-generic-password -s \(SFTPPassword.service) -a \(settings.credentialID) -w\n"
            try Data(script.utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            environment = ["SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "cdrip:0"]
        } else if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = socket }
        let result = try await (runner ?? LocalCLIRunner(environmentOverrides: environment)).run(path: "/usr/bin/sftp", arguments: Self.arguments(settings, folder: folder, batch: batch), directory: folder, timeout: timeout)
        guard result.code == 0 else { throw ConnectionError("SFTP failed. Check credentials, the trusted host key and remote-folder permissions. Completed uploads remain on the server; an interrupted file may remain as .part.\n" + String(result.output.suffix(1800))) }
    }
    public func test(_ settings: SFTPSettings) async throws {
        try await execute("cd \(Self.quote(settings.remoteDirectory))\npwd\nquit\n", settings: settings, timeout: .seconds(90))
    }
    public func upload(_ files: [SFTPUploadFile], settings: SFTPSettings, directoryName: String,
                       progress: @Sendable (Int, Int, String) async -> Void) async throws {
        guard !files.isEmpty, directoryName.range(of: #"^CDRip-[a-zA-Z0-9-]+$"#, options: .regularExpression) != nil else { throw ConnectionError("Invalid SFTP upload selection.") }
        var names = Set<String>()
        for file in files {
            let url = URL(fileURLWithPath: file.path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard file.path.hasPrefix("/"), ["MP3", "FLAC"].contains(file.format), values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0,
                  names.insert(file.format + "/" + file.filename.lowercased()).inserted else { throw ConnectionError("Upload needs distinct, regular, nonempty MP3/FLAC files.") }
            _ = try Self.quote(file.path)
        }
        let remote = settings.remoteDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = "/" + (remote.isEmpty ? "" : remote + "/") + directoryName
        let formats = Set(files.map(\.format)).sorted()
        var setup = "mkdir \(try Self.quote(base))\n"
        for format in formats { setup += "mkdir \(try Self.quote(base + "/" + format))\n" }
        try await execute(setup + "quit\n", settings: settings, timeout: .seconds(90))
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            await progress(index, files.count, file.filename)
            let final = base + "/" + file.format + "/" + file.filename
            let partial = base + "/" + file.format + "/.cdrip-" + UUID().uuidString + ".part"
            try await execute("put \(Self.quote(file.path)) \(Self.quote(partial))\nrename \(Self.quote(partial)) \(Self.quote(final))\nquit\n", settings: settings, timeout: .seconds(3600))
            await progress(index + 1, files.count, file.filename)
        }
    }
}
