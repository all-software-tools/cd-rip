import SwiftUI
import CDRipCore

struct AIMetadataView: View {
    @Bindable var model: AppModel
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = ""
    @State private var replaceExisting = false
    @State private var refresh = false
    @State private var showCoverImport = false
    @State private var coverURL = ""
    @State private var coverSourceURL = ""
    @State private var referenceURL = ""
    private var session: RipSession? { model.workspace.sessions.first { $0.id == sessionID } }
    private var referenceDirty: Bool { referenceURL.trimmingCharacters(in: .whitespacesAndNewlines) != (session?.metadataReferenceURL ?? "") }
    private var track: SessionTrack? { session?.tracks.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Review metadata with AI").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("CLI web research for metadata and covers · no audio recognition. Review proposals before applying.")
                .font(.callout).foregroundStyle(Palette.muted)
            HStack {
                Text(model.workspace.settings.aiProvider.title).font(.headline)
                Text(model.workspace.settings.metadataModel.isEmpty ? "CLI default model" : model.workspace.settings.metadataModel).font(.caption)
                Spacer()
                Text("Attempts: \(session?.aiCallCount ?? 0) / \(model.workspace.settings.maxAICallsPerSession)").font(.caption).monospacedDigit()
            }
            if let session {
                HStack {
                    TextField("Reference page URL (optional)", text: $referenceURL).textFieldStyle(.roundedBorder)
                    Button("Save URL") { Task { await model.saveMetadataReferenceURL(referenceURL, sessionID: sessionID) } }
                }.disabled(model.isBusy)
                if referenceURL.trimmingCharacters(in: .whitespacesAndNewlines) != (session.metadataReferenceURL ?? "") {
                    Text("Save the reference URL before starting web research.").font(.caption).foregroundStyle(.orange)
                }
                Text("Compilations are supported. Artist and title are enough to search; album name and reference URL are optional.").font(.caption).foregroundStyle(Palette.muted)
                Picker("Track", selection: $selectedID) {
                    ForEach(session.tracks) { track in
                        Text("\(track.number). \(track.supplied.title.isEmpty ? "Title missing" : track.supplied.title) · \(model.aiReviewLabel(track, session: session))").tag(track.id)
                    }
                }.disabled(model.isReviewingAI)
                HStack {
                    Button("Review this track") { Task { await model.startAIReview(trackIDs: [selectedID], forceRefresh: refresh) } }.disabled(track == nil || model.isBusy || model.isTestingConnection || referenceDirty)
                    Button("Review all \(session.tracks.count) tracks") { Task { await model.startAIReview(trackIDs: Set(session.tracks.map(\.id)), forceRefresh: refresh) } }.disabled(model.isBusy || model.isTestingConnection || referenceDirty)
                    Toggle("Refresh cached results", isOn: $refresh).font(.caption).disabled(model.isBusy)
                }
                HStack {
                    Button("Retry unfinished tracks") {
                        let ids = Set(session.tracks.filter { $0.aiError != nil || !model.aiReviewIsCurrent($0, session: session) }.map(\.id))
                        Task { await model.startAIReview(trackIDs: ids) }
                    }.disabled(model.isBusy || model.isTestingConnection || referenceDirty || !session.tracks.contains { $0.aiError != nil || !model.aiReviewIsCurrent($0, session: session) })
                    Spacer()
                    Button("Import cover from URL") { coverURL = session.metadataReferenceURL ?? ""; coverSourceURL = coverURL; showCoverImport = true }.disabled(model.isBusy)
                }
                Text("One review attempt per uncached track; CLIs may make internal requests/retries. Uses your CLI subscription allowance. Change provider, model and request limit in App settings.")
                    .font(.caption).foregroundStyle(Palette.muted)
                if model.isReviewingAI {
                    HStack { ProgressView().controlSize(.small); Text(model.aiProgressText).font(.caption); Spacer(); Button("Cancel review") { model.cancel() } }
                } else if !model.aiProgressText.isEmpty { Text(model.aiProgressText).font(.caption).foregroundStyle(Palette.muted) }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let error = track?.aiError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                        if let track, let review = track.aiReview {
                            Text(review.decision.status.title).font(.headline).foregroundStyle(review.decision.status == .conflict ? .orange : Palette.green)
                            DisclosureGroup("Research notes") {
                                Text(review.decision.explanation.replacingOccurrences(of: "\\n", with: "\n")).font(.callout).textSelection(.enabled)
                            }.font(.callout)
                            Text(review.usedAI ? "\(review.provider.title) · \(review.model)" : "Catalog lookup only · no AI request was needed").font(.caption).foregroundStyle(Palette.muted)
                            if review.usedAI {
                                Text("Reported tokens: \(review.inputTokens.map(String.init) ?? "not reported") input / \(review.outputTokens.map(String.init) ?? "not reported") output. These are usage counts, not a price estimate.").font(.caption2).foregroundStyle(Palette.muted)
                            }
                            if let candidate = review.candidate {
                                if let length = candidate.duration {
                                    Text(String(format: "CD: %.2fs · catalog: %.2fs · difference: %.2fs", track.duration, length, abs(track.duration - length))).font(.caption).monospacedDigit()
                                }
                                Text(candidate.versionNote?.isEmpty == false ? "Source version note: " + candidate.versionNote! : "Recording version is not specified in a separate source note.").font(.caption).foregroundStyle(Palette.muted)
                                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 9) {
                                    GridRow { Text("Field").bold(); Text("Current draft").bold(); Text("Web / AI proposal").bold() }
                                    ForEach(AIMetadataContract.fields, id: \.self) { key in
                                        GridRow {
                                            Text(AIMetadataContract.fieldTitle(key))
                                            Text(AIMetadataContract.tags(track.supplied, artist: session.effectiveArtist(for: track))[key] ?? "—")
                                            Text(candidate.tags[key] ?? "—")
                                        }
                                    }
                                }.font(.callout).textSelection(.enabled)
                                ForEach(candidate.evidence, id: \.id) { evidence in
                                    if let source = evidence.sourceURL, let url = URL(string: source) { Link("View \(evidence.provider) source", destination: url).font(.caption) }
                                }
                            }
                            ForEach(Array(review.decision.conflicts.enumerated()), id: \.offset) { _, conflict in Text("• " + conflict).font(.caption).foregroundStyle(.orange) }
                            if !review.decision.missingFields.isEmpty { Text("Still missing: " + review.decision.missingFields.map(AIMetadataContract.fieldTitle).joined(separator: ", ")).font(.caption).foregroundStyle(Palette.muted) }
                            if track.aiReviewAppliedAt != nil { Text("Proposal applied to the draft. Use Preview tag writing to save tags to audio copies.").font(.caption).foregroundStyle(Palette.green) }
                            else if !model.aiReviewIsCurrent(track, session: session) { Text("The draft or provider changed after this result. Run a new review before applying it.").font(.caption).foregroundStyle(.orange) }
                        } else { Text("Review a track or the whole album. Apply your tracklist first so each track has a title and artist.").foregroundStyle(Palette.muted) }
                        if let covers = track?.aiReview?.webCovers, !covers.isEmpty {
                            Text("Cover proposals").font(.headline)
                            ForEach(covers) { cover in
                                HStack {
                                    Text(cover.description).font(.caption)
                                    Spacer()
                                    Button("Preview cover") { coverURL = cover.imageURL ?? cover.pageURL; coverSourceURL = cover.pageURL; showCoverImport = true }
                                        .disabled(model.isBusy)
                                }
                                if let url = URL(string: cover.pageURL) { Link("View cover source", destination: url).font(.caption) }
                            }
                        }
                        Text("CLI research can use multiple public web sources. Source links are retained, but source claims and CD editions still need review. Missing information stays empty.")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Toggle("Replace existing values too", isOn: $replaceExisting).font(.caption).disabled(model.isBusy)
                    Spacer()
                    Button(replaceExisting ? "Apply proposal to draft" : "Fill missing draft fields") {
                        guard let track else { return }
                        Task { await model.applyAIReview(trackID: track.id, sessionID: sessionID, replaceExisting: replaceExisting) }
                    }.buttonStyle(GreenButtonStyle()).disabled(model.isBusy || model.persistenceFailed || track?.aiReview?.candidate == nil || track.map { !model.aiReviewIsCurrent($0, session: session) } != false)
                }
            }
        }.padding(26).frame(width: 850, height: 780).background(Palette.background)
            .sheet(isPresented: $showCoverImport) { CoverImportView(model: model, sessionID: sessionID, trackID: selectedID, initialURL: coverURL, initialSourceURL: coverSourceURL) }
            .onAppear { selectedID = model.selectedTrackID ?? session?.tracks.first?.id ?? ""; referenceURL = session?.metadataReferenceURL ?? "" }
            .onChange(of: selectedID) { replaceExisting = false }
    }
}
