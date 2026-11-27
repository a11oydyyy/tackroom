import Foundation

/// The registered projects, kept in Tackroom's own Application Support folder.
/// Tackroom never writes anything into a project folder.
public struct ProjectList: Sendable {
    public var url: URL

    public init(url: URL = ProjectList.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        Paths.home.appendingPathComponent("Library/Application Support/Tackroom/projects.json")
    }

    public func load() -> [Project] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Project].self, from: data)) ?? []
    }

    public func save(_ projects: [Project]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(projects).write(to: url, options: .atomic)
    }
}

public enum ProjectAccess: Sendable, Hashable {
    case ok
    /// The folder is gone or was moved.
    case missing
    /// macOS did not let Tackroom read it.
    case denied(String)
}

public extension Project {
    /// Opens the saved bookmark (if any), runs `body`, and closes it again.
    /// The bookmark also follows the folder when it is moved or renamed.
    func withAccess<T>(_ body: (_ path: String, _ access: ProjectAccess) -> T) -> T {
        var path = self.path
        var scoped: URL?
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                path = url.path
                if url.startAccessingSecurityScopedResource() { scoped = url }
            }
        }
        defer { scoped?.stopAccessingSecurityScopedResource() }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return body(path, .missing)
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return body(path, .ok)
        } catch {
            return body(path, .denied((error as NSError).localizedDescription))
        }
    }

    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
