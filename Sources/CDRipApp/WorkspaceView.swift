import AppKit
import SwiftUI
import CDRipCore
import UniformTypeIdentifiers

enum Palette {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.073)
    static let panel = Color(red: 0.087, green: 0.103, blue: 0.111)
    static let green = Color(red: 0.64, green: 0.90, blue: 0.38)
    static let muted = Color(red: 0.56, green: 0.61, blue: 0.63)
}

struct WorkspaceView: View {
    @Bindable var model: AppModel
    @State private var destinationStatus: String?
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.white.opacity(0.05))
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        demoNotice
                        switch model.tab {
                        case .preparation: preparation
                        case .metadata: MetadataWorkspace(model: model)
                        case .history: history
                        }
                    }.padding(30)
                }
                footer
            }
        }
        .background(Palette.background)
        .tint(Palette.green)
        .frame(minWidth: 1000, minHeight: 720)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled && model.isReady && !model.demonstrationMode { await model.refreshSource(background: true) }
            }
        }
        .onChange(of: model.completedRipCount) { _, _ in
            if let sound = NSSound(named: "Glass") { sound.play() } else { NSSound.beep() }
        }
        .onChange(of: model.workspace.settings) { destinationStatus = nil }
        .onChange(of: model.selectedTrackIDs) { destinationStatus = nil }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .alert("CD Rip", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "opticaldisc.fill").font(.system(size: 29)).foregroundStyle(Palette.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CD RIP").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("RADIO LIBRARY STUDIO").font(.system(size: 8, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.muted)
                }
            }.padding(.top, 38).padding(.bottom, 48)
            Text("YOUR LIBRARY").eyebrow().padding(.bottom, 14)
            ForEach(WorkspaceTab.allCases, id: \.self) { tab in
                Button { model.tab = tab } label: {
                    HStack(spacing: 11) {
                        Image(systemName: icon(tab)).frame(width: 20)
                        Text(tab.rawValue).font(.system(size: 13, weight: .medium))
                        Spacer()
                        if tab == .history { Text("\(model.workspace.sessions.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted) }
                    }.padding(12).background(model.tab == tab ? Palette.green.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(model.tab == tab ? Palette.green : .white.opacity(0.65))
                }.buttonStyle(.plain).padding(.bottom, 5)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label("AZURACAST", systemImage: "dot.radiowaves.left.and.right").font(.system(size: 10, weight: .semibold)).tracking(1)
                Text("From your CD to\nyour radio library.").font(.system(size: 16, weight: .medium)).lineSpacing(4)
                Text("Local output · manual upload").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            Button { model.showSettings = true } label: {
                Label("App settings", systemImage: "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }.buttonStyle(.plain).padding(.top, 24).padding(.bottom, 24)
            Text("VERSION 0.5.0  /  CD RIP").font(.system(size: 8, design: .monospaced)).foregroundStyle(Palette.muted.opacity(0.6))
        }.padding(.horizontal, 22).padding(.bottom, 20).frame(width: 222).background(Color.black.opacity(0.18))
    }
    private func icon(_ tab: WorkspaceTab) -> String {
        switch tab { case .preparation: "opticaldisc"; case .metadata: "tag"; case .history: "clock.arrow.circlepath" }
    }
    private var header: some View {
        HStack {
            Text("WORKSPACE").eyebrow()
            Text("/").foregroundStyle(Palette.muted.opacity(0.4)).padding(.horizontal, 7)
            Text(model.tab.rawValue).font(.system(size: 12, weight: .medium))
            Spacer()
            Circle().fill(Palette.green).frame(width: 5, height: 5)
            Text("Local on your Mac").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(.horizontal, 30).frame(height: 62).overlay(alignment: .bottom) { Divider().opacity(0.25) }
    }
    private var demoNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: model.demonstrationMode ? "flask" : "waveform.badge.exclamationmark").foregroundStyle(Palette.green)
            Text(model.demonstrationMode ? "DEMO MODE" : "AUDIO CD READING").font(.system(size: 9, weight: .bold)).tracking(1)
            Text(model.demonstrationMode ? "Simulated extraction, without a CD or audio files." : "Full paranoia reading. Per-track checksum results are shown in Metadata.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
        }.padding(13).background(Palette.green.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.green.opacity(0.14)))
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your music starts here.").font(.system(size: 31, weight: .semibold, design: .rounded))
                    Text("Choose an output folder, select your tracks, then add their details.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Text("01 / 03").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).padding(.top, 10)
            }
            HStack(alignment: .top, spacing: 16) {
                sourceCard.frame(maxWidth: .infinity)
                outputCard.frame(maxWidth: .infinity)
            }
            trackTable
        }
    }
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("01  AUDIO SOURCE").eyebrow()
            HStack(spacing: 18) {
                DiscArtwork().frame(width: 90, height: 90)
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.disc?.displayTitle ?? "Waiting for an audio CD").font(.system(size: 18, weight: .semibold))
                    Text("\(model.disc?.tracks.count ?? 0) tracks · \(duration(model.disc?.tracks.map(\.duration).reduce(0,+) ?? 0))").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Label(model.sourceStatus, systemImage: model.demonstrationMode ? "flask.fill" : "opticaldisc").font(.system(size: 10)).foregroundStyle(Palette.green)
                }
            }
            HStack {
                Label("External CD/DVD drive", systemImage: "externaldrive").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Detect") { Task { await model.refreshSource() } }.disabled(model.isBusy || model.isDetecting)
                Button("Eject") { Task { await model.ejectDisc() } }.disabled(model.isBusy || model.isDetecting || model.disc?.source != .optical)
            }.padding(.top, 3)
            Toggle("Demo mode", isOn: Binding(get: { model.demonstrationMode }, set: { enabled in Task { await model.setDemonstration(enabled) } })).font(.caption).disabled(model.isBusy || model.isDetecting)
        }.card()
    }
    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("02  OUTPUT").eyebrow()
            HStack {
                Image(systemName: "folder").foregroundStyle(Palette.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output folder").font(.system(size: 11, weight: .medium))
                    Text(model.workspace.settings.destinationPath.isEmpty ? "Choose where to save your music" : model.workspace.settings.destinationPath)
                        .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button("Choose…", action: chooseDestination).font(.system(size: 11)).disabled(model.isBusy || !model.isReady || model.persistenceFailed)
            }
            HStack {
                Button("Check folder") { checkDestination() }.disabled(model.workspace.settings.destinationPath.isEmpty)
                Button("Open in Finder") {
                    let url = URL(fileURLWithPath: model.workspace.settings.destinationPath)
                    if !NSWorkspace.shared.open(url) { model.message = "The folder is unavailable." }
                }.disabled(model.workspace.settings.destinationPath.isEmpty)
            }.font(.caption)
            Text("MP3, FLAC and retained WAV go into separate subfolders here. Reports are stored internally.").font(.caption).foregroundStyle(Palette.muted)
            Button("Output settings…") { model.showSettings = true }.font(.caption)
            if let destinationStatus { Text(destinationStatus).font(.caption2).foregroundStyle(Palette.muted) }
            Divider().opacity(0.4)
            Picker("Quality", selection: Binding(get: { model.workspace.settings.profile }, set: { profile in
                var value = model.workspace.settings; value.profile = profile
                Task { await model.updateSettings(value) }
            })) {
                ForEach(OutputProfile.allCases) { profile in Text(profile.title).tag(profile) }
            }.font(.system(size: 12)).disabled(model.isBusy || model.persistenceFailed)
            Text(model.workspace.settings.profile.detail).font(.system(size: 10)).foregroundStyle(Palette.muted)
            Text(model.demonstrationMode ? "Simulation does not create audio files." : (model.workspace.settings.outputFolders.deleteWAVAfterConversion ? "WAV is deleted after verified conversion. Read reports are kept." : "WAV is retained in the WAV subfolder. MP3 and FLAC use their own subfolders.")).font(.system(size: 9)).foregroundStyle(Palette.muted.opacity(0.8))
        }.card()
    }

    private var trackTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CD tracks").font(.system(size: 14, weight: .semibold))
                Text("\(model.selectedTrackIDs.count) selected").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.leading, 7)
                Spacer()
                Toggle("Select all tracks", isOn: Binding(
                    get: { model.allTracksSelected },
                    set: { model.selectAllTracks($0) }
                )).toggleStyle(.checkbox).font(.system(size: 10)).foregroundStyle(Palette.green)
                    .disabled(model.isBusy || model.disc?.tracks.isEmpty != false)
            }.padding(.bottom, 16)
            HStack {
                Text("#").frame(width: 51, alignment: .leading)
                Text("TEMPORARY FILENAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("DURATION").frame(width: 80, alignment: .trailing)
                Text("STATUS").frame(width: 155, alignment: .trailing)
            }.font(.system(size: 9, weight: .medium)).tracking(0.8).foregroundStyle(Palette.muted).padding(.bottom, 9)
            ForEach(model.disc?.tracks ?? []) { track in
                HStack(spacing: 8) {
                    Toggle("Select track \(track.number)", isOn: Binding(get: { model.selectedTrackIDs.contains(track.id) }, set: { selected in
                        if selected { model.selectedTrackIDs.insert(track.id) } else { model.selectedTrackIDs.remove(track.id) }
                    })).labelsHidden().toggleStyle(.checkbox).disabled(model.isBusy)
                    Text(String(format: "%02d", track.number)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).frame(width: 23)
                    Text(String(format: "Track %02d", track.number)).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(duration(track.duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).frame(width: 80, alignment: .trailing)
                    VStack(alignment: .trailing, spacing: 3) {
                        if let current = model.currentSession?.tracks.first(where: { $0.id == track.id }), current.phase == .reading {
                            let fraction = min(0.99, current.progress / 0.78)
                            Text("Reading · \(Int(fraction * 100))%").monospacedDigit()
                            GeometryReader { geometry in
                                Capsule().fill(Palette.green.opacity(0.15))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Palette.green).frame(width: geometry.size.width * fraction)
                                    }
                            }.frame(height: 3).accessibilityLabel("Track read progress").accessibilityValue("\(Int(fraction * 100)) percent")
                        } else if let current = model.currentSession?.tracks.first(where: { $0.id == track.id }), current.phase == .encoding {
                            HStack { ProgressView().controlSize(.mini); Text("Encoding / checking…") }
                        } else { Text(phase(for: track.id)) }
                    }.font(.system(size: 10)).foregroundStyle(Palette.muted).frame(width: 155, alignment: .trailing)
                }.frame(height: 34).overlay(alignment: .top) { Divider().opacity(0.2) }
            }
        }.card()
    }
    private func phase(for id: String) -> String { model.currentSession?.tracks.first { $0.id == id }?.ripStatusLabel ?? (model.demonstrationMode ? "Ready for demo" : "Ready to read") }

    private var history: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your sessions.").font(.system(size: 31, weight: .semibold, design: .rounded))
            Text("Your preferences, selections and metadata drafts are saved locally.").foregroundStyle(Palette.muted)
            if model.workspace.sessions.isEmpty {
                ContentUnavailableView("No sessions yet", systemImage: "clock", description: Text("Start a session in Extraction."))
            }
            ForEach(model.workspace.sessions) { session in
                Button { Task { await model.selectSession(session.id) } } label: {
                    HStack(spacing: 15) {
                        Image(systemName: "opticaldisc").font(.title).foregroundStyle(Palette.green)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(session.disc.displayTitle).font(.headline)
                            Text(session.createdAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(Locale(identifier: "en")))).font(.caption).foregroundStyle(Palette.muted)
                            Text(session.destinationPath).font(.caption2).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(session.outputProfile.title).font(.caption)
                            Text("\(session.tracks.count) tracks · \(session.hasFinishedSimulation ? "completed" : "see track status")").font(.caption2).foregroundStyle(Palette.muted)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                    }.card()
                }.buttonStyle(.plain).disabled(model.isBusy)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if model.isBusy {
                Group { if model.isTagging || model.isReviewingAI { ProgressView().controlSize(.small) } else { ProgressView(value: model.currentSession?.progress ?? 0).frame(width: 150) } }
                Text(model.isReadingTracklistImage ? model.ocrProgress : model.isReviewingAI ? model.aiProgressText : model.isTagging ? (model.tagProgressText.isEmpty ? "Writing and verifying tags…" : model.tagProgressText) : model.currentSession?.disc.source == .demonstration ? "Simulation in progress…" : "Reading / verifying audio…").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Stop") { model.cancel() }
            } else {
                Image(systemName: model.persistenceFailed ? "exclamationmark.triangle" : "internaldrive").foregroundStyle(Palette.muted)
                Text(model.persistenceFailed ? "Saving blocked · original data preserved" : "Sessions saved locally").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                if model.tab == .preparation {
                    Button { Task { await model.startRip() } } label: {
                        Label(model.demonstrationMode ? "Simulate extraction" : "Extract selected tracks", systemImage: "play.fill").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 5)
                    }.buttonStyle(GreenButtonStyle()).disabled(!model.canStart)
                } else {
                    Button("Back to extraction") { model.tab = .preparation }
                }
            }
        }.padding(.horizontal, 30).frame(height: 72).background(Palette.panel)
    }
    private func checkDestination() {
        let settings = model.workspace.settings
        let seconds = model.disc?.tracks.filter { model.selectedTrackIDs.contains($0.id) }.map(\.duration).reduce(0, +) ?? 0
        do {
            let report = try OutputFiles.validateDestination(URL(fileURLWithPath: settings.destinationPath), requiredBytes: OutputFiles.requiredBytes(seconds: seconds, profile: settings.profile))
            for format in (settings.outputFolders.deleteWAVAfterConversion ? [] : ["wav"]) + EncodingPlan.outputs(profile: settings.profile, trackNumber: 1).map({ URL(fileURLWithPath: $0.relativePath).pathExtension }) {
                let folder = settings.outputFolders.base(for: format, fallback: settings.destinationPath)
                if FileManager.default.fileExists(atPath: folder.path) {
                    _ = try OutputFiles.validateDestination(folder, requiredBytes: report.requiredBytes)
                }
            }
            destinationStatus = "Output folder ready · format subfolders are created automatically · " + englishByteCount(report.availableBytes) + " free · estimated space needed " + englishByteCount(report.requiredBytes)
        } catch { destinationStatus = error.localizedDescription }
    }
    private func chooseDestination() {
        let panel = makeDestinationPanel(currentPath: model.workspace.settings.destinationPath)
        if panel.runModal() == .OK, let url = panel.url {
            rememberDestinationFolder(url)
            var value = model.workspace.settings; value.destinationPath = url.path
            Task { await model.updateSettings(value); checkDestination() }
        }
    }
}

@MainActor func rememberDestinationFolder(_ url: URL) {
    UserDefaults.standard.set(url.path, forKey: "lastChosenOutputFolder")
}

@MainActor func makeDestinationPanel(currentPath: String) -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    // Share the last confirmed location across all output selectors and app launches.
    let candidates = [UserDefaults.standard.string(forKey: "lastChosenOutputFolder") ?? "", currentPath]
    panel.directoryURL = candidates.compactMap { path -> URL? in
        guard !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }.first ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    panel.prompt = "Choose output folder"
    return panel
}

struct DiscArtwork: View {
    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [.gray.opacity(0.2), Palette.green.opacity(0.45), .gray.opacity(0.2), .white.opacity(0.55), .gray.opacity(0.15), Palette.green.opacity(0.4), .gray.opacity(0.2)], center: .center))
            ForEach(0..<5) { n in Circle().stroke(.white.opacity(0.07), lineWidth: 1).padding(CGFloat(n * 6 + 3)) }
            Circle().fill(Palette.panel).frame(width: 27, height: 27)
            Circle().stroke(.white.opacity(0.2), lineWidth: 1).frame(width: 34, height: 34)
            Circle().fill(.black.opacity(0.65)).frame(width: 13, height: 13)
        }
    }
}

func duration(_ seconds: TimeInterval) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
extension View {
    func card() -> some View { padding(20).background(Palette.panel, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.055))) }
    func eyebrow() -> some View { font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.muted) }
}

struct GreenButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(enabled ? Color.black : Palette.muted)
            .background(enabled ? Palette.green.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

private func englishByteCount(_ bytes: Int64) -> String {
    let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
    var value = Double(max(0, bytes))
    var unit = 0
    while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
    return String(format: "%.1f %@", locale: Locale(identifier: "en_US"), value, units[unit])
}
