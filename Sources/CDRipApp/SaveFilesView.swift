import SwiftUI
import CDRipCore

struct SaveFilesView: View {
    @Bindable var model: AppModel
    let sessionID: UUID
    var trackIDs: Set<String>? = nil
    @Environment(\.dismiss) private var dismiss
    private var session: RipSession? { model.workspace.sessions.first { $0.id == sessionID } }
    private var tracks: [SessionTrack] { session?.tracks.filter { trackIDs?.contains($0.id) ?? true } ?? [] }
    private var canSave: Bool {
        guard let session, !tracks.isEmpty, session.disc.source == .optical else { return false }
        return tracks.allSatisfy {
            let tags = model.effectiveFileTags($0, session: session)
            return model.mediaIssue(for: $0) == nil && !tags.artist.isEmpty && !tags.title.isEmpty && !$0.outputPaths.isEmpty && $0.phase == .awaitingVerification && $0.integrity?.readCompleted == true
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save all").font(.title2.bold())
            Text("Writes the approved artist, title and other draft fields into your MP3/FLAC files, then saves them in MP3 and FLAC subfolders of the output folder saved with this session. AI review and an album name are optional.").font(.callout).foregroundStyle(Palette.muted)
            ScrollView {
                if let session {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(tracks) { track in
                            let tags = model.effectiveFileTags(track, session: session)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Track \(track.number) · \(tags.artist) — \(tags.title)").font(.headline)
                                ForEach(track.outputPaths, id: \.self) { path in
                                    Text(URL(fileURLWithPath: path).lastPathComponent + " → " + model.fileSaveDestination(path, metadata: tags, session: session).path).font(.system(.caption, design: .monospaced))
                                }
                                if let issue = model.mediaIssue(for: track) { Text(issue).font(.caption).foregroundStyle(.orange) }
                                if let error = track.fileTagError { Text(error).font(.caption).foregroundStyle(.orange) }
                                if model.fileTagsAreCurrent(track, session: session) { Text("Already saved · unchanged files will be skipped").font(.caption).foregroundStyle(Palette.green) }
                            }
                            Divider()
                        }
                    }
                }
            }.frame(height: 340)
            Text("Track numbers are stored in tags, not filenames. Audio is verified without recompression. Backups and reports are kept in the application’s internal storage. This does not change the CD read-verification status.").font(.caption).foregroundStyle(Palette.muted)
            if !canSave { Text("Each track needs an artist, a title and completed extracted files before saving.").font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Back") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save all \(tracks.count) tracks") {
                    Task {
                        await model.saveTagsAndFilenames(sessionID: sessionID, trackIDs: Set(tracks.map(\.id)))
                        if model.isTagging { dismiss() }
                    }
                }.buttonStyle(GreenButtonStyle()).disabled(!canSave || model.isBusy || model.persistenceFailed)
            }
        }.task { await model.refreshMediaFiles(sessionID: sessionID) }.padding(26).frame(width: 820).background(Palette.background)
    }
}
