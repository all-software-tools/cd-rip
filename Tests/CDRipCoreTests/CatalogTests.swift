import Foundation
import Testing
@testable import CDRipCore

private let releaseJSON = #"""
{"id":"11111111-1111-4111-8111-111111111111","title":"Album","date":"1991-02-04","country":"GB","artist-credit":[{"name":"Various Artists"}],"media":[{"position":1,"format":"CD","tracks":[{"id":"track2","position":2,"title":"Track title","length":215000,"artist-credit":[{"name":"Queen"}],"recording":{"id":"recording2","title":"Recording title","length":210000}},{"id":"track7","position":7,"recording":{"id":"recording7","title":"Other","artist-credit":[{"name":"David Bowie"},{"name":"Queen","joinphrase":""}]}}]},{"position":2,"format":"CD","tracks":[]}]}
"""#
private actor FixtureCatalog: CatalogFetching {
    var urls: [URL] = []
    let data: Data
    init(_ data: Data) { self.data = data }
    func get(_ url: URL, limit: Int) async throws -> Data { urls.append(url); return data }
}
@Test func catalogDistinguishesTrackRecordingArtistAndMedium() throws {
    let release = try JSONDecoder().decode(CatalogRelease.self, from: Data(releaseJSON.utf8))
    let track = try #require(release.media?.first?.tracks?.first)
    #expect(track.trackTitle == "Track title")
    #expect(track.recording.title == "Recording title")
    #expect(track.duration == 215)
    #expect(track.artist(albumArtist: release.artist) == "Queen")
    #expect(release.artist == "Various Artists")
    #expect(release.media?.count == 2)
}
@Test func catalogQueryEscapesOperatorsAndInvalidCoverIsRejected() async throws {
    let http = FixtureCatalog(Data(#"{"releases":[]}"#.utf8))
    _ = try await MusicCatalog(http: http).search(artist: #"A" OR release:*"#, album: "Album")
    let url = try #require(await http.urls.first)
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
    #expect(query == #"artist:"A\" OR release:*" AND release:"Album""#)
    await #expect(throws: ConnectionError.self) { try await MusicCatalog(http: http).release("../../other") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    await #expect(throws: ConnectionError.self) { try await MusicCatalog(http: http).cover(releaseID: "11111111-1111-4111-8111-111111111111", directory: root) }
    #expect(!FileManager.default.fileExists(atPath: root.path))
}
@MainActor @Test func catalogProposalKeepsManualValuesAndEvidenceAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JSONWorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
    var state = try await store.load()
    let disc = try await DemoDiscSource().loadDisc()
    var session = RipSession(disc: disc, selectedIDs: [disc.tracks[1].id, disc.tracks[6].id], profile: .mp3_320, destinationPath: "/tmp/test")
    session.tracks[0].supplied.title = "Operator title"
    session.tracks[0].supplied.genre = "Rock"
    state.sessions = [session]; state.selectedSessionID = session.id
    try await store.save(state)
    let model = AppModel(store: store); await model.bootstrap()
    let release = try JSONDecoder().decode(CatalogRelease.self, from: Data(releaseJSON.utf8))
    await model.proposeCatalog(release, medium: try #require(release.media?.first), cover: nil, sessionID: session.id)
    let restored = try await store.load()
    let track = restored.sessions[0].tracks[0]
    #expect(track.supplied.title == "Operator title")
    #expect(track.supplied.genre == "Rock")
    #expect(track.proposed.title == "Track title")
    #expect(track.proposed.genre.isEmpty)
    #expect(track.proposed.discTotal == 2)
    #expect(track.identification == .conflict)
    #expect(track.evidence.first?.recordingID == "recording2")
    #expect(track.evidence.first?.releaseID == release.id)
    #expect(track.evidence.first?.fields?.contains("title") == true)
    #expect(track.evidence.first?.fields?.contains("genre") == false)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CDRIP_LIVE_CATALOG_TEST"] == "1"))
func explicitLiveCatalogDiagnostic() async throws {
    let catalog = MusicCatalog()
    let releases = try await catalog.search(artist: "Queen", album: "A Night at the Opera")
    let first = try #require(releases.first)
    let detail = try await catalog.release(first.id)
    #expect(detail.id == first.id)
    #expect(detail.media?.contains { !($0.tracks ?? []).isEmpty } == true)
    print("LIVE CATALOG: \(releases.count) results, release detail with tracks verified.")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CDRip-live-cover-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let cover = try await catalog.cover(releaseID: detail.id, directory: root)
        #expect(FileManager.default.fileExists(atPath: cover.path))
        print("LIVE CATALOG: cover downloaded and validated.")
    } catch { print("LIVE CATALOG: selected edition has no usable cover: \(error.localizedDescription)") }
}

@Test func releaseSearchAllowsSummaryMediaWithoutTrackPosition() async throws {
    let json = #"{"releases":[{"id":"11111111-1111-4111-8111-111111111111","title":"Album","media":[{"format":"CD","track-count":12}]}]}"#
    let rows = try await MusicCatalog(http: FixtureCatalog(Data(json.utf8))).search(artist: "Queen", album: "Album")
    #expect(rows.count == 1)
    #expect(rows[0].media?.first?.tracks == nil)
}

private func referenceDisc() -> OpticalDiscInfo {
    let offsets = [0, 15213, 32164, 46442, 63264, 80339, 95312]
    return OpticalDiscInfo(device: "disk9", mountPath: "/Volumes/Audio CD", tracks: (0..<6).map {
        OpticalTrack(number: $0 + 1, startSector: offsets[$0], sectorCount: offsets[$0 + 1] - offsets[$0])
    })
}

@Test func musicBrainzDiscIDMatchesPublishedVectorAndRejectsPartialTOC() throws {
    let disc = referenceDisc()
    #expect(try MusicBrainzDiscID.calculate(disc) == "49HHV7Eb8UKF3aQiNmu1GR8vKTY-")
    let partial = OpticalDiscInfo(device: disc.device, mountPath: disc.mountPath, tracks: Array(disc.tracks.dropFirst()))
    #expect(throws: ConnectionError.self) { try MusicBrainzDiscID.calculate(partial) }
    let broken = OpticalDiscInfo(device: disc.device, mountPath: disc.mountPath, tracks: [
        OpticalTrack(number: 1, startSector: Int.max, sectorCount: Int.max)
    ])
    #expect(throws: ConnectionError.self) { try MusicBrainzDiscID.calculate(broken) }
}

private struct FailedCatalog: CatalogFetching {
    let missing: Bool
    func get(_ url: URL, limit: Int) async throws -> Data {
        if missing { throw CatalogNotFound() }
        throw ConnectionError("HTTP 503")
    }
}

@Test func discLookupDistinguishesUnknownDiscFromServiceFailureAndWrongResponse() async throws {
    #expect(try await MusicCatalog(http: FailedCatalog(missing: true)).lookupDisc(referenceDisc()).isEmpty)
    await #expect(throws: ConnectionError.self) {
        try await MusicCatalog(http: FailedCatalog(missing: false)).lookupDisc(referenceDisc())
    }
    let wrong = FixtureCatalog(Data(#"{"id":"wrong","releases":[]}"#.utf8))
    await #expect(throws: ConnectionError.self) { try await MusicCatalog(http: wrong).lookupDisc(referenceDisc()) }
    let correct = FixtureCatalog(Data(#"{"id":"49HHV7Eb8UKF3aQiNmu1GR8vKTY-","releases":[]}"#.utf8))
    #expect(try await MusicCatalog(http: correct).lookupDisc(referenceDisc()).isEmpty)
    let url = try #require(await correct.urls.first)
    #expect(url.path.hasSuffix("49HHV7Eb8UKF3aQiNmu1GR8vKTY-"))
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "cdstubs", value: "no")) == true)
}

@Test func discLayoutIsAssociatedWithCorrectMedium() throws {
    let json = #"{"id":"11111111-1111-4111-8111-111111111111","title":"Double album","media":[{"position":1,"discs":[{"id":"other"}]},{"position":2,"discs":[{"id":"49HHV7Eb8UKF3aQiNmu1GR8vKTY-"}]}]}"#
    let release = try JSONDecoder().decode(CatalogRelease.self, from: Data(json.utf8))
    let id = try MusicBrainzDiscID.calculate(referenceDisc())
    #expect(release.media?.first?.contains(discID: id) == false)
    #expect(release.media?.last?.contains(discID: id) == true)
}
