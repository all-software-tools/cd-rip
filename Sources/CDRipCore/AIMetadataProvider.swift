import Foundation

/// Text-only metadata requests. Subscriptions remain subscriptions; no CLI API-key fallback.
public struct AIMetadataProvider: AIMetadataGenerating {
    private let runner: any CLIRunning
    public init(runner: any CLIRunning = LocalCLIRunner()) { self.runner = runner }
    public func generate(input: AIMetadataInput, settings: AppSettings, azureKey: String) async throws -> AIStructuredResponse {
        let prompt = try AIMetadataContract.prompt(input)
        guard settings.metadataModel.count <= 200 else { throw ConnectionError("The model name is too long.") }
        if settings.aiProvider == .azureFoundry { return try await azure(prompt: prompt, settings: settings, key: azureKey) }
        let response = try await runStructured(prompt: prompt, schema: AIMetadataContract.schema, settings: settings, web: false)
        _ = try AIMetadataContract.validate(response.data, input: input)
        return response
    }
    func runStructured(prompt: String, schema schemaObject: [String: Any], settings: AppSettings, web: Bool, quick: Bool = false) async throws -> AIStructuredResponse {
        guard settings.metadataModel.count <= 200 else { throw ConnectionError("The model name is too long.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CDRip-AI-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let codex = settings.aiProvider == .codexCLI
        let path = codex ? settings.codexPath : settings.claudePath
        let auth: CLIResult
        do { auth = try await runner.run(path: path, arguments: codex ? ["login", "status"] : ["--safe-mode", "--setting-sources", "", "auth", "status", "--json"], directory: directory, timeout: .seconds(20)) }
        catch { if error is CancellationError { throw error }; throw ConnectionError("CLI login check failed: " + error.localizedDescription) }
        guard AIConnectionTester.subscriptionAuthenticated(auth, provider: settings.aiProvider) else {
            throw ConnectionError("Subscription login could not be confirmed. Sign in through the selected CLI and test the connection. No metadata request was sent.")
        }
        let schema = try JSONSerialization.data(withJSONObject: schemaObject, options: [.sortedKeys])
        var args: [String]
        let final = directory.appendingPathComponent("response.json")
        if codex {
            let file = directory.appendingPathComponent("schema.json")
            try schema.write(to: file, options: .withoutOverwriting)
            args = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "--json",
                    "-c", "forced_login_method=\"chatgpt\"", "-c", "model_provider=\"openai\"", "-c", web ? "web_search=\"live\"" : "web_search=\"disabled\"",
                    "-c", "features.shell_tool=false", "-c", "features.apply_patch=false", "--output-schema", file.path, "--output-last-message", final.path]
        } else {
            args = ["--safe-mode", "--setting-sources", "", "--strict-mcp-config", "--tools", web ? "WebSearch,WebFetch" : "", "--no-chrome", "--disable-slash-commands",
                    "--no-session-persistence", "--permission-mode", "dontAsk", "--output-format", web ? "stream-json" : "json", "--max-turns", web ? "20" : "3",
                    "--json-schema", String(decoding: schema, as: UTF8.self)]
        }
        if web && !codex { args += ["--verbose", "--allowedTools", "WebSearch,WebFetch", "--effort", "medium"] }
        if web && codex { args += ["-c", "model_reasoning_effort=\"medium\""] }
        if quick {
            if codex { args += ["-c", "model_reasoning_effort=\"low\""] }
            else { args += ["--effort", "low", "--settings", #"{"alwaysThinkingEnabled":false,"env":{"MAX_THINKING_TOKENS":"0"}}"#] }
        }
        if !settings.metadataModel.isEmpty { args += ["--model", settings.metadataModel] }
        else if quick && !codex { args += ["--model", "haiku"] }
        // OCR requests direct JSON, with strict local contract validation.
        // The OCR contract validates the returned object locally before it reaches drafts.
        if quick && !codex, let index = args.firstIndex(of: "--json-schema") { args.removeSubrange(index...(index + 1)) }
        if !codex { args.append("-p") }
        args.append(quick && !codex ? prompt + "\nReply with a single JSON object, no prose or Markdown, matching this schema: " + String(decoding: schema, as: UTF8.self) : prompt)
        let result: CLIResult
        do { result = try await runner.run(path: path, arguments: args, directory: directory, timeout: .seconds(web ? 420 : 180)) }
        catch {
            if error is CancellationError { throw error }
            if quick, error.localizedDescription.localizedCaseInsensitiveContains("timed out") {
                throw ConnectionError("AI grouping timed out. The recognized text is retained; retry grouping without reloading the image.")
            }
            throw ConnectionError("CLI response failed: " + error.localizedDescription)
        }
        try Task.checkCancellation()
        if quick && !codex { return try Self.parseQuickJSON(result) }
        return try web ? Self.parseWeb(result, provider: settings.aiProvider) : Self.parse(result, provider: settings.aiProvider)
    }
    static func parseQuickJSON(_ result: CLIResult) throws -> AIStructuredResponse {
        guard result.code == 0,
              let envelope = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              envelope["type"] as? String == "result", envelope["subtype"] as? String == "success", envelope["is_error"] as? Bool == false,
              let text = envelope["result"] as? String else {
            throw ConnectionError("Claude did not return a complete JSON tracklist. Retry grouping the recognized text.")
        }
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), json.hasSuffix("```"), let firstNewline = json.firstIndex(of: "\n") {
            let header = json[..<firstNewline].lowercased()
            if header == "```json" || header == "```" {
                json = String(json[json.index(after: firstNewline)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ConnectionError("Claude returned text instead of a JSON tracklist. Retry grouping the recognized text.")
        }
        let usage = envelope["usage"] as? [String: Any]
        return .init(data: try JSONSerialization.data(withJSONObject: object), inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int)
    }
    static func parseWeb(_ result: CLIResult, provider: AIProvider) throws -> AIStructuredResponse {
        let events = result.output.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let usedWeb: Bool
        if provider == .codexCLI {
            usedWeb = events.contains { event in
                guard let item = event["item"] as? [String: Any] else { return false }
                return event["type"] as? String == "item.completed" && item["type"] as? String == "web_search"
            }
        } else {
            usedWeb = events.contains { event in
                guard let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return false }
                return content.contains { $0["type"] as? String == "tool_use" && ["WebSearch", "WebFetch"].contains($0["name"] as? String ?? "") }
            }
        }
        guard usedWeb else { throw ConnectionError("The CLI did not use a web search/fetch tool. No web research was accepted; check model/tool access and retry.") }
        if provider == .codexCLI { return try parse(result, provider: provider) }
        guard let final = events.last(where: { $0["type"] as? String == "result" }) else { throw ConnectionError("Claude web research did not finish. Retry the track.") }
        return try parse(.init(code: result.code, output: String(decoding: JSONSerialization.data(withJSONObject: final), as: UTF8.self)), provider: provider)
    }
    static func parse(_ result: CLIResult, provider: AIProvider) throws -> AIStructuredResponse {
        guard result.code == 0 else { throw ConnectionError("The AI request failed. Check subscription/model access and usage limits. No changes were applied.") }
        if provider == .codexCLI {
            let events = result.output.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            guard let completed = events.last(where: { $0["type"] as? String == "turn.completed" }),
                  !events.contains(where: { ["error", "turn.failed"].contains($0["type"] as? String ?? "") }) else {
                throw ConnectionError("Codex did not finish the metadata response. Retry the track.")
            }
            let messages = events.compactMap { event -> String? in
                guard event["type"] as? String == "item.completed", let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message" else { return nil }
                return item["text"] as? String
            }
            guard let final = messages.last else { throw ConnectionError("Codex returned no structured metadata.") }
            let usage = completed["usage"] as? [String: Any]
            return .init(data: Data(final.utf8), inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int)
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              object["type"] as? String == "result", object["subtype"] as? String == "success", object["is_error"] as? Bool == false,
              let structured = object["structured_output"] as? [String: Any] else {
            throw ConnectionError("Claude returned an incomplete or refused structured response. No changes were applied.")
        }
        let usage = object["usage"] as? [String: Any]
        let inputTokens = (usage?["input_tokens"] as? Int).map {
            $0 + (usage?["cache_creation_input_tokens"] as? Int ?? 0) + (usage?["cache_read_input_tokens"] as? Int ?? 0)
        }
        return .init(data: try JSONSerialization.data(withJSONObject: structured), inputTokens: inputTokens, outputTokens: usage?["output_tokens"] as? Int)
    }
    private func azure(prompt: String, settings: AppSettings, key: String) async throws -> AIStructuredResponse {
        let base = try AzureAddress.base(settings.azureEndpoint)
        guard !key.isEmpty, !settings.azureDeployment.isEmpty else { throw ConnectionError("Configure the Azure deployment and save its key in Settings first.") }
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 150
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue(key, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": settings.azureDeployment,
            "messages": [["role": "user", "content": prompt]], "max_completion_tokens": 4096, "stream": false,
            "response_format": ["type": "json_schema", "json_schema": ["name": "cd_metadata_review", "strict": true, "schema": AIMetadataContract.schema]]])
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 160
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ConnectionError("Azure metadata request failed (HTTP \(status)). Check deployment access, structured-output support and quota. No changes were applied.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 128_000 else { throw ConnectionError("Azure returned too much metadata.") }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try Self.parseAzure(data)
    }
    static func parseAzure(_ data: Data) throws -> AIStructuredResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], choices.count == 1, let choice = choices.first,
              choice["finish_reason"] as? String == "stop", let message = choice["message"] as? [String: Any],
              message["refusal"] == nil || message["refusal"] is NSNull,
              let content = message["content"] as? String else {
            throw ConnectionError("Azure refused or truncated the metadata response. No proposal was applied.")
        }
        let usage = object["usage"] as? [String: Any]
        return .init(data: Data(content.utf8), inputTokens: usage?["prompt_tokens"] as? Int, outputTokens: usage?["completion_tokens"] as? Int)
    }
}
