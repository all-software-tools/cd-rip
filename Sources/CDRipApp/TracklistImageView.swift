import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CDRipCore

struct TracklistImageView: View {
    @Bindable var model: AppModel
    let sessionID: UUID
    var applied: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDisc = -1
    @State private var rows: [OCRMusicRow] = []
    @State private var confirmed: Set<Int> = []
    @State private var sharedArtist = ""
    @State private var discConfirmed = false
    @State private var saving = false
    @State private var pendingImage: URL?
    @State private var leftEdge = 0.0
    @State private var rightEdge = 1.0
    private var session: RipSession? { model.workspace.sessions.first { $0.id == sessionID } }
    private var result: OCRTracklistResult? { model.ocrResult?.sessionID == sessionID ? model.ocrResult : nil }
    private var issues: [String] {
        guard let session else { return ["Session unavailable."] }
        var result = TracklistOCRContract.issues(rows, session: session, sharedArtist: sharedArtist)
        if let live = model.disc, live.source == .optical, live.id != session.disc.id {
            result.append("The CD in the drive differs from this rip session. Select the matching session before applying.")
        }
        return result
    }
    private var canApply: Bool { selectedDisc >= 0 && !rows.isEmpty && issues.isEmpty && confirmed.count == rows.count && discConfirmed && !model.isBusy && !saving && !model.persistenceFailed }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Read and validate a tracklist image").font(.title2.bold())
                Spacer()
                Button("Close") { if model.isReadingTracklistImage { model.cancel() }; dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
            }
            Text("OCR reads the print; AI separates the CDs. You select the ripped CD and confirm every artist/title. Names cannot be verified from CD audio by this step.").font(.callout).foregroundStyle(Palette.muted)
            HStack {
                Button("Choose image…") { chooseImage() }.disabled(model.isBusy || saving)
                if let session { Text("Ripped CD: \(session.disc.tracks.count) physical tracks · \(session.tracks.count) extracted").font(.caption) }
                Spacer()
                if model.isReadingTracklistImage {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                }
            }
            if let url = pendingImage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select the CD column before reading, or keep the whole image.").font(.callout)
                    if let image = NSImage(contentsOf: url) {
                        let width = min(760.0, 250.0 * image.size.width / max(1, image.size.height))
                        Image(nsImage: image).resizable().frame(width: width, height: 250)
                            .overlay(alignment: .leading) { Color.black.opacity(0.65).frame(width: width * leftEdge) }
                            .overlay(alignment: .trailing) { Color.black.opacity(0.65).frame(width: width * (1 - rightEdge)) }
                    }
                    HStack {
                        Text("Left edge").frame(width: 70)
                        Slider(value: $leftEdge, in: 0...0.95).onChange(of: leftEdge) { rightEdge = max(rightEdge, leftEdge + 0.05) }
                        Text("\(Int(leftEdge * 100))%").monospacedDigit().frame(width: 40)
                        Text("Right edge").frame(width: 75)
                        Slider(value: $rightEdge, in: 0.05...1).onChange(of: rightEdge) { leftEdge = min(leftEdge, rightEdge - 0.05) }
                        Text("\(Int(rightEdge * 100))%").monospacedDigit().frame(width: 40)
                    }
                    HStack {
                        Button("Whole image") { leftEdge = 0; rightEdge = 1 }
                        Button("Open full-size image") { NSWorkspace.shared.open(url) }
                        Button("Read selected area with AI") {
                            Task { await model.readTracklistImage(url, sessionID: sessionID, horizontalRange: leftEdge...rightEdge) }
                            pendingImage = nil
                        }.buttonStyle(GreenButtonStyle())
                        Button("Cancel selection") { pendingImage = nil }
                    }
                    Text("Keep every artist, title and track number inside the bright area. The original photo is unchanged.").font(.caption).foregroundStyle(Palette.muted)
                }.disabled(model.isBusy)
            }
            if !model.ocrProgress.isEmpty { Text(model.ocrProgress).font(.caption).foregroundStyle(Palette.muted) }
            if let error = model.ocrError {
                Text(error).font(.caption).foregroundStyle(.orange)
                if model.canRetryTracklistImage(sessionID: sessionID) {
                    Button("Retry AI grouping — reuse recognized text") { Task { await model.retryTracklistImage(sessionID: sessionID) } }
                }
            }
            if !model.ocrText.isEmpty, result == nil {
                DisclosureGroup("Recognized text (available even if AI grouping fails)") {
                    ScrollView { Text(model.ocrText).font(.caption).textSelection(.enabled) }.frame(height: 120)
                    Button("Copy text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.ocrText, forType: .string) }
                }
            }
            if let result {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading) {
                        if let image = NSImage(contentsOfFile: result.imagePath) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 240, height: 220)
                        }
                        Button("Open full-size image") { NSWorkspace.shared.open(URL(fileURLWithPath: result.imagePath)) }
                        DisclosureGroup("Raw OCR text") {
                            ScrollView { Text(result.lines.map { "\($0.id). \($0.text)" }.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(height: 230)
                        }
                    }.frame(width: 240)
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("CD in the image", selection: $selectedDisc) {
                            Text("Choose the CD you ripped…").tag(-1)
                            ForEach(result.discs.indices, id: \.self) { index in
                                Text("\(result.discs[index].label) · \(result.discs[index].tracks.count) tracks").tag(index)
                            }
                        }.disabled(model.isBusy)
                        TextField("Shared artist (optional)", text: $sharedArtist).textFieldStyle(.roundedBorder)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(rows.indices, id: \.self) { index in rowEditor(index, result: result) }
                            }
                        }.frame(height: 330)
                        if selectedDisc >= 0 {
                            Button("Add missing row") {
                                let missing = Set(session?.disc.tracks.map(\.number) ?? []).subtracting(rows.map(\.number)).sorted().first ?? rows.count + 1
                                rows.append(.init(number: missing, artist: "", title: "", duration: nil, sourceLineIDs: [], uncertainty: "Manually entered — verify against the image."))
                                confirmed = []; discConfirmed = false
                            }
                            Toggle("This is the CD I ripped, not another disc in the collection", isOn: $discConfirmed).font(.caption)
                        }
                        if !issues.isEmpty, selectedDisc >= 0 { Text(issues.joined(separator: "\n")).font(.caption).foregroundStyle(.orange) }
                    }
                }.disabled(model.isBusy || saving)
            } else if pendingImage == nil {
                Text("Choose a clear photo or scan of the back cover or booklet. Images containing multiple CD tracklists are supported.").foregroundStyle(Palette.muted).frame(maxWidth: .infinity, minHeight: 280)
            }
            Text("No automatic approval: check every row against the image. Matching track counts alone do not identify a CD. Applying changes drafts only; use Save all afterwards to write audio tags.").font(.caption).foregroundStyle(Palette.muted)
            HStack {
                Text("Confirmed: \(confirmed.count) / \(rows.count)").font(.caption)
                Spacer()
                Button("Apply confirmed tracklist to drafts") { apply() }.buttonStyle(GreenButtonStyle()).disabled(!canApply)
            }
        }.padding(24).frame(width: 1050).background(Palette.background)
            .onChange(of: selectedDisc) {
                rows = result.flatMap { $0.discs.indices.contains(selectedDisc) ? $0.discs[selectedDisc].tracks : nil } ?? []
                confirmed = []; discConfirmed = false
            }
            .onChange(of: result) { selectedDisc = -1; rows = []; confirmed = []; discConfirmed = false }
            .onChange(of: sharedArtist) { confirmed = [] }
    }
    @ViewBuilder private func rowEditor(_ index: Int, result: OCRTracklistResult) -> some View {
        if rows.indices.contains(index) {
        let row = rows[index]
        let binding = Binding<OCRMusicRow>(get: { rows.indices.contains(index) ? rows[index] : row }, set: { value in
            guard rows.indices.contains(index) else { return }
            rows[index] = value; confirmed.remove(index); discConfirmed = false
        })
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                TextField("#", value: binding.number, format: .number).frame(width: 40)
                TextField("Artist", text: binding.artist).frame(width: 175)
                TextField("Title", text: binding.title)
                Button { guard rows.indices.contains(index) else { return }; rows.remove(at: index); confirmed = []; discConfirmed = false } label: { Image(systemName: "trash") }.help("Remove this row")
                Toggle("Checked", isOn: Binding(get: { confirmed.contains(index) }, set: { if $0 { confirmed.insert(index) } else { confirmed.remove(index) } })).toggleStyle(.checkbox).font(.caption)
            }.textFieldStyle(.roundedBorder)
            let sources = result.lines.filter { row.sourceLineIDs.contains($0.id) }
            Text("Image text: " + (sources.isEmpty ? "manually entered" : sources.map(\.text).joined(separator: " | "))).font(.caption2).foregroundStyle(Palette.muted).textSelection(.enabled)
            if let track = session?.disc.tracks.first(where: { $0.number == row.number }) {
                let printed = TracklistOCRContract.seconds(row.duration)
                let mismatch = printed.map { abs(Double($0) - track.duration) > 3 } ?? false
                Text("CD: \(Int(track.duration) / 60):\(String(format: "%02d", Int(track.duration) % 60)) · printed: \(row.duration ?? "not available")" + (mismatch ? " · duration differs — check version and CD selection" : ""))
                    .font(.caption2).foregroundStyle(mismatch ? .orange : Palette.muted)
            }
            if !row.uncertainty.isEmpty { Text(row.uncertainty).font(.caption2).foregroundStyle(.orange) }
            if sources.contains(where: { $0.confidence < 0.8 }) { Text("Low OCR confidence — inspect the image carefully.").font(.caption2).foregroundStyle(.orange) }
            Divider()
        }
        }
    }
    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { pendingImage = url; leftEdge = 0; rightEdge = 1; model.clearTracklistImagePreview() }
    }
    private func apply() {
        guard canApply else { return }
        saving = true
        let mapping = rows.enumerated().map { TracklistRow(line: $0.offset + 1, number: $0.element.number, artist: $0.element.artist, title: $0.element.title) }
        let text = rows.map { "\($0.number). \($0.artist.isEmpty ? sharedArtist : $0.artist) — \($0.title)" }.joined(separator: "\n")
        Task {
            await model.applyTracklist(mapping, original: text, commonArtist: sharedArtist, sessionID: sessionID)
            saving = false
            if !model.persistenceFailed { applied(); dismiss() }
        }
    }
}
