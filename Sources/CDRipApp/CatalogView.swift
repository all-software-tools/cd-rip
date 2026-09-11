import SwiftUI
import CDRipCore

struct CatalogView: View {
    @Bindable var model: AppModel
    let session: RipSession
    @Environment(\.dismiss) private var dismiss
    @State private var artist = ""
    @State private var album = ""
    @State private var results: [CatalogRelease] = []
    @State private var release: CatalogRelease?
    @State private var mediumPosition = 1
    @State private var cover: URL?
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @State private var lookupDiscID: String?
    private var medium: CatalogMedium? { release?.media?.first { $0.position == mediumPosition } }
    private var wrongDisc: Bool { lookupDiscID.map { medium?.contains(discID: $0) != true } ?? false }
    private var missing: [Int] { session.tracks.map(\.number).filter { n in !(medium?.tracks?.contains { $0.position == n } ?? false) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Find the album and release").font(.title2.bold())
                Spacer()
                Button("Close") { operation?.cancel(); dismiss() }
            }
            Text("MusicBrainz · catalog search, not audio recognition. Choose your CD’s release. Results will not overwrite drafts automatically.")
                .font(.caption).foregroundStyle(Palette.muted)
            if let optical = session.disc.optical {
                HStack {
                    Button("Find album from CD") { run {
                        results = []; release = nil; cover = nil; lookupDiscID = nil
                        let id = try MusicBrainzDiscID.calculate(optical)
                        let found = try await MusicCatalog().lookupDisc(optical)
                        try Task.checkCancellation()
                        lookupDiscID = id; results = found
                        message = found.isEmpty ? "No exact CD match in MusicBrainz. Search by artist/album or enter your tracklist." : "CD structure found. Choose and check the release; this does not verify the audio."
                    } }.disabled(operation != nil)
                    Text("Uses the saved full CD layout · no audio upload or new account").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            HStack {
                TextField("Artist (optional)", text: $artist)
                TextField("Album (optional)", text: $album)
                Button("Search") { run {
                    results = []; release = nil; cover = nil; lookupDiscID = nil
                    results = try await MusicCatalog().search(artist: artist, album: album)
                    release = nil; cover = nil
                    message = results.isEmpty ? "No results. Try different search terms." : "Up to 25 results. Add the album name to narrow your search."
                } }
            }.textFieldStyle(.roundedBorder).disabled(operation != nil)
            if operation != nil { HStack { ProgressView().controlSize(.small); Text("Loading…").font(.caption); Button("Cancel") { operation?.cancel() } } }
            if let message { Text(message).font(.caption).foregroundStyle(Palette.muted) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(results) { item in
                        Button { run {
                            release = nil; cover = nil
                            let detail = try await MusicCatalog().release(item.id)
                            try Task.checkCancellation()
                            if let lookupDiscID, detail.media?.contains(where: { $0.contains(discID: lookupDiscID) }) != true {
                                throw ConnectionError("This release no longer contains the matching CD layout. Please search again.")
                            }
                            release = detail
                            mediumPosition = detail.media?.first(where: { medium in lookupDiscID.map { medium.contains(discID: $0) } ?? true })?.position ?? 1
                        } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title + " · " + item.artist).font(.headline)
                                    Text(item.edition.isEmpty ? "Release date/country not listed" : item.edition).font(.caption).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                if release?.id == item.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green) }
                            }.padding(10).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(operation != nil)
                    }
                    if let release {
                        Divider()
                        HStack {
                            Text("Release: " + release.title).font(.headline)
                            Spacer()
                            Link("View source", destination: URL(string: "https://musicbrainz.org/release/\(release.id)")!)
                        }
                        Picker("Disc in release", selection: $mediumPosition) {
                            ForEach(release.media ?? []) { medium in
                                Text("Disc \(medium.position) · \(medium.format ?? "unknown format") · \(medium.tracks?.count ?? 0) tracks").tag(medium.position)
                            }
                        }.disabled(operation != nil)
                        if let medium {
                            Text("Local CD: \(session.disc.tracks.count) tracks · release: \(medium.tracks?.count ?? 0) tracks. Durations are clues, not audio verification.")
                                .font(.caption).foregroundStyle(Palette.muted)
                            ForEach(medium.tracks ?? []) { track in
                                HStack {
                                    Text(String(format: "%02d", track.position)).monospacedDigit().frame(width: 28)
                                    Text(track.artist(albumArtist: release.artist) + " — " + track.trackTitle).lineLimit(1)
                                    Spacer()
                                    if let length = track.duration { Text(duration(length)).monospacedDigit() }
                                    if let local = session.tracks.first(where: { $0.number == track.position }), let length = track.duration {
                                        Text(String(format: "Δ %.1fs", abs(local.duration - length))).foregroundStyle(abs(local.duration - length) > 3 ? .orange : Palette.muted)
                                    }
                                }.font(.caption)
                            }
                        }
                        HStack {
                            if let cover, let image = NSImage(contentsOf: cover) { Image(nsImage: image).resizable().scaledToFit().frame(width: 100, height: 100) }
                            Button("Find release cover") { run {
                                let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CDRip/Covers")
                                cover = try await MusicCatalog().cover(releaseID: release.id, directory: directory)
                            } }.disabled(operation != nil)
                            Text("JPEG/PNG · maximum 8 MB · front cover").font(.caption2).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }.frame(height: 400)
            if !missing.isEmpty && release != nil { Text("This release is missing selected tracks: \(missing.map(String.init).joined(separator: ", ")).").font(.caption).foregroundStyle(.orange) }
            if wrongDisc && release != nil { Text("Choose a disc whose layout matches your CD.").font(.caption).foregroundStyle(.orange) }
            Button("Save release as a proposal for review") {
                guard let release, let medium else { return }
                run {
                    await model.proposeCatalog(release, medium: medium, cover: cover, sessionID: session.id)
                    if !model.persistenceFailed { dismiss() }
                }
            }.buttonStyle(GreenButtonStyle()).disabled(release == nil || medium == nil || !missing.isEmpty || wrongDisc || operation != nil || model.persistenceFailed)
        }.padding(26).frame(width: 830).background(Palette.background)
            .onAppear { artist = session.commonArtist ?? session.tracks.first?.supplied.artist ?? ""; album = session.tracks.first?.supplied.album ?? "" }
            .onDisappear { operation?.cancel() }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        message = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            do { try await action() }
            catch is CancellationError { message = "Operation cancelled." }
            catch { message = error.localizedDescription }
        }
    }
}
