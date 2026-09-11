import Foundation
import Testing
@testable import CDRipCore

@Test func legacySettingsMigrateToCLIAndRoundtripLocalProviders() throws {
    let old = Data(#"{"destinationPath":"/Music","profile":"mp3_256","azureEndpoint":"","azureDeployment":"custom"}"#.utf8)
    var settings = try JSONDecoder().decode(AppSettings.self, from: old)
    #expect(settings.aiProvider == .codexCLI)
    #expect(settings.azureDeployment == "custom")
    for provider in [AIProvider.codexCLI, .claudeCLI] {
        settings.aiProvider = provider
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
}
@Test func azureCredentialsOnlyGoToCanonicalAzureHosts() throws {
    #expect(try AzureAddress.base("https://radio.openai.azure.com/openai/v1/").absoluteString == "https://radio.openai.azure.com/openai/v1/")
    for invalid in ["http://radio.openai.azure.com", "https://radio.openai.azure.com.evil.org", "https://evil.org", "https://key@radio.openai.azure.com", "https://radio.openai.azure.com?key=x", "https://radio.openai.azure.com/other", "https://radio.openai.azure.com:444", "https://.openai.azure.com"] {
        #expect(throws: ConnectionError.self) { try AzureAddress.base(invalid) }
    }
}
@Test func cliEnvironmentCannotInheritPaidAPIOrProviderOverrides() {
    let env = LocalCLIRunner.environment(["HOME":"/Users/test", "ANTHROPIC_API_KEY":"secret", "OPENAI_API_KEY":"secret", "ANTHROPIC_BASE_URL":"https://other", "CODEX_HOME":"/custom", "CLAUDE_CONFIG_DIR":"/custom", "PATH":"/untrusted", "CLAUDECODE":"1"])
    #expect(env["HOME"] == "/Users/test")
    #expect(env["ANTHROPIC_API_KEY"] == nil)
    #expect(env["OPENAI_API_KEY"] == nil)
    #expect(env["CODEX_HOME"] == nil)
    #expect(!env.values.contains("secret"))
}
private actor ScriptedCLI: CLIRunning {
    var calls: [[String]] = []
    var responses: [CLIResult]
    init(_ responses: [CLIResult]) { self.responses = responses }
    func run(path: String, arguments: [String], directory: URL, timeout: Duration) async throws -> CLIResult {
        calls.append(arguments)
        return responses.removeFirst()
    }
}
@Test func apiLoginBlocksInferenceAndSuccessfulReplyNeedsCompletion() async throws {
    let runner = ScriptedCLI([.init(code: 0, output: "Logged in using an API key")])
    var settings = AppSettings(); settings.aiProvider = .codexCLI
    await #expect(throws: ConnectionError.self) { try await AIConnectionTester(runner: runner).test(settings: settings) }
    #expect(await runner.calls.count == 1)
    let message = #"{"type":"item.completed","item":{"type":"agent_message","text":"CD_RIP_OK"}}"#
    #expect(!AIConnectionTester.validReply(.init(code: 0, output: message), provider: .codexCLI))
    let good = message + "\n" + #"{"type":"turn.completed"}"#
    #expect(AIConnectionTester.validReply(.init(code: 0, output: good), provider: .codexCLI))
    #expect(!AIConnectionTester.validReply(.init(code: 1, output: good), provider: .codexCLI))
    let success = ScriptedCLI([.init(code: 0, output: "Logged in using ChatGPT\n"), .init(code: 0, output: good)])
    let reply = try await AIConnectionTester(runner: success).test(settings: settings)
    #expect(reply.contains("Connected"))
    #expect(await success.calls[1].contains("forced_login_method=\"chatgpt\""))
}
@Test func claudeSubscriptionMustBeExplicitAndErrorsNeverPass() {
    let good = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
    #expect(AIConnectionTester.subscriptionAuthenticated(.init(code: 0, output: good), provider: .claudeCLI))
    #expect(!AIConnectionTester.subscriptionAuthenticated(.init(code: 0, output: good.replacingOccurrences(of: "claude.ai", with: "api_key")), provider: .claudeCLI))
    #expect(!AIConnectionTester.validReply(.init(code: 0, output: #"{"type":"result","subtype":"error","is_error":true,"result":"CD_RIP_OK"}"#), provider: .claudeCLI))
}
@Test func localRunnerTimesOutAndHonorsCancellation() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    await #expect(throws: ConnectionError.self) {
        try await LocalCLIRunner().run(path: "/bin/sleep", arguments: ["5"], directory: folder, timeout: .milliseconds(100))
    }
    let task = Task { try await LocalCLIRunner().run(path: "/bin/sleep", arguments: ["5"], directory: folder, timeout: .seconds(10)) }
    try await Task.sleep(for: .milliseconds(100)); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_LIVE_CONNECTION_TEST"] == "1"))
func explicitLiveSubscriptionDiagnostics() async {
    for provider in [AIProvider.codexCLI, .claudeCLI] {
        var settings = AppSettings(); settings.aiProvider = provider
        do { print("LIVE DIAGNOSTIC: " + (try await AIConnectionTester().test(settings: settings))) }
        catch { print("LIVE DIAGNOSTIC \(provider.title): \(error.localizedDescription)") }
    }
}
