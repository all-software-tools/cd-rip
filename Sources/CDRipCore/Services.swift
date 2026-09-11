import Foundation

public protocol DiscSource: Sendable {
    func loadDisc() async throws -> DiscDescriptor
}

public struct SimulationEvent: Sendable {
    public var trackID: String
    public var phase: WorkPhase
    public var progress: Double
    public init(trackID: String, phase: WorkPhase, progress: Double) {
        self.trackID = trackID; self.phase = phase; self.progress = progress
    }
}

public protocol RippingService: Sendable {
    func simulate(_ session: RipSession, report: @Sendable @escaping (SimulationEvent) async throws -> Void) async throws
}

public protocol RecognitionService: Sendable {
    func identify(audioURL: URL) async throws -> [MetadataEvidence]
}

public protocol MetadataService: Sendable {
    func candidates(for evidence: [MetadataEvidence]) async throws -> [TrackMetadata]
}

public protocol MetadataReconciler: Sendable {
    func reconcile(track: SessionTrack, candidates: [TrackMetadata]) async throws -> SessionTrack
}

public protocol TagWritingService: Sendable {
    func apply(metadata: TrackMetadata, to audioURL: URL) async throws
}

public protocol WorkspaceStoring: Sendable {
    func load() async throws -> WorkspaceState
    func save(_ state: WorkspaceState) async throws
}

public struct DemoDiscSource: DiscSource {
    public init() {}
    public func loadDisc() async throws -> DiscDescriptor {
        try Task.checkCancellation()
        return DiscDescriptor(id: "demo-disc-v1", title: "Demo session", source: .demonstration,
            tracks: [236, 214, 281, 193, 258, 225, 247, 269].enumerated().map {
                SourceTrack(id: "demo-disc-v1-track-\($0.offset + 1)", number: $0.offset + 1, duration: Double($0.element))
            })
    }
}

/// UI/state-machine fixture only: never reads a drive, encodes audio or creates media files.
public struct DemoRippingService: RippingService {
    public let delay: Duration
    public init(delay: Duration = .milliseconds(85)) { self.delay = delay }
    public func simulate(_ session: RipSession, report: @Sendable @escaping (SimulationEvent) async throws -> Void) async throws {
        guard session.disc.source == .demonstration else {
            throw CDRipError.unavailable("The demonstration service cannot read a physical CD.")
        }
        for track in session.tracks {
            for step in 1...10 {
                try Task.checkCancellation()
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                try await report(.init(trackID: track.id, phase: step < 7 ? .reading : .encoding, progress: Double(step) / 11))
            }
            try Task.checkCancellation()
            try await report(.init(trackID: track.id, phase: .ripped, progress: 1))
        }
    }
}

public struct UnconfiguredRecognition: RecognitionService {
    public init() {}
    public func identify(audioURL: URL) async throws -> [MetadataEvidence] {
        throw CDRipError.unavailable("Audio recognition is not configured yet. No files were sent.")
    }
}

public struct UnconfiguredTagWriter: TagWritingService {
    public init() {}
    public func apply(metadata: TrackMetadata, to audioURL: URL) async throws {
        throw CDRipError.unavailable("This tag writing service is not configured.")
    }
}
