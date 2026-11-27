import SwiftUI
import AppKit
import TackroomKit

/// The skill's own text, readable right in the detail pane: SKILL.md first,
/// any other file in the folder one click away. Long files open folded with a
/// table of contents; "展開全文" shows everything.
struct SkillDocument: View {
    /// The skill folder (resolved), or nil for a single-file skill.
    let folder: String?
    /// The instruction file (SKILL.md or the single file).
    let entryFile: String?
    /// Scrolls the detail pane to a line id ("L12").
    var scrollTo: (String) -> Void = { _ in }
    @State private var openFile: String?
    @State private var expanded = false
    @State private var showAllFiles = false
    /// Read off the main thread, so picking a skill never waits on the disk.
    @State private var files: [String] = []
    @State private var loaded: (path: String?, doc: Doc)?

    private static let foldAt = 60

    var body: some View {
        let current = openFile ?? entryFile ?? files.first
        let doc = loaded?.doc ?? Doc(lines: [])
        let lines = doc.lines
        let long = lines.count > Self.foldAt
        let shown = expanded || !long ? lines : Array(lines.prefix(Self.foldAt))
        let isMarkdown = current.map { ["md", "markdown", "txt", ""].contains(($0 as NSString).pathExtension.lowercased()) } ?? true

        VStack(alignment: .leading, spacing: 10) {
            if files.count > 1 {
                let cap = 9
                let shownFiles = showAllFiles || files.count <= cap + 1 ? files : Array(files.prefix(cap))
                FlowRow(spacing: 6) {
                    ForEach(shownFiles, id: \.self) { f in
                        let on = f == current
                        Button {
                            withAnimation(Theme.ease) { openFile = f; expanded = false }
                        } label: {
                            Text(relative(f))
                                .font(.system(size: 11, weight: on ? .semibold : .regular, design: .monospaced))
                                .foregroundStyle(on ? Theme.ink : Theme.ink2)
                                .lineLimit(1).truncationMode(.middle)
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(Capsule().fill(on ? Theme.soft : .clear))
                                .overlay(Capsule().strokeBorder(Theme.hair, lineWidth: on ? 0 : 0.5))
                        }
                        .buttonStyle(HoverTint(radius: 13))
                        .help(relative(f))
                    }
                    if files.count > shownFiles.count || showAllFiles && files.count > cap + 1 {
                        Button {
                            withAnimation(Theme.ease) { showAllFiles.toggle() }
                        } label: {
                            Text(showAllFiles ? L("收合") : L("另外 \(files.count - shownFiles.count) 個"))
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2)
                        }
                        .buttonStyle(HoverTint(radius: 13, hPad: 10, height: 26))
                    }
                }
            }

            do {
                VStack(alignment: .leading, spacing: 0) {
                    if isMarkdown {
                        let toc = Self.headings(lines)
                        if toc.count >= 3 {
                            FlowRow(spacing: 6) {
                                ForEach(toc, id: \.line) { h in
                                    Button {
                                        if h.line >= Self.foldAt { expanded = true }
                                        DispatchQueue.main.async { withAnimation(Theme.ease) { scrollTo("L\(h.line)") } }
                                    } label: {
                                        Text(h.text).font(.system(size: 11)).foregroundStyle(Theme.ink2)
                                    }
                                    .buttonStyle(HoverTint(radius: 6, base: Theme.pillBg, hPad: 8, height: 22))
                                }
                            }
                            .padding(.bottom, 14)
                        }
                        if !Self.extraFrontmatter(doc.frontmatter).isEmpty {
                            Text(Self.extraFrontmatter(doc.frontmatter).joined(separator: "\n"))
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.ink3)
                                .lineSpacing(3).textSelection(.enabled)
                                .padding(.bottom, 14)
                        }
                        MarkdownLines(lines: shown, offset: doc.bodyStart)
                    } else {
                        Text(shown.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink)
                            .lineSpacing(3).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if case .tooBig(let size) = doc.state {
                        Text("檔案太大（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))），僅顯示開頭部分。")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.ink3).padding(.top, 10)
                    }
                    if case .binary = doc.state {
                        Text("非文字檔，請在 Finder 中開啟。").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    }
                    if case .missingFile = doc.state {
                        Text("找不到這個檔案。").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    }
                }
                .id(current)
                .transition(.opacity)
                .padding(EdgeInsets(top: 20, leading: 22, bottom: long && !expanded ? 64 : 22, trailing: 22))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.paper)
                    .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hair, lineWidth: 0.5)))
                .overlay(alignment: .bottom) {
                    if long && !expanded {
                        ZStack(alignment: .bottom) {
                            LinearGradient(colors: [Theme.paper.opacity(0), Theme.paper], startPoint: .top, endPoint: .bottom)
                                .frame(height: 110).allowsHitTesting(false)
                            PillButton(title: L("展開全文（共 \(lines.count) 行）")) { withAnimation(Theme.ease) { expanded = true } }
                                .padding(.bottom, 16)
                        }
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
                    }
                }
            }
            if long && expanded {
                Button("收合") { withAnimation(Theme.ease) { expanded = false } }
                    .buttonStyle(HoverTint(radius: 14, hPad: 14, height: 28)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink2)
                    .frame(maxWidth: .infinity)
            }
        }
        .task(id: (folder ?? "") + "|" + (entryFile ?? "")) {
            let (folder, entry) = (folder, entryFile)
            let list = await Task.detached(priority: .userInitiated) { Self.files(in: folder, entry: entry) }.value
            files = list
        }
        .task(id: current ?? "") {
            let path = current
            let doc = await Task.detached(priority: .userInitiated) { path.map(Self.load) ?? .missing }.value
            withAnimation(loaded == nil ? nil : .easeOut(duration: 0.15)) { loaded = (path, doc) }
        }
    }

    private func relative(_ path: String) -> String {
        guard let folder, path.hasPrefix(folder + "/") else { return (path as NSString).lastPathComponent }
        return String(path.dropFirst(folder.count + 1))
    }

    // MARK: Loading

    enum LoadState: Equatable, Sendable { case ok, tooBig(Int), binary, missingFile }

    struct Doc: Sendable {
        var lines: [String]
        var frontmatter: [String] = []
        var bodyStart = 0
        var state: LoadState = .ok
        static let missing = Doc(lines: [], state: .missingFile)
    }

    nonisolated static func load(_ path: String) -> Doc {
        let limit = 400_000
        guard let handle = FileHandle(forReadingAtPath: path) else { return .missing }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        if data.prefix(4096).contains(0) { return Doc(lines: [], state: .binary) }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        var doc = Doc(lines: [], state: size > limit ? .tooBig(size) : .ok)
        // Frontmatter shows small and grey above the body.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            doc.frontmatter = Array(lines[0...end])
            lines = Array(lines[(end + 1)...])
            doc.bodyStart = end + 1
        }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst(); doc.bodyStart += 1 }
        doc.lines = lines
        return doc
    }

    /// Extensions that are build leftovers or not readable as text.
    nonisolated static let skippedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "zip", "ico", "icns",
                                                 "woff", "woff2", "ttf", "otf", "pyc", "pyo", "class", "o", "so", "dylib"]

    /// Text files in the folder, the instruction file first. Skips hidden
    /// files, tool leftovers (__pycache__, node_modules, .pyc…) and stops at 200 files.
    nonisolated static func files(in folder: String?, entry: String?) -> [String] {
        var out: [String] = []
        if let entry { out.append(entry) }
        guard let folder, let e = FileManager.default.enumerator(at: URL(fileURLWithPath: folder),
              includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in e {
            if out.count >= 200 { break }
            if Scanner.isIgnored(url.lastPathComponent) || url.lastPathComponent.hasSuffix(".egg-info") {
                e.skipDescendants(); continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let p = url.path
            if p == entry || skippedExtensions.contains(url.pathExtension.lowercased()) { continue }
            out.append(p)
        }
        return [out.first].compactMap { $0 } + out.dropFirst().sorted()
    }

    /// Frontmatter lines other than the fences, name and description, which
    /// the header above already shows.
    static func extraFrontmatter(_ lines: [String]) -> [String] {
        var out: [String] = []
        var skipping = false
        for l in lines {
            if l.trimmingCharacters(in: .whitespaces) == "---" { continue }
            let indented = l.first == " " || l.first == "\t"
            if !indented { skipping = l.hasPrefix("name:") || l.hasPrefix("description:") }
            if !skipping { out.append(l) }
        }
        return out
    }

    static func headings(_ lines: [String]) -> [(line: Int, text: String)] {
        var out: [(Int, String)] = []
        var inCode = false
        for (i, l) in lines.enumerated() {
            if l.hasPrefix("```") { inCode.toggle(); continue }
            if !inCode, l.hasPrefix("## ") || l.hasPrefix("# ") {
                out.append((i, l.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }
}

/// A light Markdown renderer: headings, lists, quotes, code blocks, inline styles.
struct MarkdownLines: View {
    let lines: [String]
    let offset: Int

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(blocks, id: \.start) { b in
                view(for: b).id("L\(b.start)")
            }
        }
    }

    enum Kind { case heading(Int), code, bullet(String), quote, paragraph, blank }
    struct Block { var start: Int; var kind: Kind; var text: String }

    private var blocks: [Block] {
        var out: [Block] = []
        var i = 0
        while i < lines.count {
            let l = lines[i]
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                var code: [String] = []
                let s = i; i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                out.append(Block(start: s, kind: .code, text: code.joined(separator: "\n"))); i += 1; continue
            }
            if t.isEmpty { out.append(Block(start: i, kind: .blank, text: "")) }
            else if t.hasPrefix("#") {
                let level = t.prefix(while: { $0 == "#" }).count
                out.append(Block(start: i, kind: .heading(level), text: t.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if let m = t.firstMatch(of: /^([-*+]|\d+\.)\s+(.*)$/) {
                let marker = m.1.first == "-" || m.1.first == "*" || m.1.first == "+" ? "•" : String(m.1)
                let indent = l.prefix(while: { $0 == " " }).count / 2
                out.append(Block(start: i, kind: .bullet(String(repeating: "    ", count: indent) + marker), text: String(m.2)))
            } else if t.hasPrefix(">") {
                out.append(Block(start: i, kind: .quote, text: t.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                out.append(Block(start: i, kind: .paragraph, text: t))
            }
            i += 1
        }
        return out
    }

    private func inline(_ s: String) -> Text {
        let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(a)
    }

    @ViewBuilder
    private func view(for b: Block) -> some View {
        switch b.kind {
        case .blank:
            Color.clear.frame(height: 8)
        case .heading(let level):
            inline(b.text)
                .font(.system(size: level == 1 ? 18 : level == 2 ? 15 : 13.5, weight: .bold, design: level <= 2 ? .serif : .default))
                .foregroundStyle(Theme.ink)
                .padding(.top, level <= 2 ? 10 : 6).padding(.bottom, 4)
                .textSelection(.enabled)
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(b.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink).lineSpacing(3)
                    .textSelection(.enabled).padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pillBg))
            .padding(.vertical, 4)
        case .bullet(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(Theme.ink3)
                inline(b.text).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13)).lineSpacing(4).padding(.vertical, 1.5).textSelection(.enabled)
        case .quote:
            inline(b.text).font(.system(size: 13)).foregroundStyle(Theme.ink2).lineSpacing(4)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Theme.line.frame(width: 2) }
                .padding(.vertical, 2)
        case .paragraph:
            inline(b.text).font(.system(size: 13)).foregroundStyle(Theme.ink).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 1.5).textSelection(.enabled)
        }
    }
}

/// Wraps chips onto as many rows as needed.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = Self.size(of: v, within: width)
            if x > 0, x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    /// A chip's natural size, squeezed to the row width when it is longer.
    private static func size(of v: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = v.sizeThatFits(.unspecified)
        return ideal.width <= width ? ideal : v.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = Self.size(of: v, within: bounds.width)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}
