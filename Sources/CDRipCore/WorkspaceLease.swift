import Foundation
import Darwin

/// A stable sidecar lock: the JSON itself is replaced atomically, so its inode cannot be locked.
public final class WorkspaceLease: @unchecked Sendable {
    private let descriptor: Int32
    public init(fileURL: URL, owner: Bool = true) throws {
        let parent = fileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let path = parent.appendingPathComponent("." + fileURL.lastPathComponent + (owner ? ".owner-lock" : ".write-lock")).path
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ConnectionError("Cannot reserve the session workspace.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ConnectionError("This session workspace is already in use. Close the other CD Rip instance before continuing.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
