import Foundation

public enum Paths {
    /// The home folder. `TACKROOM_HOME` points everything at a stand-in home,
    /// so the whole app can be tried without touching real skills.
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["TACKROOM_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Expands a leading `~`.
    public static func expand(_ path: String) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }

    /// Shortens a path under the home folder to `~/…` for display.
    public static func abbreviate(_ path: String) -> String {
        let h = home.path
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    /// Fully resolved path, or nil when it does not exist.
    public static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Expands `*` path segments (one folder level each); other paths come back as is.
    public static func glob(_ path: String) -> [String] {
        guard path.contains("*") else { return [path] }
        var results = ["/"]
        for segment in path.split(separator: "/").map(String.init) {
            if segment == "*" {
                results = results.flatMap { base -> [String] in
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                    return names.filter { !$0.hasPrefix(".") }.sorted().map { (base as NSString).appendingPathComponent($0) }
                }
            } else {
                results = results.map { ($0 as NSString).appendingPathComponent(segment) }
            }
        }
        return results
    }

    /// Nearest folder at or above `path` that contains `.git`.
    public static func gitRoot(above path: String) -> String? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }
}
