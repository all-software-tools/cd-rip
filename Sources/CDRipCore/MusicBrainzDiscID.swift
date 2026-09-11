import Foundation
import CryptoKit

/// MusicBrainz's TOC identifier, not an audio fingerprint or an integrity check.
/// Uses the complete single-session audio TOC, including tracks not selected for ripping.
public enum MusicBrainzDiscID {
    public static func calculate(_ disc: OpticalDiscInfo) throws -> String {
        let tracks = disc.tracks
        guard (1...99).contains(tracks.count) else { throw ConnectionError("A complete audio CD table of contents is required.") }
        var end = 0
        for (index, track) in tracks.enumerated() {
            guard track.number == index + 1, (0..<450_000).contains(track.startSector),
                  (1...450_000).contains(track.sectorCount),
                  track.startSector + track.sectorCount <= 450_000,
                  index == 0 || track.startSector == end else {
                throw ConnectionError("The CD table of contents is incomplete or invalid.")
            }
            end = track.startSector + track.sectorCount
        }
        var hex = String(format: "%02X%02X%08X", 1, tracks.count, end + 150)
        for index in 0..<99 {
            hex += String(format: "%08X", index < tracks.count ? tracks[index].startSector + 150 : 0)
        }
        return Data(Insecure.SHA1.hash(data: Data(hex.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }
}
