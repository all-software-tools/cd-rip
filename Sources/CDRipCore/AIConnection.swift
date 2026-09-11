import Foundation
import Security
import Darwin

public enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case azureFoundry, codexCLI, claudeCLI
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .azureFoundry: "Azure Foundry"
        case .codexCLI: "Codex CLI"
        case .claudeCLI: "Claude Code CLI"
        }
    }
}

public protocol AIConnectionTesting: Sendable {
    func test(settings: AppSettings, azureKey: String) async throws -> String
}

/// Fixed diagnostic errors: never surface raw CLI output, credentials or HTTP response bodies.
public struct ConnectionError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum AzureAddress {
    public static func base(_ endpoint: String) throws -> URL {
        guard let c = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "https", let host = c.host?.lowercased(),
              [".openai.azure.com", ".services.ai.azure.com"].contains(where: { host.hasSuffix($0) && host.count > $0.count }),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port == nil || c.port == 443,
              ["", "/", "/openai/v1", "/openai/v1/"].contains(c.path),
              let url = URL(string: "https://\(host)/openai/v1/") else {
            throw ConnectionError("Use your Azure resource HTTPS endpoint (*.openai.azure.com or *.services.ai.azure.com), without credentials or query parameters.")
        }
        return url
    }
}

/// Credentials are scoped to the canonical Azure resource, never stored in workspace.json.
public enum AzureKeychain {
    private static func query(_ endpoint: String) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "digital.mykey.cdrip.azure",
         kSecAttrAccount as String: try AzureAddress.base(endpoint).host!]
    }
    public static func read(endpoint: String) throws -> String {
        var q = try query(endpoint)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let text = String(data: data, encoding: .utf8) else {
            throw ConnectionError("Could not read the Azure key from Keychain (\(status)).")
        }
        return text
    }
    public static func save(_ key: String, endpoint: String) throws {
        let q = try query(endpoint)
        let data = Data(key.utf8)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var create = q
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(create as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConnectionError("Could not save the Azure key to Keychain (\(status)).") }
    }
}

public struct CLIResult: Sendable {
    public var code: Int32
    public var output: String
}

public protocol CLIRunning: Sendable {
    func run(path: String, arguments: [String], directory: URL, timeout: Duration) async throws -> CLIResult
    func run(path: String, arguments: [String], directory: URL, timeout: Duration, logURL: URL) async throws -> CLIResult
}

public extension CLIRunning {
    func run(path: String, arguments: [String], directory: URL, timeout: Duration, logURL: URL) async throws -> CLIResult {
        let result = try await run(path: path, arguments: arguments, directory: directory, timeout: timeout)
        try Data(result.output.utf8).write(to: logURL, options: .atomic)
        return result
    }
}

public struct LocalCLIRunner: CLIRunning {
    private var environmentOverrides: [String: String] = [:]
    public init() {}
    init(environmentOverrides: [String: String]) { self.environmentOverrides = environmentOverrides }
    /// Allowlist avoids inheriting API keys, provider overrides and SDK session variables.
    static func environment(_ original: [String: String]) -> [String: String] {
        var result = original.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"].contains($0.key) }
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return result
    }
    public func run(path: String, arguments: [String], directory: URL, timeout: Duration) async throws -> CLIResult {
        try await execute(path: path, arguments: arguments, directory: directory, timeout: timeout, logURL: nil)
    }
    public func run(path: String, arguments: [String], directory: URL, timeout: Duration, logURL: URL) async throws -> CLIResult {
        try await execute(path: path, arguments: arguments, directory: directory, timeout: timeout, logURL: logURL)
    }
    private func execute(path: String, arguments: [String], directory: URL, timeout: Duration, logURL: URL?) async throws -> CLIResult {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw ConnectionError("CLI not found. Set the full executable path in Settings.")
        }
        let output = directory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer {
            if let logURL { try? FileManager.default.copyItem(at: output, to: logURL) }
            try? FileManager.default.removeItem(at: output)
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = Self.environment(ProcessInfo.processInfo.environment).merging(environmentOverrides) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try Task.checkCancellation()
        do { try process.run() } catch { throw ConnectionError("Could not start the CLI. Check its installation and permissions.") }
        let outputLimit = logURL == nil ? 1_048_576 : 67_108_864
        let deadline = ContinuousClock.now + timeout
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ConnectionError("The operation timed out. If macOS is asking for folder or removable-volume access, allow it, then retry the operation.") }
                let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < outputLimit else { throw ConnectionError("The CLI produced too much output. The operation was stopped.") }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if process.isRunning { process.terminate() }
            // A misbehaving CLI must not outlive a cancelled diagnostic indefinitely.
            for _ in 0..<10 where process.isRunning { await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        try Task.checkCancellation()
        let finalSize = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        guard finalSize < outputLimit else { throw ConnectionError("The CLI produced too much output. The operation was stopped.") }
        return CLIResult(code: process.terminationStatus, output: String(decoding: try Data(contentsOf: output), as: UTF8.self))
    }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct AIConnectionTester: AIConnectionTesting {
    private let runner: any CLIRunning
    public init(runner: any CLIRunning = LocalCLIRunner()) { self.runner = runner }
    static let prompt = "Connection test only. Do not use any tools or read files. Reply exactly: CD_RIP_OK"
    public func test(settings: AppSettings, azureKey: String = "") async throws -> String {
        if settings.aiProvider == .azureFoundry { return try await testAzure(settings, key: azureKey) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CDRip-connection-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let codex = settings.aiProvider == .codexCLI
        let path = codex ? settings.codexPath : settings.claudePath
        let authArgs = codex ? ["login", "status"] : ["--safe-mode", "--setting-sources", "", "auth", "status", "--json"]
        let auth = try await runner.run(path: path, arguments: authArgs, directory: folder, timeout: .seconds(20))
        guard Self.subscriptionAuthenticated(auth, provider: settings.aiProvider) else {
            throw ConnectionError(codex ? "ChatGPT authentication could not be confirmed. Run “codex login” and sign in with your ChatGPT account. No AI request was sent." : "Claude subscription authentication could not be confirmed. Run “claude auth login” and sign in with your subscription account. No AI request was sent.")
        }
        var args: [String]
        if codex {
            args = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "--json",
                    "-c", "forced_login_method=\"chatgpt\"", "-c", "model_provider=\"openai\"", "-c", "web_search=\"disabled\"",
                    "-c", "features.shell_tool=false", "-c", "features.apply_patch=false", Self.prompt]
        } else {
            args = ["--safe-mode", "--setting-sources", "", "--strict-mcp-config", "--tools", "", "--no-chrome",
                    "--disable-slash-commands", "--no-session-persistence", "--permission-mode", "dontAsk", "--output-format", "json", "-p", Self.prompt]
        }
        if !settings.metadataModel.isEmpty { args.insert(contentsOf: ["--model", settings.metadataModel], at: args.count - 1) }
        let response = try await runner.run(path: path, arguments: args, directory: folder, timeout: .seconds(60))
        guard Self.validReply(response, provider: settings.aiProvider) else {
            throw ConnectionError("The provider did not confirm the test. Check model access, subscription limits and your CLI connection. No API fallback is used.")
        }
        return "Connected · \(settings.aiProvider.title) · subscription authentication. The model responded to the test."
    }
    static func subscriptionAuthenticated(_ result: CLIResult, provider: AIProvider) -> Bool {
        guard result.code == 0 else { return false }
        if provider == .codexCLI { return result.output.split(separator: "\n").contains("Logged in using ChatGPT") }
        guard let data = result.output.data(using: .utf8), let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return d["loggedIn"] as? Bool == true && d["authMethod"] as? String == "claude.ai" && d["apiProvider"] as? String == "firstParty"
            && ["pro", "max", "team", "enterprise"].contains(d["subscriptionType"] as? String ?? "")
    }
    static func validReply(_ result: CLIResult, provider: AIProvider) -> Bool {
        guard result.code == 0 else { return false }
        if provider == .codexCLI {
            let events = result.output.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let completed = events.contains { $0["type"] as? String == "turn.completed" }
            let message = events.contains { event in
                guard event["type"] as? String == "item.completed", let item = event["item"] as? [String: Any] else { return false }
                return item["type"] as? String == "agent_message" && (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "CD_RIP_OK"
            }
            return completed && message && !events.contains { ["error", "turn.failed"].contains($0["type"] as? String ?? "") }
        }
        guard let d = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else { return false }
        return d["type"] as? String == "result" && d["subtype"] as? String == "success" && d["is_error"] as? Bool == false
            && (d["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "CD_RIP_OK"
    }
    private func testAzure(_ settings: AppSettings, key: String) async throws -> String {
        let base = try AzureAddress.base(settings.azureEndpoint)
        guard !settings.azureDeployment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConnectionError("Enter the Azure deployment name.") }
        guard !key.isEmpty else { throw ConnectionError("Enter the Azure key or save it in Keychain for this resource.") }
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": settings.azureDeployment,
            "messages": [["role": "user", "content": Self.prompt]], "max_completion_tokens": 256, "stream": false])
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 50
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw ConnectionError("Could not connect to Azure. Check your network and endpoint.") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let detail = switch code {
            case 401, 403: "Invalid key or access denied."
            case 404: "Resource or deployment not found."
            case 429: "Rate limit reached or quota exhausted."
            case 300..<400: "Redirect refused. Check the endpoint."
            default: "The request was not accepted (HTTP \(code))."
            }
            throw ConnectionError("Azure: " + detail)
        }
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = d["choices"] as? [[String: Any]], let first = choices.first,
              first["finish_reason"] as? String == "stop", let message = first["message"] as? [String: Any],
              (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "CD_RIP_OK" else {
            throw ConnectionError("Azure responded, but the test was not confirmed. Check the model and output limit.")
        }
        return "Connected · Azure Foundry · the deployment responded. This request is billed through Azure."
    }
}
