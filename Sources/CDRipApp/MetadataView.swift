import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CDRipCore

private struct MetadataPresentation: Identifiable {
    let id = UUID()
    enum Content {
        case tracklist(RipSession, TracklistPreview, String, String)
        case catalog(RipSession)
        case ai(UUID)
        case cover(UUID)
        case saveFiles(UUID)
        case imageTracklist(UUID)
        case tags(RipSession, SessionTrack, TrackMetadata)
    }
    let content: Content
}

struct MetadataWorkspace: View {
    @Bindable var model: AppModel
    @State private var tracklist = ""
    @State private var format: TracklistFormat = .titles
    @State private var presentation: MetadataPresentation?
    @State private var commonArtist = ""
    @State private var draft = TrackMetadata()
    @State private var editingTrackID: String?
    @State private var editingSessionID: UUID?
    @State private var dirty = false
    @State private var pendingTrackID: String?
    @State private var confirmDiscard = false
    var body: some View {
        ZStack {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Give your music a name.").font(.system(size: 31, weight: .semibold, design: .rounded))
                    Text("Tracklist, identification and review — after extraction.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Text("02 / 03").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            if let session = model.currentSession {
                HStack(spacing: 10) {
                    Label(session.outputProfile.title, systemImage: "waveform").font(.caption)
                    Text("· \(session.tracks.count) tracks · " + (session.disc.source == .demonstration ? "simulation without audio" : "AccurateRip not checked")).font(.caption).foregroundStyle(Palette.muted)
                }
                Text("Session output: " + session.destinationPath).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A  ADD TRACKLIST").eyebrow()
                        TextField("Shared artist (optional) · e.g. Queen", text: $commonArtist)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        Picker("Format", selection: $format) {
                            ForEach(TracklistFormat.allCases) { Text($0.title).tag($0) }
                        }.font(.caption)
                        TextEditor(text: $tracklist).font(.system(size: 11, design: .monospaced))
                            .scrollContentBackground(.hidden).frame(height: 90).padding(8)
                            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Text("You can enter titles only; the shared artist is stored separately.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                            Spacer()
                            Button("Preview") {
                                presentTracklist(session)
                            }.font(.caption).disabled(tracklist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dirty)
                        }
                        Button("Import tracklist from image…") { presentation = .init(content: .imageTracklist(session.id)) }.disabled(dirty)
                        Button("Save all") {
                            let value = draft; let id = editingTrackID; let sid = editingSessionID
                            Task {
                                if dirty, let id { await model.saveMetadata(value, trackID: id, sessionID: sid); dirty = false }
                                if !model.persistenceFailed { presentation = .init(content: .saveFiles(session.id)) }
                            }
                        }
                            .disabled(session.disc.source != .optical || session.tracks.allSatisfy { $0.outputPaths.isEmpty })
                    }.card().frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("B  IDENTIFY AND COMPLETE").eyebrow()
                        Text("Complete and review your metadata.").font(.system(size: 16, weight: .medium))
                        Text("Let Codex or Claude search the web for track metadata, album editions and covers. Review filled fields and images before saving audio files.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                        Button("Find album / cover in catalog") { presentation = .init(content: .catalog(session)) }
                        Button("Import cover from URL") { presentation = .init(content: .cover(session.id)) }.disabled(dirty)
                        Button("Find metadata for all songs with AI") {
                            let value = draft; let id = editingTrackID; let sid = editingSessionID
                            Task {
                                if dirty, let id { await model.saveMetadata(value, trackID: id, sessionID: sid); dirty = false }
                                if !model.persistenceFailed { await model.findAllSongMetadata(sessionID: session.id) }
                            }
                        }.disabled(model.isTestingConnection)
                        Text("Fills missing fields and artwork for every song. Completed songs are skipped. Review, then Save all.").font(.caption).foregroundStyle(Palette.muted)
                        Button("Identify by audio") {}.disabled(true)
                        Text(model.isReviewingAI ? model.aiProgressText : "CLI web research enabled. Audio recognition is not configured.").font(.system(size: 9)).foregroundStyle(Palette.muted)
                    }.card().frame(maxWidth: .infinity)
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("TRACK REVIEW").eyebrow()
                        ForEach(session.tracks) { track in
                            Button { select(track.id) } label: {
                                HStack(spacing: 12) {
                                    Text(String(format: "%02d", track.number)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.supplied.title.isEmpty ? "Track \(track.number)" : track.supplied.title).font(.system(size: 12)).lineLimit(1)
                                        Text(session.effectiveArtist(for: track).isEmpty ? "Artist not provided" : session.effectiveArtist(for: track)).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 5) {
                                        Text(model.mediaIssue(for: track) != nil ? "File needs attention" : model.fileTagsAreCurrent(track, session: session) ? "Tags saved" : "Tags not saved").foregroundStyle(model.fileTagsAreCurrent(track, session: session) ? Palette.green : .orange)
                                        Text(reviewLabel(track, session: session)).foregroundStyle(track.aiReview?.decision.status == .conflict ? .orange : Palette.muted)
                                    }.font(.system(size: 9))
                                }.padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.selectedTrackID == track.id ? Palette.green.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.card().frame(maxWidth: .infinity)
                    editor.frame(width: 300)
                }
            } else {
                ContentUnavailableView("Start a session", systemImage: "tag", description: Text("Choose an output folder and start extraction. You can then add metadata."))
            }
        }
        .disabled(model.isBusy || model.persistenceFailed)
        }
        .sheet(item: $presentation) { item in
            switch item.content {
            case let .imageTracklist(sessionID):
                TracklistImageView(model: model, sessionID: sessionID) { format = .artistTitle; loadSession() }
            case let .saveFiles(sessionID):
                SaveFilesView(model: model, sessionID: sessionID)
            case let .cover(sessionID):
                CoverImportView(model: model, sessionID: sessionID, trackID: model.selectedTrackID)
            case let .ai(sessionID):
                AIMetadataView(model: model, sessionID: sessionID)
            case let .tags(session, track, metadata):
                TagPreview(model: model, session: session, track: track, metadata: metadata)
            case let .catalog(session):
                CatalogView(model: model, session: session)
            case let .tracklist(session, preview, original, artist):
                TracklistPreviewView(model: model, session: session, preview: preview, original: original, commonArtist: artist) {
                    if let id = editingTrackID { loadTrack(id) }
                }
            }
        }
        .onAppear {
            loadSession()
            if CommandLine.arguments.contains("--snapshot-tracklist-image"), let session = model.currentSession { presentation = .init(content: .imageTracklist(session.id)) }
            if CommandLine.arguments.contains("--snapshot-cover"), let session = model.currentSession {
                presentation = .init(content: .cover(session.id))
            }
            if CommandLine.arguments.contains("--snapshot-save-files"), let session = model.currentSession { presentation = .init(content: .saveFiles(session.id)) }
            if CommandLine.arguments.contains("--snapshot-ai"), let session = model.currentSession {
                presentation = .init(content: .ai(session.id))
            }
            if CommandLine.arguments.contains("--snapshot-tracklist"), let session = model.currentSession {
                format = .artistTitle
                presentTracklist(session)
            }
        }
        .onChange(of: model.selectedTrack?.supplied) { if !dirty, let id = model.selectedTrackID { loadTrack(id) } }
        .onChange(of: model.selectedTrack?.coverImport) { if !dirty, let id = model.selectedTrackID { loadTrack(id) } }
        .onChange(of: model.selectedTrack?.aiReviewAppliedAt) { _, _ in if let id = model.selectedTrackID { loadTrack(id) } }
        .onChange(of: model.selectedTrack?.tagRevisions?.count) { _, _ in if let id = model.selectedTrackID { loadTrack(id) } }
        .onChange(of: model.workspace.selectedSessionID) { _, _ in saveOnNavigation(); loadSession() }
        .onDisappear { saveOnNavigation() }
        .onChange(of: tracklist) { _, value in
            guard value != model.currentSession?.tracklist else { return }
            let sessionID = editingSessionID
            Task { await model.saveTracklist(value, sessionID: sessionID) }
        }
        .onChange(of: commonArtist) { _, value in
            guard value != (model.currentSession?.commonArtist ?? "") else { return }
            let sessionID = editingSessionID
            Task { await model.saveCommonArtist(value, sessionID: sessionID) }
        }
        .confirmationDialog("Discard this track’s unsaved changes?", isPresented: $confirmDiscard) {
            Button("Discard changes", role: .destructive) {
                if let id = editingTrackID, let sid = editingSessionID { model.discardMetadataEdit(trackID: id, sessionID: sid) }
                if let pendingTrackID { loadTrack(pendingTrackID) }
            }
            Button("Keep editing", role: .cancel) { pendingTrackID = nil }
        }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("METADATA DRAFT").eyebrow()
            if let track = model.selectedTrack {
                Text("Track \(track.number)").font(.headline)
                Text(track.phase.label).font(.caption).foregroundStyle(.orange)
                if let error = track.error { Text(error).font(.caption2).foregroundStyle(.orange) }
                if let integrity = track.integrity {
                    Text("Paranoia read completed · audio needs review. AccurateRip not checked; offset not calibrated.").font(.caption2).foregroundStyle(.orange)
                    Button("Show audio and report") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: integrity.logPath)]) }.font(.caption)
                }
                if !track.evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Catalog proposal · " + track.identification.label).font(.caption).foregroundStyle(.orange)
                        Text(track.proposed.artist + " — " + track.proposed.title).font(.caption)
                        Text(track.proposed.album + " · " + track.proposed.year).font(.caption2).foregroundStyle(Palette.muted)
                        if let source = track.evidence.first?.sourceURL, let url = URL(string: source) { Link("Metadata source", destination: url).font(.caption2) }
                        Button("Fill empty draft fields") {
                            for key in [\TrackMetadata.title, \.artist, \.album, \.albumArtist, \.year, \.genre] where draft[keyPath: key].isEmpty {
                                draft[keyPath: key] = track.proposed[keyPath: key]
                            }
                            if draft.coverPath == nil { draft.coverPath = track.proposed.coverPath }
                            markDraftChanged()
                        }.font(.caption2)
                    }
                    Divider()
                }
                Button("Find metadata with AI") {
                    let value = draft; let id = track.id; let sessionID = editingSessionID
                    Task {
                        await model.saveMetadata(value, trackID: id, sessionID: sessionID)
                        if !model.persistenceFailed, let sessionID { dirty = false; await model.findSongMetadata(trackID: id, sessionID: sessionID) }
                    }
                }.buttonStyle(GreenButtonStyle()).disabled(model.isTestingConnection)
                Text("Uses artist and title to fill missing year, genre, album and artwork. Existing values are kept. Review, then Save.").font(.caption).foregroundStyle(Palette.muted)
                if let review = track.aiReview, review.promptVersion == AIWebMetadataContract.songVersion {
                    DisclosureGroup("AI sources and notes") {
                        Text(review.decision.explanation).font(.caption).textSelection(.enabled)
                        ForEach(review.decision.conflicts, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        ForEach(review.candidate?.evidence ?? [], id: \.id) { evidence in
                            if let address = evidence.sourceURL, let url = URL(string: address) { Link(evidence.provider, destination: url).font(.caption) }
                        }
                        if let imported = track.coverImport, let proposal = review.webCovers?.first(where: { $0.imageURL == imported.imageURL }) {
                            Text(proposal.description).font(.caption)
                        }
                    }
                    if track.supplied.coverPath == nil { Text("No image found. Choose a cover manually if needed.").font(.caption).foregroundStyle(Palette.muted) }
                }
                if let error = track.aiError { Text(error).font(.caption).foregroundStyle(.orange) }
                field("Title", \.title)
                field("Artist", \.artist)
                if !(model.currentSession?.commonArtist ?? "").isEmpty {
                    Text("If Artist is blank, use: \(model.currentSession?.commonArtist ?? ""). The track artist takes priority.")
                        .font(.system(size: 9)).foregroundStyle(Palette.green)
                }
                field("Album", \.album)
                field("Album artist", \.albumArtist)
                HStack { field("Year", \.year); field("Genre / style", \.genre) }
                HStack(spacing: 12) {
                    Group {
                        if let path = draft.coverPath, let image = NSImage(contentsOfFile: path) {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else { Image(systemName: "photo").font(.title2).foregroundStyle(Palette.muted) }
                    }.frame(width: 54, height: 54).background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Choose cover…", action: chooseCover).font(.caption)
                        if draft.coverPath != nil { Button("Remove") { draft.coverPath = nil; markDraftChanged() }.font(.caption2) }
                    }
                }
                Button(dirty ? "Save to audio files *" : "Save to audio files") {
                    let value = draft; let id = track.id; let sessionID = editingSessionID
                    Task {
                        await model.saveMetadata(value, trackID: id, sessionID: sessionID)
                        if !model.persistenceFailed, let sessionID { dirty = false; await model.saveTagsAndFilenames(sessionID: sessionID, trackIDs: [id]) }
                    }
                }.buttonStyle(GreenButtonStyle())
                Button("Save all") {
                    let value = draft; let id = track.id; let sessionID = editingSessionID
                    Task {
                        await model.saveMetadata(value, trackID: id, sessionID: sessionID)
                        if !model.persistenceFailed, let sessionID { dirty = false; presentation = .init(content: .saveFiles(sessionID)) }
                    }
                }.buttonStyle(GreenButtonStyle())
                if let session = model.currentSession {
                    var tags = draft
                    let _ = { if tags.artist.isEmpty { tags.artist = session.commonArtist ?? "" } }()
                    Text(FileTagSaver.filename(metadata: tags, extension: "mp3")).font(.system(size: 9, design: .monospaced))
                }
                Text("Save writes tags and renames this track’s files. Navigating away keeps a draft only. Use Save all to save every track.")
                    .font(.system(size: 9)).foregroundStyle(Palette.muted).lineSpacing(3)
                Button("Show current files") { NSWorkspace.shared.activateFileViewerSelecting(track.outputPaths.map { URL(fileURLWithPath: $0) }) }.disabled(track.outputPaths.isEmpty)
                if let error = track.fileTagError { Text(error).font(.caption).foregroundStyle(.orange) }
                if let revisions = track.tagRevisions, !revisions.isEmpty {
                    Text("Saved versions · originals preserved").font(.caption2).foregroundStyle(Palette.muted)
                    ForEach(Array(revisions.enumerated()), id: \.element.id) { index, revision in
                        Button("Show version \(index + 1) · \(revision.createdAt.formatted(date: .omitted, time: .shortened))") {
                            NSWorkspace.shared.activateFileViewerSelecting(revision.outputPaths.map { URL(fileURLWithPath: $0) })
                        }.font(.caption2)
                    }
                }
            }
        }.card()
    }
    private func reviewLabel(_ track: SessionTrack, session: RipSession) -> String {
        if track.aiError != nil { return model.aiReviewLabel(track, session: session) }
        if let review = track.aiReview, model.aiReviewIsCurrent(track, session: session) { return review.decision.status.title }
        return track.identification.label
    }
    private func presentTracklist(_ session: RipSession) {
        presentation = .init(content: .tracklist(session, TracklistParser.parse(tracklist, format: format, session: session), tracklist, commonArtist))
    }
    private func field(_ title: String, _ key: WritableKeyPath<TrackMetadata, String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(Palette.muted)
            TextField(title, text: Binding(get: { draft[keyPath: key] }, set: { draft[keyPath: key] = $0; markDraftChanged() })).textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
    }
    private func markDraftChanged() {
        dirty = true
        if let id = editingTrackID, let sid = editingSessionID { model.stageMetadataEdit(draft, trackID: id, sessionID: sid) }
    }
    private func select(_ id: String) {
        guard id != editingTrackID else { return }
        if dirty { pendingTrackID = id; confirmDiscard = true }
        else { loadTrack(id) }
    }
    private func loadTrack(_ id: String) {
        model.selectedTrackID = id; editingTrackID = id; draft = model.selectedTrack?.supplied ?? TrackMetadata(); dirty = false
    }
    private func loadSession() {
        editingSessionID = model.workspace.selectedSessionID
        tracklist = model.currentSession?.tracklist ?? ""
        commonArtist = model.currentSession?.commonArtist ?? ""
        if let id = model.selectedTrackID ?? model.currentSession?.tracks.first?.id { loadTrack(id) }
    }
    private func saveOnNavigation() {
        guard dirty, let id = editingTrackID, let sessionID = editingSessionID else { return }
        let value = draft
        Task { await model.saveMetadata(value, trackID: id, sessionID: sessionID) }
    }
    private func chooseCover() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg, .png]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            guard size <= 12 * 1024 * 1024, NSImage(contentsOf: url) != nil else {
                model.message = "Choose a valid JPEG/PNG image no larger than 12 MB."; return
            }
            draft.coverPath = url.path; markDraftChanged()
        }
    }
}

struct TagPreview: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let session: RipSession
    let track: SessionTrack
    let metadata: TrackMetadata
    private var effective: TrackMetadata {
        var value = metadata
        if value.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.artist = session.commonArtist ?? "" }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Write tags to new copies").font(.title2.bold())
            Text("Originals and previous versions remain available. Audio must remain identical; the “Needs review” status is preserved.").font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading) {
                GridRow { Text("Artist"); Text(effective.artist) }
                GridRow { Text("Title"); Text(effective.title) }
                GridRow { Text("Album"); Text(effective.album) }
                GridRow { Text("Album artist"); Text(effective.albumArtist) }
                GridRow { Text("Year / genre"); Text(effective.year + " / " + effective.genre) }
                GridRow { Text("Track / disc"); Text("\(track.number)/\(session.disc.tracks.count) · \(effective.discNumber)/\(effective.discTotal)") }
                GridRow { Text("Cover"); Text(effective.coverPath == nil ? "No cover" : URL(fileURLWithPath: effective.coverPath!).lastPathComponent) }
            }.font(.callout)
            Divider()
            ForEach(track.outputPaths, id: \.self) { path in
                Text(AudioTagWriter.relativePath(metadata: effective, number: track.number, extension: URL(fileURLWithPath: path).pathExtension))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            HStack {
                Button("Back") { dismiss() }
                Spacer()
                Button("Write tagged copies") {
                    Task { await model.writeTags(metadata: metadata, trackID: track.id, sessionID: session.id) }
                    dismiss()
                }.buttonStyle(GreenButtonStyle()).disabled(effective.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || effective.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 640)
    }
}
