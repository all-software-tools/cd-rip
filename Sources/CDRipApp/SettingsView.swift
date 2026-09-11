import SwiftUI
import CDRipCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AppSettings()
    @State private var result: String?
    @State private var succeeded = false
    @State private var testing: Task<Void, Never>?
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("App settings").font(.title2.bold())
                Spacer()
                Button("Close") { testing?.cancel(); dismiss() }
            }
            Picker("Default profile", selection: $draft.profile) {
                ForEach(OutputProfile.allCases) { Text($0.title).tag($0) }
            }
            Text("Choose one output folder in Extraction. The app creates MP3, FLAC and retained WAV subfolders inside it, according to your selected profile.")
                .font(.caption).foregroundStyle(Palette.muted)
            Toggle("Delete WAV after successful conversion", isOn: $draft.outputFolders.deleteWAVAfterConversion)
            Text("Deletes each WAV only after all requested formats are verified and saved. Failed or cancelled tracks keep their WAV. Read reports and recovery data are kept in the application’s internal storage.")
                .font(.caption).foregroundStyle(Palette.muted)
            Toggle("Play a sound when all selected tracks finish", isOn: $draft.completionSound)
            Divider()
            Text("Audio verification").eyebrow()
            Toggle("Online AccurateRip lookup", isOn: Binding(get: { draft.audioVerification.enabled && AccurateRipAccess.databaseApproved }, set: { draft.audioVerification.enabled = $0 }))
                .disabled(!AccurateRipAccess.databaseApproved)
            if !AccurateRipAccess.databaseApproved {
                Text("Local v1/v2 checksums are calculated before conversion. Online access is pending AccurateRip’s approval for this application.").font(.caption).foregroundStyle(Palette.muted)
                Link("AccurateRip access policy", destination: URL(string: "https://www.accuraterip.com/3rdparty-access.htm")!).font(.caption)
            }
            Stepper("Additional reads after a mismatch: \(draft.audioVerification.mismatchRereads)", value: $draft.audioVerification.mismatchRereads, in: 0...2).font(.caption)
            Text("Mismatches keep their WAV and block conversion. Missing references or an unavailable service remain unverified. Matching repeated reads alone do not count as AccurateRip verification.").font(.caption).foregroundStyle(Palette.muted)
            if let drive = model.disc?.optical?.driveID {
                Text("Drive: \(drive)").font(.caption)
                Toggle("Use a known read offset for this drive", isOn: Binding(get: { draft.audioVerification.driveOffsets[drive] != nil }, set: { enabled in
                    if enabled { draft.audioVerification.driveOffsets[drive] = 0 } else { draft.audioVerification.driveOffsets.removeValue(forKey: drive) }
                }))
                if draft.audioVerification.driveOffsets[drive] != nil {
                    HStack {
                        Text("Read offset (stereo samples)").font(.caption)
                        TextField("0", value: Binding(get: { draft.audioVerification.driveOffsets[drive] ?? 0 }, set: { draft.audioVerification.driveOffsets[drive] = max(-5880, min(5880, $0)) }), format: .number).textFieldStyle(.roundedBorder).frame(width: 110)
                    }
                    Text("Enter a documented offset for this exact model and firmware. A positive value reads later samples. Manual entry is not automatic calibration. Disc-edge padding is outside AccurateRip’s checked region for typical offsets.").font(.caption).foregroundStyle(Palette.muted)
                }
            } else {
                Text("Detect a supported optical drive to configure its offset. Unidentified drives use zero without claiming calibration.").font(.caption).foregroundStyle(Palette.muted)
            }
            Divider()
            SFTPSettingsFields(settings: $draft.sftp)
            Divider()
            Text("AI provider").eyebrow()
            Picker("Provider", selection: $draft.aiProvider) {
                ForEach([AIProvider.codexCLI, .claudeCLI]) { Text($0.title).tag($0) }
            }.disabled(testing != nil)
            Group {
                    TextField("Full path to CLI executable", text: draft.aiProvider == .codexCLI ? $draft.codexPath : $draft.claudePath)
                    TextField("Model (optional · blank uses CLI default)", text: draft.aiProvider == .codexCLI ? $draft.codexModel : $draft.claudeModel)
                    Text("Web search and page reading enabled for metadata and cover research. Subscription authentication · no API fallback. Sign in through the CLI first. The test uses your account allowance; any extra usage enabled on your account is managed by the provider.")
                        .font(.caption).foregroundStyle(Palette.muted)
            }.textFieldStyle(.roundedBorder).disabled(testing != nil)
            Stepper("Maximum AI review attempts per session: \(draft.maxAICallsPerSession)", value: $draft.maxAICallsPerSession, in: 1...100).font(.caption)
            HStack {
                Button("Test connection") { testConnection() }.disabled(model.isTestingConnection)
                if testing != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { testing?.cancel() }
                }
            }
            if let result {
                Label(result, systemImage: succeeded ? "checkmark.circle.fill" : "info.circle")
                    .font(.callout).foregroundStyle(succeeded ? Palette.green : Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The test sends a diagnostic message only. Audio recognition and metadata matching are separate steps.")
                .font(.caption).foregroundStyle(Palette.muted)
            Button("Save preferences") { save() }
                .buttonStyle(GreenButtonStyle())
                .disabled(testing != nil || model.persistenceFailed || !model.isReady || model.isBusy)
        }.padding(28)
        }.frame(width: 660, height: 660).background(Palette.background)
            .onAppear { draft = model.workspace.settings }
            .onChange(of: draft) { old, new in
                result = nil; succeeded = false
            }
            .onDisappear { testing?.cancel() }
    }
    private func testConnection() {
        guard !model.isTestingConnection else { return }
        let settings = draft
        result = nil; succeeded = false
        testing = Task { @MainActor in
            defer { testing = nil; model.finishConnectionTest() }
            do {
                let response = try await AIConnectionTester().test(settings: settings)
                try Task.checkCancellation()
                result = response; succeeded = true
            } catch is CancellationError { result = "Test cancelled." }
            catch { result = error.localizedDescription }
        }
        if let testing { model.registerConnectionTest(testing) }
    }
    private func save() {
        Task { await model.updateSettings(draft); if !model.persistenceFailed { dismiss() } else { result = model.message } }
    }
}
