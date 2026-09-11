import Foundation
import Observation

public enum WorkspaceTab: String, CaseIterable, Sendable {
    case preparation = "Extraction", metadata = "Metadata", history = "Sessions"
}

@MainActor @Observable public final class AppModel {
    public private(set) var workspace = WorkspaceState()
    public private(set) var disc: DiscDescriptor?
    public var selectedTrackIDs: Set<String> = []
    public var selectedTrackID: String?
    public var tab: WorkspaceTab = .preparation
    public private(set) var isBusy = false
    public private(set) var isReviewingAI = false
    public private(set) var aiProgressText = ""
    @ObservationIgnored private let aiCatalog: any AIMetadataCatalog
    @ObservationIgnored private let aiGenerator: any AIMetadataGenerating
    public private(set) var isReadingTracklistImage = false
    public private(set) var ocrResult: OCRTracklistResult?
    public private(set) var ocrText = ""
    public private(set) var ocrError: String?
    public private(set) var ocrProgress = ""
    public private(set) var isTagging = false
    public private(set) var tagProgressText = ""
    public private(set) var completedRipCount = 0
    public private(set) var isReady = false
    public private(set) var persistenceFailed = false
    public var message: String?
    public var showSettings = false
    public private(set) var sourceStatus = "Detecting source…"
    public private(set) var isDetecting = false
    public private(set) var demonstrationMode = true
    @ObservationIgnored private var sourceRefresh: Task<Void, Never>?
    @ObservationIgnored private let opticalSource = MacOpticalSource()
    @ObservationIgnored private let opticalRipper = SecureOpticalRipper()

    @ObservationIgnored private let songCoverLoader: any SongCoverLoading
    @ObservationIgnored private let fileBackupRoot: URL
    @ObservationIgnored private let store: any WorkspaceStoring
    @ObservationIgnored private let source: any DiscSource
    @ObservationIgnored private let ripper: any RippingService
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var connectionOperation: Task<Void, Never>?
    public private(set) var isTestingConnection = false
    public func registerConnectionTest(_ task: Task<Void, Never>) { connectionOperation = task; isTestingConnection = true }
    public func finishConnectionTest() { connectionOperation = nil; isTestingConnection = false }

    public init(store: any WorkspaceStoring, source: any DiscSource = DemoDiscSource(), ripper: any RippingService = DemoRippingService(),
                aiCatalog: any AIMetadataCatalog = MusicBrainzAICatalog(), aiGenerator: any AIMetadataGenerating = AIMetadataProvider(), fileBackupRoot: URL = RipFileRouting.internalDirectory.appendingPathComponent("TagBackups"), songCoverLoader: any SongCoverLoading = SongCoverLoader()) {
        self.store = store; self.source = source; self.ripper = ripper
        self.aiCatalog = aiCatalog; self.aiGenerator = aiGenerator; self.fileBackupRoot = fileBackupRoot; self.songCoverLoader = songCoverLoader
    }
    public var currentSession: RipSession? {
        workspace.sessions.first { $0.id == workspace.selectedSessionID }
    }
    public var canStart: Bool {
        isReady && !persistenceFailed && !isBusy && !isDetecting && disc != nil && !selectedTrackIDs.isEmpty && !workspace.settings.destinationPath.isEmpty
    }
    public var selectedTrack: SessionTrack? { currentSession?.tracks.first { $0.id == selectedTrackID } }

    public func bootstrap() async {
        guard !isReady else { return }
        do {
            workspace = try await store.load()
            var recovered = false
            for s in workspace.sessions.indices {
                for t in workspace.sessions[s].tracks.indices {
                    if let plan = workspace.sessions[s].tracks[t].pendingFileTagSave {
                        if try await FileTagSaver().recover(plan) { finishFileTagSave(plan, sessionIndex: s, trackIndex: t) }
                        else { workspace.sessions[s].tracks[t].pendingFileTagSave = nil }
                        recovered = true
                    }
                }
            }
            if recovered { try await store.save(workspace) }
            if let session = currentSession { restoreSessionSettings(session) }
            selectedTrackID = currentSession?.tracks.first?.id
            isReady = true
        } catch {
            message = error.localizedDescription; persistenceFailed = true
        }
        if isReady { if let id = workspace.selectedSessionID { await refreshMediaFiles(sessionID: id) }; await refreshSource() }
    }

    public func setDemonstration(_ enabled: Bool) async {
        await sourceRefresh?.value
        guard !isBusy, !isDetecting else { return }
        demonstrationMode = enabled
        disc = nil; selectedTrackIDs = []
        await refreshSource()
    }

    /// Background polling updates the UI only when the source actually changes.
    /// User actions await the scan before touching the drive or changing source mode.
    public func refreshSource(background: Bool = false) async {
        // A manual click must not disappear behind an automatic scan.
        if !background, let pending = sourceRefresh {
            isDetecting = true
            sourceStatus = "Waiting for CD detection… Allow any macOS access request."
            await pending.value
        }
        guard !isBusy, !isDetecting, sourceRefresh == nil else { return }
        isDetecting = !background
        if !background { sourceStatus = "Detecting CD… Allow any macOS access request." }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.isDetecting = false; self.sourceRefresh = nil }
            do {
                let found = try await (self.demonstrationMode ? self.source.loadDisc() : self.opticalSource.loadDisc())
                try Task.checkCancellation()
                if self.disc != found {
                    self.selectedTrackIDs = Set(found.tracks.map(\.id))
                    self.disc = found
                }
                let status = self.demonstrationMode ? "Simulated source · no audio files" : "Audio CD · \(found.optical?.device ?? "") · \(found.tracks.count) tracks"
                if self.sourceStatus != status { self.sourceStatus = status }
            } catch {
                guard !(error is CancellationError) else { return }
                if self.disc != nil { self.disc = nil; self.selectedTrackIDs = [] }
                if self.sourceStatus != error.localizedDescription { self.sourceStatus = error.localizedDescription }
            }
        }
        sourceRefresh = task
        await task.value
    }

    public var allTracksSelected: Bool {
        guard let tracks = disc?.tracks, !tracks.isEmpty else { return false }
        return selectedTrackIDs == Set(tracks.map(\.id))
    }
    public func selectAllTracks(_ selected: Bool) {
        guard !isBusy else { return }
        selectedTrackIDs = selected ? Set(disc?.tracks.map(\.id) ?? []) : []
    }

    public func ejectDisc() async {
        await sourceRefresh?.value
        guard !isBusy, !isDetecting, let disc, disc.source == .optical else { return }
        isDetecting = true
        do {
            try await opticalSource.eject(disc)
            self.disc = nil; selectedTrackIDs = []; sourceStatus = "CD ejected."
        } catch { message = error.localizedDescription }
        isDetecting = false
    }

    public func startRip() async {
        await sourceRefresh?.value
        if demonstrationMode { await startSimulation(); return }
        guard canStart, let disc, disc.source == .optical, selectedTrackIDs.isSubset(of: Set(disc.tracks.map(\.id))) else { return }
        var session = RipSession(disc: disc, selectedIDs: selectedTrackIDs, profile: workspace.settings.profile, destinationPath: workspace.settings.destinationPath)
        session.outputFolders = workspace.settings.outputFolders
        session.settingsSnapshot = workspace.settings
        isBusy = true
        workspace.sessions.insert(session, at: 0); workspace.selectedSessionID = session.id
        selectedTrackID = session.tracks.first?.id
        await persist()
        guard !persistenceFailed else { isBusy = false; return }
        let savedSession = session
        let ripper = opticalRipper
        operation = Task { [weak self] in
            do {
                try await ripper.rip(savedSession) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.receiveOptical(event, sessionID: savedSession.id)
                }
                await self?.finish(sessionID: savedSession.id, error: nil)
            } catch { await self?.finish(sessionID: savedSession.id, error: error) }
        }
    }

    private func receiveOptical(_ event: OpticalRipEvent, sessionID: UUID) async throws {
        try Task.checkCancellation()
        guard let s = index(for: sessionID), let t = workspace.sessions[s].tracks.firstIndex(where: { $0.id == event.trackID }) else { throw CancellationError() }
        workspace.sessions[s].tracks[t].phase = event.phase
        workspace.sessions[s].tracks[t].progress = event.progress
        workspace.sessions[s].tracks[t].outputPaths = event.paths
        workspace.sessions[s].tracks[t].integrity = event.integrity
        workspace.sessions[s].updatedAt = Date()
        await persist()
        if persistenceFailed { throw ConnectionError("Reading stopped: the session could not be saved.") }
    }

    public func updateSettings(_ settings: AppSettings) async {
        guard isReady && !persistenceFailed && !isBusy else { return }
        workspace.settings = settings
        if tab == .metadata, let s = index(for: workspace.selectedSessionID) {
            var snapshot = settings
            snapshot.destinationPath = workspace.sessions[s].destinationPath
            snapshot.profile = workspace.sessions[s].outputProfile
            snapshot.outputFolders = workspace.sessions[s].outputFolders ?? RipOutputFolders()
            workspace.sessions[s].settingsSnapshot = snapshot
        }
        await persist()
    }

    public func startSimulation() async {
        guard !isBusy && isReady && !persistenceFailed else { return }
        guard let disc, !selectedTrackIDs.isEmpty, selectedTrackIDs.isSubset(of: Set(disc.tracks.map(\.id))) else {
            message = CDRipError.invalidSelection.localizedDescription; return
        }
        guard !workspace.settings.destinationPath.isEmpty else { message = CDRipError.missingDestination.localizedDescription; return }
        var session = RipSession(disc: disc, selectedIDs: selectedTrackIDs, profile: workspace.settings.profile, destinationPath: workspace.settings.destinationPath)
        session.settingsSnapshot = workspace.settings
        session.outputFolders = workspace.settings.outputFolders
        isBusy = true // Set before await to prevent double-click races.
        workspace.sessions.insert(session, at: 0)
        workspace.selectedSessionID = session.id
        selectedTrackID = session.tracks.first?.id
        await persist()
        guard !persistenceFailed else { isBusy = false; return }
        let ripper = self.ripper
        operation = Task { [weak self, session] in
            do {
                try await ripper.simulate(session) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.receive(event, sessionID: session.id)
                }
                await self?.finish(sessionID: session.id, error: nil)
            } catch { await self?.finish(sessionID: session.id, error: error) }
        }
    }

    public func cancel() { operation?.cancel() }
    public func cancelAndWait() async {
        operation?.cancel()
        connectionOperation?.cancel()
        await operation?.value
        await connectionOperation?.value
    }

    private func receive(_ event: SimulationEvent, sessionID: UUID) async throws {
        try Task.checkCancellation()
        guard let s = workspace.sessions.firstIndex(where: { $0.id == sessionID }),
              let t = workspace.sessions[s].tracks.firstIndex(where: { $0.id == event.trackID }) else { return }
        workspace.sessions[s].tracks[t].phase = event.phase
        workspace.sessions[s].tracks[t].progress = event.progress
        workspace.sessions[s].updatedAt = Date()
        if event.phase == .ripped {
            await persist()
            if persistenceFailed { throw CDRipError.unavailable("Simulation stopped: the session could not be saved.") }
        }
    }

    private func finish(sessionID: UUID, error: Error?) async {
        if let s = workspace.sessions.firstIndex(where: { $0.id == sessionID }) {
            if let error {
                for t in workspace.sessions[s].tracks.indices where ![.ripped, .awaitingVerification].contains(workspace.sessions[s].tracks[t].phase) {
                    workspace.sessions[s].tracks[t].phase = error is CancellationError ? .cancelled : .failed
                    workspace.sessions[s].tracks[t].error = error is CancellationError ? "Operation cancelled. Temporary files are preserved for diagnostics." : error.localizedDescription
                }
                if !(error is CancellationError) { message = error.localizedDescription }
            } else { tab = .metadata }
            workspace.sessions[s].updatedAt = Date()
        }
        await persist()
        isBusy = false
        operation = nil
        if error == nil, !persistenceFailed, workspace.settings.completionSound,
           let session = workspace.sessions.first(where: { $0.id == sessionID }),
           session.disc.source == .optical, !session.tracks.isEmpty,
           session.tracks.allSatisfy({ $0.phase == .awaitingVerification }) { completedRipCount += 1 }
    }

    private func restoreSessionSettings(_ session: RipSession) {
        if let settings = session.settingsSnapshot { workspace.settings = settings }
        workspace.settings.destinationPath = session.destinationPath
        workspace.settings.profile = session.outputProfile
        workspace.settings.outputFolders = session.outputFolders ?? RipOutputFolders()
    }

    public func selectSession(_ id: UUID) async {
        guard !isBusy, !persistenceFailed, let session = workspace.sessions.first(where: { $0.id == id }) else { return }
        guard await flushMetadataEdits() else { return }
        restoreSessionSettings(session)
        workspace.selectedSessionID = id
        selectedTrackID = currentSession?.tracks.first?.id
        tab = .metadata
        await refreshMediaFiles(sessionID: id)
        await persist()
    }

    public func saveTracklist(_ text: String, sessionID: UUID? = nil) async {
        guard !isBusy, !persistenceFailed, let s = index(for: sessionID) else { return }
        workspace.sessions[s].tracklist = text
        workspace.sessions[s].updatedAt = Date()
        await persist()
    }

    public func saveCommonArtist(_ text: String, sessionID: UUID? = nil) async {
        guard !isBusy, !persistenceFailed, let s = index(for: sessionID) else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.sessions[s].commonArtist = value.isEmpty ? nil : value
        workspace.sessions[s].updatedAt = Date()
        await persist()
    }

    private struct PendingEdit: Equatable {
        let sessionID: UUID
        let trackID: String
        let metadata: TrackMetadata
    }
    private var pendingMetadataEdits: [String: PendingEdit] = [:]
    public var hasUnsavedMetadataEdits: Bool { !pendingMetadataEdits.isEmpty }
    public func stageMetadataEdit(_ metadata: TrackMetadata, trackID: String, sessionID: UUID) {
        pendingMetadataEdits[sessionID.uuidString + ":" + trackID] = PendingEdit(sessionID: sessionID, trackID: trackID, metadata: metadata)
    }
    public func discardMetadataEdit(trackID: String, sessionID: UUID) {
        pendingMetadataEdits[sessionID.uuidString + ":" + trackID] = nil
    }
    public func discardAllMetadataEdits() { pendingMetadataEdits.removeAll() }
    public func flushMetadataEdits() async -> Bool {
        guard !isBusy, !persistenceFailed, isReady else { return false }
        guard !pendingMetadataEdits.isEmpty else { return true }
        let edits = pendingMetadataEdits
        guard edits.values.allSatisfy({ edit in workspace.sessions.contains { $0.id == edit.sessionID && $0.tracks.contains { $0.id == edit.trackID } } }) else {
            message = "The unsaved draft no longer has a matching session. Keep the app open and copy your edits."; return false
        }
        isBusy = true
        defer { isBusy = false }
        for edit in edits.values {
            guard let s = index(for: edit.sessionID), let t = workspace.sessions[s].tracks.firstIndex(where: { $0.id == edit.trackID }) else { continue }
            workspace.sessions[s].tracks[t].supplied = edit.metadata
            workspace.sessions[s].tracks[t].identification = .supplied
            workspace.sessions[s].updatedAt = Date()
        }
        await persist()
        guard !persistenceFailed else { return false }
        for (key, edit) in edits where pendingMetadataEdits[key] == edit { pendingMetadataEdits[key] = nil }
        return true
    }

    /// Saves a draft in the session, never tags any audio file.
    public func saveMetadata(_ metadata: TrackMetadata, trackID: String, sessionID: UUID? = nil) async {
        guard !isBusy, !persistenceFailed, let s = index(for: sessionID),
              let t = workspace.sessions[s].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        workspace.sessions[s].tracks[t].supplied = metadata
        workspace.sessions[s].tracks[t].identification = .supplied
        workspace.sessions[s].updatedAt = Date()
        await persist()
        let key = workspace.sessions[s].id.uuidString + ":" + trackID
        if !persistenceFailed, pendingMetadataEdits[key]?.metadata == metadata { pendingMetadataEdits[key] = nil }
    }

    public func applyTracklist(_ rows: [TracklistRow], original: String, commonArtist: String, sessionID: UUID) async {
        guard !isBusy, !persistenceFailed, let s = index(for: sessionID) else { return }
        let issues = TracklistParser.validate(rows, session: workspace.sessions[s])
        guard issues.isEmpty else { message = issues.joined(separator: "\n"); return }
        workspace.sessions[s].tracklist = original
        let artist = commonArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.sessions[s].commonArtist = artist.isEmpty ? nil : artist
        for t in workspace.sessions[s].tracks.indices {
            guard let row = rows.first(where: { $0.number == workspace.sessions[s].tracks[t].number }) else { continue }
            workspace.sessions[s].tracks[t].supplied.title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            workspace.sessions[s].tracks[t].supplied.artist = row.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            workspace.sessions[s].tracks[t].identification = .supplied
        }
        workspace.sessions[s].updatedAt = Date()
        await persist()
    }

    public func proposeCatalog(_ release: CatalogRelease, medium: CatalogMedium, cover: URL?, sessionID: UUID) async {
        guard !isBusy, !persistenceFailed, let s = index(for: sessionID), let tracks = medium.tracks,
              release.media?.contains(where: { $0.position == medium.position }) == true,
              Set(tracks.map(\.position)).count == tracks.count,
              workspace.sessions[s].tracks.allSatisfy({ local in tracks.contains { $0.position == local.number } }) else {
            message = "This release cannot be mapped to the selected tracks."; return
        }
        for t in workspace.sessions[s].tracks.indices {
            let current = workspace.sessions[s].tracks[t]
            guard let track = tracks.first(where: { $0.position == current.number }) else { continue }
            var proposal = TrackMetadata()
            proposal.title = track.trackTitle; proposal.artist = track.artist(albumArtist: release.artist)
            proposal.album = release.title; proposal.albumArtist = release.artist
            proposal.year = release.date ?? ""; proposal.discNumber = medium.position; proposal.discTotal = release.media?.count ?? 1
            proposal.coverPath = cover?.path
            var evidence = MetadataEvidence(id: "musicbrainz:\(release.id):\(medium.position):\(track.id)", provider: "MusicBrainz", recordingID: track.recording.id, releaseID: release.id)
            evidence.sourceURL = "https://musicbrainz.org/release/\(release.id)"
            evidence.fields = ["title", "artist", "album", "albumArtist", "discNumber", "discTotal"]
            if release.date != nil { evidence.fields?.append("year") }
            evidence.mediumPosition = medium.position
            evidence.recordingDuration = track.duration
            if let optical = workspace.sessions[s].disc.optical,
               let discID = try? MusicBrainzDiscID.calculate(optical), medium.contains(discID: discID) {
                evidence.discID = discID
            }
            workspace.sessions[s].tracks[t].proposed = proposal
            workspace.sessions[s].tracks[t].evidence.removeAll { $0.provider == "MusicBrainz" || $0.provider == "Cover Art Archive" }
            workspace.sessions[s].tracks[t].evidence.append(evidence)
            if cover != nil {
                var coverEvidence = MetadataEvidence(id: "coverartarchive:\(release.id)", provider: "Cover Art Archive", releaseID: release.id)
                coverEvidence.sourceURL = "https://coverartarchive.org/release/\(release.id)/front-500"
                coverEvidence.fields = ["coverPath"]
                workspace.sessions[s].tracks[t].evidence.append(coverEvidence)
            }
            let titleConflict = !current.supplied.title.isEmpty && current.supplied.title.compare(proposal.title, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
            let durationConflict = track.duration.map { abs($0 - current.duration) > 3 } ?? false
            workspace.sessions[s].tracks[t].identification = titleConflict || durationConflict ? .conflict : .needsReview
        }
        workspace.sessions[s].updatedAt = Date()
        await persist()
    }

    public private(set) var mediaFileIssues: [String: String] = [:]
    private var checkedMediaPaths: Set<String> = []
    public func mediaIssue(for track: SessionTrack) -> String? { track.outputPaths.compactMap { mediaFileIssues[$0] }.first }
    public func refreshMediaFiles(sessionID: UUID) async {
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }) else { return }
        let issues = await FileTagSaver().checkFiles(session.tracks)
        for track in session.tracks {
            guard let current = workspace.sessions.first(where: { $0.id == sessionID })?.tracks.first(where: { $0.id == track.id }),
                  current.outputPaths == track.outputPaths, current.savedFileHashes == track.savedFileHashes else { continue }
            for path in track.outputPaths { checkedMediaPaths.insert(path); mediaFileIssues[path] = issues[path] }
        }
    }

    public func effectiveFileTags(_ track: SessionTrack, session: RipSession) -> TrackMetadata {
        var metadata = track.supplied
        metadata.artist = session.effectiveArtist(for: track).trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return metadata
    }
    public func fileSaveDestination(_ path: String, metadata: TrackMetadata, session: RipSession) -> URL {
        let input = URL(fileURLWithPath: path)
        return (session.outputFolders ?? RipOutputFolders()).base(for: input.pathExtension, fallback: session.destinationPath)
            .appendingPathComponent(FileTagSaver.filename(metadata: metadata, extension: input.pathExtension))
    }
    public func fileTagsAreCurrent(_ track: SessionTrack, session: RipSession) -> Bool {
        !track.outputPaths.isEmpty && track.outputPaths.allSatisfy { checkedMediaPaths.contains($0) && mediaFileIssues[$0] == nil && URL(fileURLWithPath: $0).standardizedFileURL == fileSaveDestination($0, metadata: effectiveFileTags(track, session: session), session: session).standardizedFileURL } && track.savedFileTags == effectiveFileTags(track, session: session) && track.fileTagError == nil && track.pendingFileTagSave == nil
    }
    private func finishFileTagSave(_ plan: FileTagSavePlan, sessionIndex s: Int, trackIndex t: Int) {
        if let old = workspace.sessions[s].tracks[t].tagRevisions {
            workspace.sessions[s].tracks[t].tagRevisions = old.map { revision in
                TagRevision(id: revision.id, createdAt: revision.createdAt, metadata: revision.metadata,
                    outputPaths: revision.outputPaths.map { path in plan.files.first { $0.original == path }?.backup ?? path }, originalPaths: revision.originalPaths)
            }
        }
        workspace.sessions[s].tracks[t].outputPaths = plan.revision.outputPaths
        workspace.sessions[s].tracks[t].savedFileTags = plan.revision.metadata
        workspace.sessions[s].tracks[t].savedFileHashes = Dictionary(uniqueKeysWithValues: plan.files.map { ($0.output, $0.taggedHash) })
        for file in plan.files { checkedMediaPaths.insert(file.output); mediaFileIssues[file.output] = nil }
        workspace.sessions[s].tracks[t].fileTagError = nil
        if workspace.sessions[s].tracks[t].tagRevisions == nil { workspace.sessions[s].tracks[t].tagRevisions = [] }
        if workspace.sessions[s].tracks[t].tagRevisions?.contains(where: { $0.id == plan.revision.id }) != true {
            workspace.sessions[s].tracks[t].tagRevisions?.append(plan.revision)
        }
        workspace.sessions[s].tracks[t].pendingFileTagSave = nil
        workspace.sessions[s].updatedAt = Date()
    }
    public func saveTagsAndFilenames(sessionID: UUID, trackIDs: Set<String>) async {
        guard !isBusy, !persistenceFailed, isReady, let s = index(for: sessionID), !trackIDs.isEmpty else { return }
        guard !workspace.sessions[s].destinationPath.isEmpty else { message = "Choose an output folder in Extraction before saving."; return }
        let session = workspace.sessions[s]
        let tracks = session.tracks.filter { trackIDs.contains($0.id) }
        guard tracks.count == trackIDs.count, session.disc.source == .optical,
              tracks.allSatisfy({ $0.phase == .awaitingVerification && $0.integrity?.readCompleted == true && !$0.outputPaths.isEmpty }) else {
            message = "Save requires completed extracted files for every selected track."; return
        }
        guard tracks.allSatisfy({ let tags = effectiveFileTags($0, session: session); return !tags.artist.isEmpty && !tags.title.isEmpty }) else {
            message = "Enter an artist and title for every selected track before saving files."; return
        }
        let names = tracks.flatMap { track in track.outputPaths.map { path in
            fileSaveDestination(path, metadata: effectiveFileTags(track, session: session), session: session).path.lowercased()
        } }
        guard Set(names).count == names.count else { message = "Two tracks would have the same filename. Give them distinct titles before saving."; return }
        isBusy = true; isTagging = true; message = nil
        tagProgressText = "Preparing to save tags and filenames…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.isTagging = false; self.operation = nil }
            await self.refreshMediaFiles(sessionID: sessionID)
            var saved = 0, skipped = 0
            for (position, track) in tracks.enumerated() {
                guard let s = self.index(for: sessionID), let t = self.workspace.sessions[s].tracks.firstIndex(where: { $0.id == track.id }) else { return }
                do {
                    try Task.checkCancellation()
                    if let issue = self.mediaIssue(for: track) { throw ConnectionError(issue) }
                    if self.fileTagsAreCurrent(track, session: session) { skipped += 1; continue }
                    self.tagProgressText = "Saving track \(track.number) · \(position + 1)/\(tracks.count) · verifying tags and unchanged audio…"
                    let metadata = self.effectiveFileTags(track, session: session)
                    let saver = FileTagSaver()
                    let plan = try await saver.prepare(metadata: metadata, number: track.number, total: session.disc.tracks.count,
                        inputs: track.outputPaths.map { URL(fileURLWithPath: $0) },
                        destinations: track.outputPaths.map { self.fileSaveDestination($0, metadata: metadata, session: session) },
                        backupRoot: self.fileBackupRoot)
                    // Durable checkpoint precedes any source replacement, including across separate output volumes.
                    self.workspace.sessions[s].tracks[t].pendingFileTagSave = plan
                    await self.persist()
                    guard !self.persistenceFailed else { return }
                    try await saver.commit(plan)
                    self.finishFileTagSave(plan, sessionIndex: s, trackIndex: t)
                    await self.persist()
                    guard !self.persistenceFailed else { return }
                    saved += 1
                } catch {
                    // A pending plan stays durable if rollback could not finish. Startup will recover it safely.
                    if let pending = self.workspace.sessions[s].tracks[t].pendingFileTagSave {
                        do {
                            if try await FileTagSaver().recover(pending) { self.finishFileTagSave(pending, sessionIndex: s, trackIndex: t) }
                            else { self.workspace.sessions[s].tracks[t].pendingFileTagSave = nil }
                        } catch { self.message = "File recovery needs attention. Backups and session recovery information were preserved." }
                    }
                    self.workspace.sessions[s].tracks[t].fileTagError = Task.isCancelled ? "Save cancelled. Retry to finish this track." : error.localizedDescription
                    await self.persist()
                    self.tagProgressText = "Save stopped at track \(track.number). \(saved) saved; remaining files were not changed."
                    if self.message == nil { self.message = self.workspace.sessions[s].tracks[t].fileTagError }
                    return
                }
            }
            self.tagProgressText = "Saved tags and filenames · \(saved) tracks updated · \(skipped) already saved."
            self.message = self.tagProgressText
        }
    }

    public func writeTags(metadata: TrackMetadata, trackID: String, sessionID: UUID) async {
        guard !isBusy, !persistenceFailed, let s = index(for: sessionID),
              let t = workspace.sessions[s].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let session = workspace.sessions[s]
        let track = session.tracks[t]
        guard session.disc.source == .optical, track.phase == .awaitingVerification,
              let integrity = track.integrity, integrity.readCompleted, !track.outputPaths.isEmpty else {
            message = "Tagging requires extracted files and a complete read report. Writing tags does not change the audio verification status."; return
        }
        var tags = metadata
        if tags.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { tags.artist = session.commonArtist ?? "" }
        guard !tags.artist.isEmpty, !tags.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Enter a title and artist before writing tags."; return
        }
        isBusy = true; isTagging = true
        workspace.sessions[s].tracks[t].supplied = metadata
        workspace.sessions[s].tracks[t].identification = .supplied
        await persist()
        guard !persistenceFailed else { isBusy = false; isTagging = false; return }
        let destination = URL(fileURLWithPath: integrity.logPath).deletingLastPathComponent().appendingPathComponent("Tagged - \(UUID())")
        operation = Task { [weak self] in
            do {
                var revision = try await AudioTagWriter().write(metadata: tags, number: track.number, total: session.disc.tracks.count,
                    inputs: track.outputPaths.map { URL(fileURLWithPath: $0) }, destination: destination)
                if let folders = session.outputFolders {
                    let local = revision.outputPaths.map { URL(fileURLWithPath: $0) }
                    let routed = try await RipFileRouting.publish(local, folders: folders, fallback: session.destinationPath,
                        sessionID: session.id, subfolder: "Tagged - \(revision.id)")
                    revision = TagRevision(id: revision.id, createdAt: revision.createdAt, metadata: revision.metadata,
                        outputPaths: routed.map(\.path), originalPaths: revision.originalPaths)
                    try JSONEncoder().encode(revision).write(to: destination.appendingPathComponent("tag-revision.json"), options: .atomic)
                    for file in local { try FileManager.default.removeItem(at: file) }
                }
                guard let self, let s = self.index(for: sessionID), let t = self.workspace.sessions[s].tracks.firstIndex(where: { $0.id == trackID }) else { return }
                if self.workspace.sessions[s].tracks[t].tagRevisions == nil { self.workspace.sessions[s].tracks[t].tagRevisions = [] }
                self.workspace.sessions[s].tracks[t].tagRevisions?.append(revision)
                self.workspace.sessions[s].updatedAt = Date()
                await self.persist()
            } catch {
                self?.message = error is CancellationError ? "Tagging cancelled. Originals and saved versions are preserved." : error.localizedDescription
            }
            self?.isBusy = false; self?.isTagging = false; self?.operation = nil
        }
    }

    public func applyImportedCover(_ cover: ImportedCover, sessionID: UUID, trackIDs: Set<String>, replaceExisting: Bool) async {
        guard !isBusy, !persistenceFailed, let s = index(for: sessionID),
              FileManager.default.fileExists(atPath: cover.filePath), !trackIDs.isEmpty,
              trackIDs.isSubset(of: Set(workspace.sessions[s].tracks.map(\.id))) else { return }
        for t in workspace.sessions[s].tracks.indices where trackIDs.contains(workspace.sessions[s].tracks[t].id) {
            guard replaceExisting || workspace.sessions[s].tracks[t].supplied.coverPath == nil else { continue }
            workspace.sessions[s].tracks[t].supplied.coverPath = cover.filePath
            workspace.sessions[s].tracks[t].coverImport = cover
        }
        workspace.sessions[s].updatedAt = Date()
        await persist()
    }

    private var ocrRecognizedInput: OCRTracklistResult?
    public func canRetryTracklistImage(sessionID: UUID) -> Bool {
        ocrRecognizedInput?.sessionID == sessionID && !isBusy
    }
    public func retryTracklistImage(sessionID: UUID) async {
        guard let input = ocrRecognizedInput, input.sessionID == sessionID else { return }
        await readTracklistImage(URL(fileURLWithPath: input.imagePath), sessionID: sessionID, recognizedLines: input.lines)
    }
    public func clearTracklistImagePreview() {
        guard !isBusy else { return }
        ocrResult = nil; ocrError = nil; ocrProgress = ""; ocrText = ""; ocrRecognizedInput = nil
    }

    public func readTracklistImage(_ url: URL, sessionID: UUID, horizontalRange: ClosedRange<Double> = 0...1, recognizedLines: [OCRTextLine]? = nil) async {
        guard isReady, !isBusy, !isTestingConnection, !persistenceFailed, let s = index(for: sessionID) else { return }
        let settings = workspace.settings
        guard (workspace.sessions[s].aiCallCount ?? 0) < settings.maxAICallsPerSession else { ocrError = "The session AI request limit has been reached. Adjust it in Settings."; return }
        if recognizedLines == nil { ocrRecognizedInput = nil }
        ocrResult = nil; ocrError = nil; ocrText = ""; ocrProgress = recognizedLines == nil ? "Reading text from the image on your Mac…" : "Retrying AI grouping of recognized text…"
        isBusy = true; isReadingTracklistImage = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.isReadingTracklistImage = false; self.operation = nil }
            do {
                let start = Date()
                let lines: [OCRTextLine]
                if let recognizedLines { lines = recognizedLines }
                else { lines = try await VisionTracklistReader().read(url, horizontalRange: horizontalRange) }
                self.ocrRecognizedInput = OCRTracklistResult(sessionID: sessionID, imagePath: url.path, lines: lines, discs: [])
                try Task.checkCancellation()
                self.ocrText = lines.map(\.text).joined(separator: "\n")
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
                guard let s = self.index(for: sessionID) else { return }
                self.workspace.sessions[s].aiCallCount = (self.workspace.sessions[s].aiCallCount ?? 0) + 1
                await self.persist()
                guard !self.persistenceFailed else { return }
                let modelName = settings.metadataModel.isEmpty ? (settings.aiProvider == .claudeCLI ? "Haiku" : "CLI default, low reasoning") : settings.metadataModel
                self.ocrProgress = (recognizedLines == nil ? "OCR read \(lines.count) lines in \(elapsed)s. " : "Reusing \(lines.count) recognized lines. ") + "Grouping CDs with \(settings.aiProvider.title) · \(modelName)…"
                let discs = try await CLITracklistOrganizer().organize(lines, settings: settings)
                try Task.checkCancellation()
                self.ocrResult = OCRTracklistResult(sessionID: sessionID, imagePath: url.path, lines: lines, discs: discs)
                self.ocrProgress = "Choose the CD you ripped and confirm each row against the image."
            } catch {
                self.ocrError = error is CancellationError ? "Image reading cancelled. No track names were changed." : error.localizedDescription
            }
        }
    }

    public func findSongMetadata(trackID: String, sessionID: UUID) async {
        await findSongsMetadata(trackIDs: [trackID], sessionID: sessionID)
    }
    public func findAllSongMetadata(sessionID: UUID) async {
        guard let s = index(for: sessionID) else { return }
        await findSongsMetadata(trackIDs: workspace.sessions[s].tracks.map(\.id), sessionID: sessionID)
    }
    private func findSongsMetadata(trackIDs: [String], sessionID: UUID) async {
        guard isReady, !isBusy, !isTestingConnection, !persistenceFailed, !trackIDs.isEmpty,
              let s = index(for: sessionID), trackIDs.allSatisfy({ id in workspace.sessions[s].tracks.contains { $0.id == id } }) else { return }
        let settings = workspace.settings
        guard let researcher = aiGenerator as? any WebMetadataGenerating, settings.aiProvider != .azureFoundry else { message = "Select Codex CLI or Claude Code CLI in Settings."; return }
        guard (1...100).contains(settings.maxAICallsPerSession) else { message = "Set the AI request limit between 1 and 100."; return }
        isBusy = true; isReviewingAI = true; message = nil
        aiProgressText = "Preparing metadata search…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.isReviewingAI = false; self.operation = nil }
            var completed = 0, skipped = 0, failed = 0
            for (position, trackID) in trackIDs.enumerated() {
                if Task.isCancelled { self.aiProgressText = "Search cancelled · \(completed) results kept. Audio files are unchanged."; return }
                guard !self.persistenceFailed, let s = self.index(for: sessionID),
                      let t = self.workspace.sessions[s].tracks.firstIndex(where: { $0.id == trackID }) else { return }
                let session = self.workspace.sessions[s], track = self.workspace.sessions[s].tracks[t]
                let supplied = self.effectiveFileTags(track, session: session)
                if supplied.artist.isEmpty || supplied.title.isEmpty {
                    self.workspace.sessions[s].tracks[t].aiError = "Enter the artist and title before searching."
                    self.workspace.sessions[s].tracks[t].aiErrorStage = "input"
                    failed += 1; await self.persist(); continue
                }
                if [supplied.year, supplied.genre, supplied.album, supplied.albumArtist].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), supplied.coverPath != nil {
                    skipped += 1; continue
                }
                guard (session.aiCallCount ?? 0) < settings.maxAICallsPerSession else {
                    self.aiProgressText = "Request limit reached · \(completed) results kept · \(skipped) already complete · \(failed) errors. Adjust the limit in Settings to continue."
                    self.message = self.aiProgressText; return
                }
                self.aiProgressText = "Track \(track.number) · \(position + 1)/\(trackIDs.count) · " + supplied.artist + " — " + supplied.title + "…"
            do {
                let hash = try AIMetadataContract.fingerprint(session: session, track: track, settings: settings)
                self.workspace.sessions[s].aiCallCount = (self.workspace.sessions[s].aiCallCount ?? 0) + 1
                await self.persist()
                guard !self.persistenceFailed else { return }
                let result = try await researcher.researchSong(session: session, track: track, settings: settings)
                try Task.checkCancellation()
                var artwork: SongCoverResult?
                if track.supplied.coverPath == nil {
                    self.aiProgressText = "Track \(track.number) · \(position + 1)/\(trackIDs.count) · loading artwork…"
                    artwork = try await self.songCoverLoader.load(result.covers)
                }
                try Task.checkCancellation()
                guard let currentS = self.index(for: sessionID), let t = self.workspace.sessions[currentS].tracks.firstIndex(where: { $0.id == trackID }),
                      try AIMetadataContract.fingerprint(session: self.workspace.sessions[currentS], track: self.workspace.sessions[currentS].tracks[t], settings: settings) == hash else {
                    throw ConnectionError("The draft changed during the search. Search again for the updated artist and title.")
                }
                var record = AIReviewRecord(usedAI: true, inputHash: hash, provider: settings.aiProvider,
                    model: settings.metadataModel.isEmpty ? "CLI default" : settings.metadataModel, promptVersion: AIWebMetadataContract.songVersion,
                    createdAt: Date(), decision: result.decision, candidate: result.candidate, inputTokens: result.inputTokens, outputTokens: result.outputTokens)
                record.webCovers = result.covers
                var metadata = self.workspace.sessions[currentS].tracks[t].supplied
                let keys: [String: WritableKeyPath<TrackMetadata, String>] = ["year": \.year, "genre": \.genre, "album": \.album, "albumArtist": \.albumArtist]
                for (name, key) in keys where metadata[keyPath: key].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let value = result.candidate?.tags[name] { metadata[keyPath: key] = value }
                }
                if let artwork { metadata.coverPath = artwork.cover.filePath; self.workspace.sessions[currentS].tracks[t].coverImport = artwork.cover }
                self.workspace.sessions[currentS].tracks[t].supplied = metadata
                self.workspace.sessions[currentS].tracks[t].aiReview = record
                self.workspace.sessions[currentS].tracks[t].aiError = nil
                self.workspace.sessions[currentS].tracks[t].aiErrorStage = nil
                self.workspace.sessions[currentS].tracks[t].aiReviewAppliedAt = Date()
                self.workspace.sessions[currentS].updatedAt = Date()
                await self.persist()
                completed += 1
            } catch {
                if Task.isCancelled || error is CancellationError { self.aiProgressText = "Search cancelled · \(completed) results kept. Audio files are unchanged."; return }
                if let currentS = self.index(for: sessionID), let t = self.workspace.sessions[currentS].tracks.firstIndex(where: { $0.id == trackID }) {
                    self.workspace.sessions[currentS].tracks[t].aiError = error.localizedDescription
                    self.workspace.sessions[currentS].tracks[t].aiErrorStage = "ai"
                    await self.persist()
                }
                failed += 1
            }
            }
            self.aiProgressText = "Search finished · \(completed) researched · \(skipped) already complete · \(failed) errors. Review the fields and images, then Save all."
            self.message = self.aiProgressText
        }
    }

    public func startAIReview(trackIDs: Set<String>, forceRefresh: Bool = false) async {
        guard isReady, !isBusy, !isTestingConnection, !persistenceFailed, let session = currentSession,
              !trackIDs.isEmpty, trackIDs.isSubset(of: Set(session.tracks.map(\.id))) else { return }
        let settings = workspace.settings
        guard (1...100).contains(settings.maxAICallsPerSession) else { message = "Set the AI request limit between 1 and 100."; return }
        isBusy = true; isReviewingAI = true; aiProgressText = "Preparing metadata review…"
        operation = Task { [weak self] in
            guard let self else { return }
            await self.performAIReview(session: session, trackIDs: trackIDs, settings: settings, forceRefresh: forceRefresh)
            self.isReviewingAI = false; self.isBusy = false; self.operation = nil
        }
    }
    private func performAIReview(session: RipSession, trackIDs: Set<String>, settings: AppSettings, forceRefresh: Bool) async {
        if let researcher = aiGenerator as? any WebMetadataGenerating {
            await performWebReview(researcher, session: session, trackIDs: trackIDs, settings: settings, forceRefresh: forceRefresh)
            return
        }
        let selected = session.tracks.filter { trackIDs.contains($0.id) }
        var completed = 0, failed = 0, cached = 0
        for (position, track) in selected.enumerated() {
            if Task.isCancelled { aiProgressText = "AI review cancelled. Completed results are saved."; return }
            guard let s = index(for: session.id), let t = workspace.sessions[s].tracks.firstIndex(where: { $0.id == track.id }) else { return }
            var requestedAI = false
            do {
                let hash = try AIMetadataContract.fingerprint(session: session, track: track, settings: settings)
                if !forceRefresh, let previous = track.aiReview, previous.inputHash == hash, Date().timeIntervalSince(previous.createdAt) < 86400 {
                    cached += 1; completed += 1; workspace.sessions[s].tracks[t].aiErrorStage = nil; workspace.sessions[s].tracks[t].aiError = nil; continue
                }
                aiProgressText = "Track \(track.number) · \(position + 1)/\(selected.count) · looking up catalog candidates…"
                let candidates = try await aiCatalog.candidates(session: session, track: track)
                try Task.checkCancellation()
                let input = AIMetadataInput(trackId: track.id, number: track.number, duration: track.duration,
                    suppliedTags: AIMetadataContract.tags(track.supplied, artist: session.effectiveArtist(for: track)), candidates: candidates)
                let decision: AIMetadataDecision
                var response: AIStructuredResponse?
                if candidates.isEmpty {
                    decision = AIMetadataDecision(trackId: track.id, candidateId: nil, evidenceIds: [], status: .noMatch,
                        proposedTags: Dictionary(uniqueKeysWithValues: AIMetadataContract.fields.map { ($0, Optional<String>.none) }), conflicts: [],
                        missingFields: AIMetadataContract.fields.filter { input.suppliedTags[$0] == nil },
                        explanation: "No catalog candidate found. AI was not called. Check the artist/title or choose the album in the catalog.")
                } else {
                    requestedAI = true
                    guard (workspace.sessions[s].aiCallCount ?? 0) < settings.maxAICallsPerSession else { throw ConnectionError("The session AI request limit has been reached. Saved results remain available. You can adjust the limit in Settings.") }
                    let key = settings.aiProvider == .azureFoundry ? try AzureKeychain.read(endpoint: settings.azureEndpoint) : ""
                    workspace.sessions[s].aiCallCount = (workspace.sessions[s].aiCallCount ?? 0) + 1
                    await persist()
                    guard !persistenceFailed else { return }
                    aiProgressText = "Track \(track.number) · \(position + 1)/\(selected.count) · reviewing with \(settings.aiProvider.title)…"
                    response = try await aiGenerator.generate(input: input, settings: settings, azureKey: key)
                    try Task.checkCancellation()
                    decision = try AIMetadataContract.validate(response!.data, input: input)
                }
                // Reject stale work if a concurrent input update occurred while a request was running.
                guard try AIMetadataContract.fingerprint(session: workspace.sessions[s], track: workspace.sessions[s].tracks[t], settings: settings) == hash else {
                    throw ConnectionError("Metadata changed during AI review. Run the review again for the updated draft.")
                }
                let record = AIReviewRecord(usedAI: response != nil, inputHash: hash, provider: settings.aiProvider,
                    model: settings.metadataModel.isEmpty ? "CLI default" : settings.metadataModel, promptVersion: AIMetadataContract.version,
                    createdAt: Date(), decision: decision, candidate: candidates.first { $0.id == decision.candidateId },
                    inputTokens: response?.inputTokens, outputTokens: response?.outputTokens)
                workspace.sessions[s].tracks[t].aiReview = record
                workspace.sessions[s].tracks[t].aiErrorStage = nil; workspace.sessions[s].tracks[t].aiError = nil
                workspace.sessions[s].tracks[t].aiReviewAppliedAt = nil
                workspace.sessions[s].updatedAt = Date()
                completed += 1
            } catch {
                if Task.isCancelled || error is CancellationError { aiProgressText = "AI review cancelled. Completed results are saved."; return }
                failed += 1
                workspace.sessions[s].tracks[t].aiErrorStage = requestedAI ? "ai" : "catalog"
                workspace.sessions[s].tracks[t].aiError = (error is ConnectionError || error is CatalogUnavailable) ? error.localizedDescription : (requestedAI ? "The AI service could not complete this track. Check the connection and retry." : "The catalog could not be reached. Check the connection and retry unfinished tracks.")
                if requestedAI || error is CatalogUnavailable || error is URLError {
                    await persist()
                    aiProgressText = "Review stopped at track \(track.number). Use Retry unfinished tracks after the service recovers; completed results are saved."
                    return
                }
            }
            await persist()
            if persistenceFailed { aiProgressText = "Stopped: results could not be saved."; return }
        }
        await persist()
        aiProgressText = "Review finished · \(completed) results · \(cached) reused · \(failed) errors. Audio and draft tags are unchanged."
    }
    public func saveMetadataReferenceURL(_ value: String, sessionID: UUID) async {
        guard !isBusy, !persistenceFailed, let s = index(for: sessionID) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let url = URL(string: trimmed), (try? CoverAddress.validate(url)) != nil else {
                message = "Enter a public HTTPS album/reference URL."; return
            }
        }
        workspace.sessions[s].metadataReferenceURL = trimmed.isEmpty ? nil : trimmed
        workspace.sessions[s].updatedAt = Date()
        await persist()
    }
    private func performWebReview(_ researcher: any WebMetadataGenerating, session: RipSession, trackIDs: Set<String>, settings: AppSettings, forceRefresh: Bool) async {
        let selected = session.tracks.filter { trackIDs.contains($0.id) }
        var completed = 0, cached = 0, failed = 0
        // Clear obsolete catalog errors before queuing web research; never present them as new CLI failures.
        if let s = index(for: session.id) {
            for t in workspace.sessions[s].tracks.indices where trackIDs.contains(workspace.sessions[s].tracks[t].id) {
                let track = workspace.sessions[s].tracks[t]
                if track.aiErrorStage == "catalog" || (track.aiErrorStage == nil && track.aiError?.contains("catalog") == true) {
                    workspace.sessions[s].tracks[t].aiError = nil
                    workspace.sessions[s].tracks[t].aiErrorStage = nil
                }
            }
            await persist()
            if persistenceFailed { return }
        }
        for (position, track) in selected.enumerated() {
            guard let s = index(for: session.id), let t = workspace.sessions[s].tracks.firstIndex(where: { $0.id == track.id }) else { return }
            do {
                try Task.checkCancellation()
                let hash = try AIMetadataContract.fingerprint(session: session, track: track, settings: settings)
                if !forceRefresh, let previous = track.aiReview, previous.inputHash == hash,
                   previous.promptVersion == AIWebMetadataContract.version, Date().timeIntervalSince(previous.createdAt) < 86400 {
                    cached += 1; completed += 1
                    workspace.sessions[s].tracks[t].aiError = nil; workspace.sessions[s].tracks[t].aiErrorStage = nil
                    continue
                }
                guard settings.aiProvider != .azureFoundry else { throw ConnectionError("Select Codex CLI or Claude Code CLI in Settings.") }
                guard (workspace.sessions[s].aiCallCount ?? 0) < settings.maxAICallsPerSession else { throw ConnectionError("The session AI request limit has been reached. Adjust the limit in Settings to continue.") }
                workspace.sessions[s].aiCallCount = (workspace.sessions[s].aiCallCount ?? 0) + 1
                await persist()
                guard !persistenceFailed else { return }
                aiProgressText = "Track \(track.number) · \(position + 1)/\(selected.count) · \(settings.aiProvider.title) searching the web for metadata and cover…"
                let result = try await researcher.research(session: session, track: track, settings: settings)
                try Task.checkCancellation()
                guard try AIMetadataContract.fingerprint(session: workspace.sessions[s], track: workspace.sessions[s].tracks[t], settings: settings) == hash else { throw ConnectionError("The album context changed. Retry this track.") }
                var record = AIReviewRecord(usedAI: true, inputHash: hash, provider: settings.aiProvider,
                    model: settings.metadataModel.isEmpty ? "CLI default" : settings.metadataModel, promptVersion: AIWebMetadataContract.version,
                    createdAt: Date(), decision: result.decision, candidate: result.candidate,
                    inputTokens: result.inputTokens, outputTokens: result.outputTokens)
                record.webCovers = result.covers
                workspace.sessions[s].tracks[t].aiRejectedResponse = nil
                workspace.sessions[s].tracks[t].aiReview = record
                workspace.sessions[s].tracks[t].aiError = nil; workspace.sessions[s].tracks[t].aiErrorStage = nil
                workspace.sessions[s].tracks[t].aiReviewAppliedAt = nil
                workspace.sessions[s].updatedAt = Date(); completed += 1
                await persist()
                if persistenceFailed { aiProgressText = "Stopped: results could not be saved."; return }
            } catch {
                if Task.isCancelled || error is CancellationError { aiProgressText = "Web research cancelled. Completed results are saved."; return }
                workspace.sessions[s].tracks[t].aiErrorStage = "ai"
                workspace.sessions[s].tracks[t].aiError = (error is ConnectionError || error is WebMetadataValidationError) ? error.localizedDescription : "CLI web research failed. Check the connection and retry unfinished tracks."
                workspace.sessions[s].tracks[t].aiRejectedResponse = (error as? WebMetadataValidationError)?.responseJSON
                await persist()
                if persistenceFailed { aiProgressText = "Stopped: results could not be saved."; return }
                if error is WebMetadataValidationError {
                    failed += 1
                    aiProgressText = "Track \(track.number) needs a retry; continuing with remaining tracks…"
                    continue
                }
                aiProgressText = "Web research stopped at track \(track.number). Completed results are saved; use Retry unfinished tracks."
                return
            }
        }
        await persist()
        aiProgressText = "Web research finished · \(completed) results · \(cached) reused · \(failed) track errors. Review metadata and cover proposals before applying."
    }
    public func aiReviewLabel(_ track: SessionTrack, session: RipSession) -> String {
        if track.aiErrorStage == "catalog" || (track.aiErrorStage == nil && track.aiError?.contains("catalog") == true) {
            return "Awaiting web review"
        }
        if track.aiError != nil { return "AI error — retry track" }
        if track.aiReview?.promptVersion != AIWebMetadataContract.version && track.aiReview?.promptVersion != AIWebMetadataContract.songVersion { return "Awaiting web review" }
        return aiReviewIsCurrent(track, session: session) ? "Reviewed" : "Needs new review"
    }
    public func aiReviewIsCurrent(_ track: SessionTrack, session: RipSession) -> Bool {
        guard let review = track.aiReview else { return false }
        return (try? AIMetadataContract.fingerprint(session: session, track: track, settings: workspace.settings)) == review.inputHash
    }
    public func applyAIReview(trackID: String, sessionID: UUID, replaceExisting: Bool) async {
        guard !isBusy, !persistenceFailed, let s = index(for: sessionID),
              let t = workspace.sessions[s].tracks.firstIndex(where: { $0.id == trackID }),
              let review = workspace.sessions[s].tracks[t].aiReview, let candidate = review.candidate else { return }
        guard aiReviewIsCurrent(workspace.sessions[s].tracks[t], session: workspace.sessions[s]) else {
            message = "The draft or provider changed after this review. Run AI review again before applying it."; return
        }
        var metadata = workspace.sessions[s].tracks[t].supplied
        let effective = AIMetadataContract.tags(metadata, artist: workspace.sessions[s].effectiveArtist(for: workspace.sessions[s].tracks[t]))
        let keys: [String: WritableKeyPath<TrackMetadata, String>] = ["title": \.title, "artist": \.artist, "album": \.album, "albumArtist": \.albumArtist, "year": \.year, "genre": \.genre]
        for (field, value) in candidate.tags where replaceExisting || effective[field] == nil {
            if let key = keys[field] { metadata[keyPath: key] = value }
        }
        workspace.sessions[s].tracks[t].supplied = metadata
        workspace.sessions[s].tracks[t].identification = .supplied
        workspace.sessions[s].tracks[t].aiReviewAppliedAt = Date()
        // Keep AI evidence in its review record; do not confuse recording metadata with a chosen release.
        workspace.sessions[s].updatedAt = Date()
        await persist()
    }

    private func index(for sessionID: UUID?) -> Int? { workspace.sessions.firstIndex { $0.id == (sessionID ?? workspace.selectedSessionID) } }
    private func persist() async {
        guard !persistenceFailed else { return }
        do { try await store.save(workspace) }
        catch { persistenceFailed = true; message = "Could not save locally: \(error.localizedDescription)" }
    }
}
