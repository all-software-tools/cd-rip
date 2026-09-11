import SwiftUI
import CDRipCore

struct CoverImportView: View {
    @Bindable var model: AppModel
    let sessionID: UUID
    let trackID: String?
    var initialURL: String = ""
    var initialSourceURL: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var page: CoverPage?
    @State private var selected = ""
    @State private var preview: ImportedCover?
    @State private var allTracks = true
    @State private var replaceExisting = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    private var session: RipSession? { model.workspace.sessions.first { $0.id == sessionID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Import cover from URL").font(.title2.bold())
                Spacer()
                Button("Close") { operation?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Paste an album page or a direct image link. Preview the image and check that it belongs to your CD edition before applying it.").font(.callout).foregroundStyle(Palette.muted)
            HStack {
                TextField("https://… page or image URL", text: $address).textFieldStyle(.roundedBorder)
                Button("Find images") { run {
                    page = nil; preview = nil; selected = ""
                    let found = try await CoverImportService().discover(address)
                    try Task.checkCancellation()
                    page = found; selected = found.candidates.first?.id ?? ""
                    message = "Found \(found.candidates.count) image links. Select one and load its preview; pages may include unrelated images."
                } }.disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(operation != nil)
            if let page {
                Picker("Image", selection: $selected) {
                    ForEach(Array(page.candidates.enumerated()), id: \.element.id) { index, candidate in
                        Text("\(index + 1). \(candidate.label) · \(candidate.url.lastPathComponent)").tag(candidate.id)
                    }
                }.disabled(operation != nil)
                HStack {
                    Link("Open source page", destination: page.url)
                    if let candidate = page.candidates.first(where: { $0.id == selected }) {
                        Link("Open image", destination: candidate.url)
                        Spacer()
                        Button("Load preview") { run {
                            preview = nil
                            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CDRip/Covers")
                            let imported = try await CoverImportService().download(candidate, pageURL: address == initialURL ? (URL(string: initialSourceURL) ?? page.url) : page.url, directory: root)
                            try Task.checkCancellation()
                            preview = imported
                            message = "Preview ready. Applying saves the cover to drafts; Preview tag writing embeds it into MP3/FLAC copies."
                        } }.disabled(operation != nil)
                    }
                }.font(.caption)
            }
            if operation != nil { HStack { ProgressView().controlSize(.small); Text("Loading…"); Button("Cancel") { operation?.cancel() } }.font(.caption) }
            if let message { Text(message).font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
            Group {
                if let preview, let image = NSImage(contentsOfFile: preview.filePath) {
                    VStack {
                        Image(nsImage: image).resizable().scaledToFit()
                        Text("\(preview.width) × \(preview.height) · JPEG · source URL saved").font(.caption).foregroundStyle(Palette.muted)
                    }
                } else { Text("Image preview").foregroundStyle(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(height: 265).frame(maxWidth: .infinity)
            Text("JPEG / PNG / WebP downloads · saved as JPEG · maximum 8 MB. No album or song identity is inferred from the image.").font(.caption2).foregroundStyle(Palette.muted)
            Divider()
            HStack {
                VStack(alignment: .leading) {
                    Toggle("Apply to all \(session?.tracks.count ?? 0) tracks", isOn: $allTracks)
                    Toggle("Replace existing covers too", isOn: $replaceExisting)
                }.font(.caption).disabled(operation != nil)
                Spacer()
                Button("Apply cover to drafts") {
                    guard let preview, let session else { return }
                    let ids = allTracks ? Set(session.tracks.map(\.id)) : Set([trackID].compactMap { $0 })
                    run {
                        await model.applyImportedCover(preview, sessionID: sessionID, trackIDs: ids, replaceExisting: replaceExisting)
                        if !model.persistenceFailed { dismiss() }
                    }
                }.buttonStyle(GreenButtonStyle()).disabled(preview == nil || operation != nil || model.isBusy || model.persistenceFailed || (!allTracks && trackID == nil))
            }
        }.padding(26).frame(width: 780, height: 690).background(Palette.background)
            .onAppear {
                address = initialURL
                if initialURL.isEmpty, let existing = session?.tracks.first(where: { $0.id == trackID })?.coverImport {
                    preview = existing; address = existing.pageURL
                }
            }
            .onChange(of: selected) { preview = nil }
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
