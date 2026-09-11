import Foundation

/// One versioned snapshot, serialized by the actor and atomically replaced on the same volume.
/// Refuses writes after failed load so corrupt/future files cannot silently be reset.
public actor JSONWorkspaceStore: WorkspaceStoring {
    public let fileURL: URL
    private var writable = false
    private var loadedData: Data?
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> WorkspaceState {
        writable = false
        loadedData = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            writable = true
            return WorkspaceState()
        }
        let data = try Data(contentsOf: fileURL)
        struct Header: Decodable { let schemaVersion: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw CDRipError.corruptStore }
        guard header.schemaVersion == WorkspaceState.currentVersion else { throw CDRipError.unsupportedSchema(header.schemaVersion) }
        guard var state = try? JSONDecoder().decode(WorkspaceState.self, from: data) else { throw CDRipError.corruptStore }
        loadedData = data
        state.recoverInterruptedWork()
        writable = true
        return state
    }

    public func save(_ state: WorkspaceState) throws {
        guard writable else { throw CDRipError.corruptStore }
        guard state.schemaVersion == WorkspaceState.currentVersion else { throw CDRipError.unsupportedSchema(state.schemaVersion) }
        let lease = try WorkspaceLease(fileURL: fileURL, owner: false)
        defer { withExtendedLifetime(lease) {} }
        let current = FileManager.default.fileExists(atPath: fileURL.path) ? try Data(contentsOf: fileURL) : nil
        guard current == loadedData else {
            writable = false
            throw ConnectionError("The workspace changed in another instance. Saving is blocked to preserve its changes. Reopen the workspace.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
        loadedData = data
    }
}
