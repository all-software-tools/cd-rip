import Foundation

public enum OutputProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case mp3_320, mp3_256, mp3_192, mp3_v0, flac, mp3AndFlac
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .mp3_320: "MP3 · 320 kbps"
        case .mp3_256: "MP3 · 256 kbps"
        case .mp3_192: "MP3 · 192 kbps"
        case .mp3_v0: "MP3 · VBR V0"
        case .flac: "FLAC · lossless"
        case .mp3AndFlac: "MP3 320 + FLAC"
        }
    }
    public var detail: String {
        self == .flac ? "44.1 kHz · 16-bit · stereo" : "44.1 kHz · stereo · radio library profile"
    }
}

public enum SourceKind: String, Codable, Sendable { case optical, demonstration }

public struct SourceTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var number: Int
    public var duration: TimeInterval
    public init(id: String, number: Int, duration: TimeInterval) {
        self.id = id; self.number = number; self.duration = duration
    }
}

public struct DiscDescriptor: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var source: SourceKind
    public var tracks: [SourceTrack]
    public var optical: OpticalDiscInfo?
    /// Display old automatic labels in English without rewriting saved sessions.
    public var displayTitle: String {
        if source == .optical && title == "CD audio" { return "Audio CD" }
        if source == .demonstration && id == "demo-disc-v1" { return "Demo session" }
        return title
    }
    public init(id: String, title: String, source: SourceKind, tracks: [SourceTrack]) {
        self.id = id; self.title = title; self.source = source; self.tracks = tracks
    }
}

public enum WorkPhase: String, Codable, Sendable {
    case pending, reading, encoding, ripped, awaitingVerification, cancelled, failed
    public var label: String {
        switch self {
        case .pending: "Pending"
        case .reading: "Reading"
        case .encoding: "Encoding"
        case .ripped: "Completed"
        case .awaitingVerification: "Audio needs review"
        case .cancelled: "Cancelled"
        case .failed: "Error"
        }
    }
}

public enum IdentificationStatus: String, Codable, Sendable {
    case notChecked, supplied, match, needsReview, conflict, unrecognized, serviceError
    public var label: String {
        switch self {
        case .notChecked: "Not checked"
        case .supplied: "Manually entered"
        case .match: "Match"
        case .needsReview: "Needs review"
        case .conflict: "Conflict"
        case .unrecognized: "Unrecognized"
        case .serviceError: "Service error"
        }
    }
}

public struct TrackMetadata: Codable, Equatable, Sendable {
    public var artist = ""
    public var title = ""
    public var album = ""
    public var albumArtist = ""
    public var year = ""
    public var genre = ""
    public var discNumber = 1
    public var discTotal = 1
    public var coverPath: String?
    public init() {}
}

public struct MetadataEvidence: Codable, Equatable, Sendable {
    public var id: String
    public var provider: String
    public var recordingID: String?
    public var releaseID: String?
    public var retrievedAt: Date
    public var sourceURL: String?
    public var fields: [String]?
    public var mediumPosition: Int?
    public var discID: String?
    public var recordingDuration: Double?
    public init(id: String, provider: String, recordingID: String? = nil, releaseID: String? = nil) {
        self.id = id; self.provider = provider; self.recordingID = recordingID
        self.releaseID = releaseID; retrievedAt = Date()
    }
}

public struct SessionTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var number: Int
    public var duration: TimeInterval
    public var phase: WorkPhase = .pending
    public var progress: Double = 0
    public var identification: IdentificationStatus = .notChecked
    public var supplied = TrackMetadata()
    public var proposed = TrackMetadata()
    public var evidence: [MetadataEvidence] = []
    public var outputPaths: [String] = []
    public var error: String?
    public var integrity: RipIntegrity?
    public var tagRevisions: [TagRevision]?
    public var pendingFileTagSave: FileTagSavePlan?
    public var savedFileTags: TrackMetadata?
    public var savedFileHashes: [String: String]?
    public var fileTagError: String?
    public var aiReview: AIReviewRecord?
    public var aiError: String?
    public var aiErrorStage: String?
    public var aiRejectedResponse: String?
    public var coverImport: ImportedCover?
    public var aiReviewAppliedAt: Date?
    public init(source: SourceTrack) {
        id = source.id; number = source.number; duration = source.duration
    }
}

public struct RipOutputFolders: Codable, Equatable, Sendable {
    public var wavPath = ""
    public var mp3Path = ""
    public var flacPath = ""
    public var deleteWAVAfterConversion = false
    public init() {}
    public func base(for format: String, fallback: String) -> URL {
        // Legacy individual paths remain decodable, but the Extraction root is authoritative.
        return URL(fileURLWithPath: fallback).appendingPathComponent(format.uppercased(), isDirectory: true)
    }
}

public struct RipSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var disc: DiscDescriptor
    public let outputProfile: OutputProfile
    public let destinationPath: String
    public var settingsSnapshot: AppSettings?
    public var aiCallCount: Int?
    public var outputFolders: RipOutputFolders?
    public var tracklist = ""
    /// Optional for backward-compatible decoding of schema v1 snapshots made before this field.
    public var metadataReferenceURL: String?
    public var commonArtist: String?
    public var tracks: [SessionTrack]
    public init(disc: DiscDescriptor, selectedIDs: Set<String>, profile: OutputProfile, destinationPath: String) {
        id = UUID(); createdAt = Date(); updatedAt = createdAt; self.disc = disc
        outputProfile = profile; self.destinationPath = destinationPath
        tracks = disc.tracks.filter { selectedIDs.contains($0.id) }.map(SessionTrack.init)
    }
    public var progress: Double { tracks.isEmpty ? 0 : tracks.map(\.progress).reduce(0, +) / Double(tracks.count) }
    public var hasFinishedSimulation: Bool { !tracks.isEmpty && tracks.allSatisfy { $0.phase == .ripped } }
    public func effectiveArtist(for track: SessionTrack) -> String {
        let explicit = track.supplied.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return explicit.isEmpty ? (commonArtist ?? "") : explicit
    }
}

/// Non-sensitive preferences only. No API keys, tokens or credentials belong here.
public struct AppSettings: Codable, Equatable, Sendable {
    public var destinationPath = ""
    public var outputFolders = RipOutputFolders()
    public var completionSound = true
    public var codexModel = ""
    public var claudeModel = ""
    public var maxAICallsPerSession = 25
    public var metadataModel: String {
        switch aiProvider {
        case .azureFoundry: azureDeployment
        case .codexCLI: codexModel
        case .claudeCLI: claudeModel
        }
    }
    public var profile: OutputProfile = .mp3_320
    public var azureEndpoint = ""
    public var azureDeployment = "cd-rip-metadata"
    public var aiProvider: AIProvider = .codexCLI
    public var codexPath = "/opt/homebrew/bin/codex"
    public var claudePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
    enum CodingKeys: String, CodingKey {
        case codexModel, claudeModel, maxAICallsPerSession, outputFolders, completionSound, destinationPath, profile, azureEndpoint, azureDeployment, aiProvider, codexPath, claudePath
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputFolders = try c.decodeIfPresent(RipOutputFolders.self, forKey: .outputFolders) ?? RipOutputFolders()
        completionSound = try c.decodeIfPresent(Bool.self, forKey: .completionSound) ?? true
        codexModel = try c.decodeIfPresent(String.self, forKey: .codexModel) ?? ""
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? ""
        maxAICallsPerSession = try c.decodeIfPresent(Int.self, forKey: .maxAICallsPerSession) ?? 25
        destinationPath = try c.decode(String.self, forKey: .destinationPath)
        profile = try c.decode(OutputProfile.self, forKey: .profile)
        azureEndpoint = try c.decode(String.self, forKey: .azureEndpoint)
        azureDeployment = try c.decode(String.self, forKey: .azureDeployment)
        aiProvider = try c.decodeIfPresent(AIProvider.self, forKey: .aiProvider) ?? .codexCLI
        if aiProvider == .azureFoundry { aiProvider = .codexCLI }
        codexPath = try c.decodeIfPresent(String.self, forKey: .codexPath) ?? codexPath
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? claudePath
    }
    public init() {}
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var schemaVersion = currentVersion
    public var settings = AppSettings()
    public var sessions: [RipSession] = []
    public var selectedSessionID: UUID?
    public init() {}
    /// Interrupted demonstration work is never restored as running or successful.
    public mutating func recoverInterruptedWork() {
        for s in sessions.indices {
            for t in sessions[s].tracks.indices where [.reading, .encoding].contains(sessions[s].tracks[t].phase) {
                sessions[s].tracks[t].phase = .cancelled
                sessions[s].tracks[t].error = "The operation was interrupted. Temporary files have not been verified."
            }
        }
    }
}

public enum CDRipError: LocalizedError, Equatable {
    case unavailable(String), invalidSelection, missingDestination, unsupportedSchema(Int), corruptStore
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .invalidSelection: "Select at least one track from the current source."
        case .missingDestination: "Choose an output folder first."
        case .unsupportedSchema(let version): "Local data uses version \(version), which is newer than this app supports. It will not be overwritten."
        case .corruptStore: "Local data could not be read. The original file is preserved and saving is blocked."
        }
    }
}
