import Foundation

/// One line of Activity: one commit in the store.
public struct ActivityEntry: Sendable, Hashable, Identifiable {
    public var id: String          // commit hash
    public var date: Date
    /// `gui`, `cli:<agent>`, or `external`.
    public var actor: String
    public var title: String
    public var op: JournalOp?
    /// A later commit undid this one.
    public var undone: Bool

    public var canUndo: Bool {
        guard let op, !undone else { return false }
        switch op {
        case .undo, .setting: return false
        default: return true
        }
    }

    static let opTrailer = "Tackroom-Op: "

    /// Commit message: `[actor] title`, then the operation for undo.
    static func message(title: String, actor: String, op: JournalOp) -> String {
        let json = (try? JSONEncoder().encode(op)).map { $0.base64EncodedString() } ?? ""
        return "[\(actor)] \(title)\n\n\(opTrailer)\(json)"
    }
}

public enum Activity {
    public static func load(store: Store = Store(), limit: Int = 200) -> [ActivityEntry] {
        guard store.exists,
              let log = try? store.git.run(["log", "-n", "\(limit)", "--format=%H%x1f%aI%x1f%B%x1e"]) else { return [] }
        let iso = ISO8601DateFormatter()
        var entries: [ActivityEntry] = []
        for record in log.components(separatedBy: "\u{1e}") {
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard fields.count >= 3 else { continue }
            let body = fields[2]
            let subject = body.components(separatedBy: "\n").first ?? ""
            var actor = "external"
            var title = subject
            if subject.hasPrefix("["), let close = subject.firstIndex(of: "]") {
                actor = String(subject[subject.index(after: subject.startIndex)..<close])
                title = String(subject[subject.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            var op: JournalOp?
            if let line = body.components(separatedBy: "\n").first(where: { $0.hasPrefix(ActivityEntry.opTrailer) }),
               let data = Data(base64Encoded: String(line.dropFirst(ActivityEntry.opTrailer.count))) {
                op = try? JSONDecoder().decode(JournalOp.self, from: data)
            }
            entries.append(ActivityEntry(id: fields[0], date: iso.date(from: fields[1]) ?? Date(),
                                         actor: actor, title: title, op: op, undone: false))
        }
        // Mark entries that a later undo reversed.
        let undoneIDs = Set(entries.compactMap { e -> String? in
            if case .undo(let of) = e.op { return of } else { return nil }
        })
        for i in entries.indices where undoneIDs.contains(entries[i].id) { entries[i].undone = true }
        return entries
    }
}
