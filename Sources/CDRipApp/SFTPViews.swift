import SwiftUI
import CDRipCore

struct SFTPSettingsFields: View {
    @Binding var settings: SFTPSettings
    @State private var password = ""
    @State private var candidate: String?
    @State private var candidateEndpoint = ""
    @State private var status = ""
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SFTP upload (optional)").eyebrow()
            TextField("Server hostname", text: $settings.host)
            HStack {
                TextField("Username", text: $settings.username)
                Text("Port")
                TextField("22", value: $settings.port, format: .number).frame(width: 80)
            }
            TextField("Remote folder, e.g. /music", text: $settings.remoteDirectory)
            Toggle("Authenticate with a password", isOn: $settings.usePassword)
            if settings.usePassword {
                SecureField("New password (blank keeps saved password)", text: $password)
                Text("macOS may ask you to allow Keychain access when connecting.").font(.caption).foregroundStyle(Palette.muted)
                Button("Store password in Keychain") {
                    do { try SFTPPassword.save(password, settings: settings); password = ""; status = "Password stored in macOS Keychain." }
                    catch { status = error.localizedDescription }
                }.disabled(password.isEmpty)
            } else {
                TextField("SSH private-key path (optional; blank uses SSH agent/default keys)", text: $settings.identityFile)
                Text("Unlock encrypted keys in your SSH agent before connecting.").font(.caption).foregroundStyle(Palette.muted)
            }
            HStack {
                Button("Fetch server fingerprint") { run(fetch: true) }
                Button("Test SFTP connection") { run(fetch: false) }
                if task != nil { ProgressView().controlSize(.small) }
            }.disabled(task != nil)
            if let candidate, candidateEndpoint == settings.endpoint, let fingerprint = SFTPService.fingerprint(candidate) {
                Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                Text("Compare this fingerprint with the one supplied by your server administrator before trusting it.").font(.caption).foregroundStyle(.orange)
                Button("Trust this fingerprint") {
                    settings.trustedHost = candidateEndpoint; settings.trustedKey = candidate
                    self.candidate = nil; status = "Server key selected. Save preferences to keep it."
                }
            }
            if settings.trustedHost == settings.endpoint, let fingerprint = SFTPService.fingerprint(settings.trustedKey) {
                Text("Trusted: " + fingerprint).font(.caption.monospaced()).foregroundStyle(Palette.green)
            }
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
            Text("Upload is started manually from Metadata. Each upload creates a new folder with MP3/FLAC subfolders. Local files are kept. Passwords are not stored in sessions.").font(.caption).foregroundStyle(Palette.muted)
        }.textFieldStyle(.roundedBorder)
        .onDisappear { task?.cancel() }
    }
    private func run(fetch: Bool) {
        let snapshot = settings
        task = Task {
            defer { task = nil }
            do {
                if fetch {
                    let key = try await SFTPService().fetchHostKey(snapshot)
                    try Task.checkCancellation()
                    candidate = key; candidateEndpoint = snapshot.endpoint; status = "Server fingerprint received; not trusted yet."
                } else {
                    try await SFTPService().test(snapshot)
                    status = "Connected. Remote folder exists. Upload permission will be checked when creating the upload folder."
                }
            } catch { status = Task.isCancelled ? "Cancelled." : error.localizedDescription }
        }
    }
}

struct SFTPUploadView: View {
    @Bindable var model: AppModel
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var mp3 = true
    @State private var flac = false
    @State private var saveMetadata = true
    @State private var confirm = false
    @State private var preparing = false
    private var session: RipSession? { model.workspace.sessions.first { $0.id == sessionID } }
    private var tracks: [SessionTrack] { session?.tracks.filter { $0.phase == .awaitingVerification && $0.integrity?.readCompleted == true && !$0.outputPaths.isEmpty } ?? [] }
    private var formats: Set<String> { Set((mp3 ? ["MP3"] : []) + (flac ? ["FLAC"] : [])) }
    private var files: [SFTPUploadFile] { tracks.flatMap { track in track.outputPaths.map { SFTPUploadFile(path: $0, trackID: track.id) }.filter { formats.contains($0.format) } } }
    private var missingNames: Bool {
        guard let session else { return true }
        return tracks.contains { let tags = model.effectiveFileTags($0, session: session); return tags.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tags.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var warning: String {
        var parts: [String] = []
        if !saveMetadata, files.contains(where: \.hasGenericName) { parts.append("Some files still have generic names such as Track01. They will be uploaded with those names.") }
        if !saveMetadata, let session, tracks.contains(where: { !model.fileTagsAreCurrent($0, session: session) }) { parts.append("Some metadata drafts have not been saved into the audio files. Those changes will not be uploaded.") }
        if tracks.contains(where: { $0.integrity?.requiresReview == true }) { parts.append("Some tracks have not been independently verified by AccurateRip.") }
        return parts.joined(separator: "\n\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Upload via SFTP").font(.title2.bold())
            Text("Destination: \(model.workspace.settings.sftp.username)@\(model.workspace.settings.sftp.host):\(model.workspace.settings.sftp.port)\(model.workspace.settings.sftp.remoteDirectory)").font(.caption).textSelection(.enabled)
            HStack { Toggle("MP3", isOn: $mp3); Toggle("FLAC", isOn: $flac) }.disabled(model.isBusy || preparing)
            Toggle("Save metadata and filenames before uploading", isOn: $saveMetadata).disabled(model.isBusy || preparing)
            Text("Includes saved tags and embedded covers. AI lookup is optional; this step does not run AI. Turn this off to upload files exactly as they are currently saved.").font(.caption).foregroundStyle(Palette.muted)
            if missingNames && saveMetadata { Text("Add an artist and title to every track first, or turn off saving metadata to upload the current files.").font(.caption).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files) { file in Text(file.format + "/" + file.filename).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.frame(height: 190)
            if !warning.isEmpty { Text(warning).font(.caption).foregroundStyle(.orange) }
            Text("Creates a new CDRip folder on the server. Interrupted transfers may leave a .part file; retry creates a new upload folder. No automatic overwrites or removal of local files.").font(.caption).foregroundStyle(Palette.muted)
            if model.isUploadingSFTP {
                ProgressView(value: Double(model.sftpCompleted), total: Double(max(1, model.sftpTotal)))
            }
            if !model.sftpProgress.isEmpty { Text(model.sftpProgress).font(.caption).textSelection(.enabled) }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(Palette.muted).lineLimit(5) }
            HStack {
                Button("Close") { dismiss() }.disabled(model.isBusy || preparing)
                Spacer()
                if model.isBusy { Button("Cancel operation") { model.cancel() } }
                Button("Upload \(files.count) files") {
                    if warning.isEmpty { start() } else { confirm = true }
                }.buttonStyle(GreenButtonStyle()).disabled(model.isBusy || preparing || files.isEmpty || (saveMetadata && missingNames) || model.persistenceFailed)
            }
        }.padding(26).frame(width: 760).background(Palette.background)
        .interactiveDismissDisabled(model.isBusy || preparing)
        .alert("Review before uploading", isPresented: $confirm) {
            Button("Back", role: .cancel) {}
            Button("Upload anyway") { start() }
        } message: { Text(warning) }
    }
    private func start() {
        preparing = true
        Task { await model.uploadSFTP(sessionID: sessionID, formats: formats, saveMetadata: saveMetadata); preparing = false }
    }
}
