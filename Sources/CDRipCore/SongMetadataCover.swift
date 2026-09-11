import Foundation

public struct SongCoverResult: Sendable {
    public let cover: ImportedCover
    public let description: String
}
public protocol SongCoverLoading: Sendable {
    func load(_ proposals: [WebCoverProposal]) async throws -> SongCoverResult?
}
public struct SongCoverLoader: SongCoverLoading {
    private let service: CoverImportService
    private let directory: URL
    public init(service: CoverImportService = CoverImportService(http: CoverHTTP(timeout: 15)), directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CDRip/Covers")) {
        self.service = service; self.directory = directory
    }
    public func load(_ proposals: [WebCoverProposal]) async throws -> SongCoverResult? {
        for proposal in proposals.prefix(3) {
            try Task.checkCancellation()
            // Never guess which image on a page represents the requested artwork.
            guard let address = proposal.imageURL, let image = URL(string: address), let page = URL(string: proposal.pageURL) else { continue }
            do {
                let cover = try await service.download(.init(url: image, label: proposal.description), pageURL: page, directory: directory)
                try Task.checkCancellation()
                return SongCoverResult(cover: cover, description: proposal.description)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                // Try the next sourced image, including an artist-photo fallback.
            }
        }
        return nil
    }
}
