import Foundation

/// Release builds carry their own tools. Homebrew paths support source builds.
public enum AudioToolPaths {
    public static func executable(_ name: String) -> String {
        resolve(name, resources: Bundle.main.resourceURL, prefixes: ["/opt/homebrew/bin", "/usr/local/bin"])
    }

    static func resolve(_ name: String, resources: URL?, prefixes: [String]) -> String {
        let bundled = resources?.appendingPathComponent("Tools").appendingPathComponent(name).path
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        for prefix in prefixes {
            let path = URL(fileURLWithPath: prefix).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Retain a meaningful path for the existing missing-tool error handling.
        return bundled ?? URL(fileURLWithPath: prefixes.first ?? "/usr/local/bin").appendingPathComponent(name).path
    }
}
