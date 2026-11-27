import Foundation
import Testing

@Suite struct ArchitectureBoundaryTests {
    private static let uiImports: Set<String> = [
        "SwiftUI",
        "AppKit",
        "QuickLook",
        "UniformTypeIdentifiers",
        "Observation",
        "CoreServices",
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftFiles(under relativeDir: String) throws -> [URL] {
        let base = repoRoot.appendingPathComponent(relativeDir, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func relativePath(_ url: URL) -> String {
        let prefix = repoRoot.path + "/"
        if url.path.hasPrefix(prefix) {
            return String(url.path.dropFirst(prefix.count))
        }
        return url.path
    }

    private static func importedModule(on line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("import ") else { return nil }
        let rest = trimmed.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
        return rest.split(whereSeparator: { $0.isWhitespace || $0 == "." }).first.map(String.init)
    }

    @Test func tackroomKitNeverImportsUIFrameworks() throws {
        let files = try Self.swiftFiles(under: "Sources/TackroomKit")
        #expect(!files.isEmpty)
        var violations: [String] = []
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if let module = Self.importedModule(on: String(line)), Self.uiImports.contains(module) {
                    violations.append("\(Self.relativePath(file)):\(index + 1): imports \(module)")
                }
            }
        }
        #expect(
            violations.isEmpty,
            """
            TackroomKit must remain UI-free (Foundation/CryptoKit/Darwin only).
            Fix: move SwiftUI/AppKit/macOS UI code to Sources/TackroomApp.
            Violations:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test func agentCLIRemainsReadAndProposeOnly() throws {
        let files = try Self.swiftFiles(under: "Sources/tackroom")
        #expect(!files.isEmpty)
        let forbiddenCalls = [
            "Operations(",
            ".execute(",
            ".writeLock(",
            ".ensureExists(",
            "removeItem(",
            "createSymbolicLink(",
            "moveItem(",
            "trashItem(",
        ]
        var violations: [String] = []
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            for (index, rawLine) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine)
                if let module = Self.importedModule(on: line), Self.uiImports.contains(module) {
                    violations.append("\(Self.relativePath(file)):\(index + 1): imports \(module)")
                }
                for token in forbiddenCalls where line.contains(token) {
                    violations.append("\(Self.relativePath(file)):\(index + 1): calls forbidden mutating API '\(token)'")
                }
            }
        }
        #expect(
            violations.isEmpty,
            """
            The tackroom agent CLI must stay read-only and propose-only; direct mutations bypass user confirmation in TackroomApp.
            Fix: inspect state or submit proposals via ProposalQueue().submit(...), and execute mutations only inside TackroomApp.
            Violations:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test func onlyPathsAccessesRealHomeDirectory() throws {
        let files = try Self.swiftFiles(under: "Sources")
        #expect(!files.isEmpty)
        let forbiddenTokens = ["homeDirectoryForCurrentUser", "NSHomeDirectory"]
        var violations: [String] = []
        for file in files {
            let rel = Self.relativePath(file)
            if rel == "Sources/TackroomKit/Paths.swift" { continue }
            let content = try String(contentsOf: file, encoding: .utf8)
            for (index, rawLine) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine)
                for token in forbiddenTokens where line.contains(token) {
                    violations.append("\(rel):\(index + 1): references \(token)")
                }
            }
        }
        #expect(
            violations.isEmpty,
            """
            Only Sources/TackroomKit/Paths.swift may access the real user home directory so TACKROOM_HOME isolation holds everywhere.
            Fix: replace direct home lookups with Paths.home or Paths.expand(...).
            Violations:
            \(violations.joined(separator: "\n"))
            """
        )
    }
}
