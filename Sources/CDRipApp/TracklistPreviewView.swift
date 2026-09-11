import SwiftUI
import CDRipCore

struct TracklistPreviewView: View {
    @Bindable var model: AppModel
    let session: RipSession
    let original: String
    let commonArtist: String
    let applied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [TracklistRow]
    @State private var saving = false
    @State private var writeFiles = true
    let parsingProblems: [String]
    init(model: AppModel, session: RipSession, preview: TracklistPreview, original: String, commonArtist: String, applied: @escaping () -> Void) {
        self.model = model; self.session = session; self.original = original; self.commonArtist = commonArtist; self.applied = applied
        _rows = State(initialValue: preview.rows)
        parsingProblems = preview.problems
    }
    private var issues: [String] {
        var result = TracklistParser.validate(rows, session: session)
        if session.disc.source == .optical, writeFiles, commonArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           rows.contains(where: { row in session.tracks.contains { $0.number == row.number } && row.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            result.append("Enter a shared artist or an artist for each selected track before saving files.")
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review tracklist mapping").font(.title2.bold())
            Text("Shared artist: \(commonArtist.isEmpty ? "not provided" : commonArtist). Numbers refer to physical CD tracks. Unselected rows remain in the original list only.")
                .font(.caption).foregroundStyle(Palette.muted)
            if !parsingProblems.isEmpty {
                Text("Parsing notes: " + parsingProblems.joined(separator: " ")).font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($rows) { $row in
                        HStack {
                            TextField("#", value: $row.number, format: .number).frame(width: 45)
                            TextField("Track artist (optional)", text: $row.artist).frame(width: 210)
                            TextField("Title", text: $row.title)
                            Text(session.tracks.contains { $0.number == row.number } ? "selected" : "skipped").font(.caption2).frame(width: 60)
                        }.textFieldStyle(.roundedBorder)
                    }
                }
            }.frame(height: 340)
            if !issues.isEmpty { Text(issues.joined(separator: "\n")).font(.caption).foregroundStyle(.orange) }
            if session.disc.source == .optical {
                Toggle("Write tags and rename extracted files when saving", isOn: $writeFiles).font(.callout)
                Text("Filename: Artist - Title.mp3 / .flac · no track-number prefix. Backups are kept; audio is not recompressed.").font(.caption).foregroundStyle(Palette.muted)
            }
            Text("Applying replaces the title and track artist for selected tracks. Other draft fields are preserved. This does not verify the list against the audio.")
                .font(.caption).foregroundStyle(Palette.muted)
            HStack {
                Button("Back to tracklist") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(session.disc.source == .optical && writeFiles ? "Save tags and filenames" : "Apply reviewed mapping") {
                    saving = true
                    Task {
                        await model.applyTracklist(rows, original: original, commonArtist: commonArtist, sessionID: session.id)
                        if !model.persistenceFailed, session.disc.source == .optical, writeFiles {
                            await model.saveTagsAndFilenames(sessionID: session.id, trackIDs: Set(session.tracks.map(\.id)))
                        }
                        saving = false
                        if !model.persistenceFailed { applied(); dismiss() }
                    }
                }.buttonStyle(GreenButtonStyle()).disabled(!issues.isEmpty || rows.isEmpty || saving || model.persistenceFailed)
            }
        }.padding(26).frame(width: 740).background(Palette.background)
    }
}
