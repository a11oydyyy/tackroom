import SwiftUI
import TackroomKit

/// Left column used by Updates, Agent 提案 and Activity: two-tone heading,
/// then the page's own rows.
struct ListColumn<Content: View, Footer: View>: View {
    let strong: String
    let rest: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TwoTone(strong: strong, rest: rest)
                .padding(EdgeInsets(top: 24, leading: 22, bottom: 12, trailing: 22))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .dragsWindow()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) { content }
                    .padding(.horizontal, 10)
            }
            footer
        }
        .listColumnFrame()
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.win)
    }
}

struct GroupHeader: View {
    let title: String
    let n: Int

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(title).fontWeight(.semibold)
            Text("\(n)").fontWeight(.medium).monospacedDigit()
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.ink3)
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
        .frame(height: 34, alignment: .bottom)
    }
}

/// A 72 pt selectable row with a tinted tile, like the skill rows.
struct TileRow<Lines: View>: View {
    let icon: String
    let color: Color
    let isSelected: Bool
    let namespace: Namespace.ID
    @ViewBuilder var lines: Lines
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            PathIcon(d: icon, box: 16, size: 18, lineWidth: 1.5)
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 0) { lines }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 72)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card)
                    .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.selStroke, lineWidth: 1))
                    .matchedGeometryEffect(id: "selection", in: namespace)
            } else if hovering {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.hover)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Floating pill of buttons at the bottom of a detail pane.
struct ActionDock<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(5)
            .background(Capsule().fill(Theme.card).shadow(color: .black.opacity(0.10), radius: 14, y: 8)
                .overlay(Capsule().strokeBorder(Theme.hair, lineWidth: 0.5)))
            .contentShape(Capsule())
            // A plain arrow over the dock, even when text being edited sits underneath.
            .arrowPointer()
            .padding(.bottom, 18)
    }
}

struct PillButton: View {
    let title: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1).fixedSize()
                .font(.system(size: 12.5, weight: primary ? .semibold : .medium))
                .foregroundStyle(primary ? Theme.onSolid : Theme.ink)
                .padding(.horizontal, primary ? 18 : 14).frame(height: 32)
                .background(Capsule().fill(primary ? Theme.solid : Theme.soft))
                .hoverWash(Capsule(), color: primary ? Theme.onSolid.opacity(0.14) : Theme.tint)
        }
        .buttonStyle(PressScale())
    }
}

// MARK: - Updates

struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @Namespace private var ns

    var body: some View {
        let current = model.updates.first { $0.id == selected } ?? model.updates.first
        HStack(spacing: 0) {
            ListColumn(strong: L("更新"), rest: model.updates.isEmpty ? (model.isCheckingUpdates ? L("檢查中…") : L("沒有新版本。"))
                       : L("\(model.updates.count) 個新版本待審。")) {
                if !model.updates.isEmpty {
                    GroupHeader(title: L("待審"), n: model.updates.count)
                    ForEach(model.updates) { u in
                        let sev = model.severity(of: u)
                        let tint = sev == .high ? Theme.red : model.tagStyle(for: u.name).color
                        TileRow(icon: "M8 2a6 6 0 1 0 .01 0M8 5v6M5.5 8.5 8 11l2.5-2.5", color: tint,
                                isSelected: u.id == current?.id, namespace: ns) {
                            HStack {
                                Text(u.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                Spacer()
                                Text(When.text(commitDate(u))).font(.system(size: 11)).foregroundStyle(Theme.ink3)
                            }
                            .frame(height: 19)
                            (Text(sourceLabel(u) + " · ") + Text(L("\(u.fromCommit ?? L("本機版")) → \(u.toCommit)")).font(.system(size: 11, design: .monospaced))
                             + Text(u.hasLocalEdits ? L(" · 你也改過") : u.local == .unknown ? L(" · 無法比對") : ""))
                                .font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(1)
                                .frame(height: 16)
                            Text(model.riskSummary(of: u))
                                .font(.system(size: 11, weight: sev >= .medium ? .semibold : .medium))
                                .foregroundStyle(sev == .high ? Theme.red : sev == .medium ? Theme.amber : Theme.ink3)
                                .frame(height: 16).padding(.top, 2)
                        }
                        .onTapGesture { withAnimation(Theme.spring) { selected = u.id } }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 2) {
                        Text(model.lastCheckProblem.map { L("無法檢查：") + $0 }
                             ?? model.lastUpdateCheck.map { L("上次檢查：") + When.text($0) + " " + $0.formatted(date: .omitted, time: .shortened) } ?? L("還沒檢查過"))
                            .font(.system(size: 11.5)).foregroundStyle(model.lastCheckProblem == nil ? Theme.ink3 : Theme.amber)
                        InfoDot(text: L("啟動時檢查一次，之後每 6 小時檢查一次。只比對上游作者發布的內容：你自己改過的地方不會被當成新版本。"), size: 10.5)
                    }
                    Button(model.isCheckingUpdates ? L("檢查中…") : L("立即檢查")) { model.checkUpdates() }
                        .buttonStyle(HoverTint(radius: 14, base: Theme.soft, hPad: 12, height: 28))
                        .font(.system(size: 12, weight: .semibold))
                        .disabled(model.isCheckingUpdates)
                    if !model.updateFailures.isEmpty {
                        Text("\(model.updateFailures.count) 個無法檢查").font(.system(size: 11)).foregroundStyle(Theme.amber)
                            .help(model.updateFailures.map { L("\($0.key)：\($0.value)") }.sorted().joined(separator: "\n"))
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 22, bottom: 22, trailing: 22))
            }

            DetailPane {
                if let current {
                    UpdateReview(update: current).id(current.id)
                        .onAppear {
                            // Screen check in a stand-in home: `-selectUpdate <name>`.
                            if ProcessInfo.processInfo.environment["TACKROOM_HOME"] != nil, selected == nil,
                               let name = UserDefaults.standard.string(forKey: "selectUpdate") {
                                selected = model.updates.first { $0.name == name }?.id
                            }
                        }
                } else if model.updates.isEmpty {
                    EmptyDetail(title: model.isCheckingUpdates ? L("檢查中…") : L("沒有待審的更新"),
                                text: L("已套用、略過或固定的版本，皆記錄於「紀錄」。"),
                                action: (L("開啟紀錄"), { model.selection = .activity }))
                } else {
                    EmptyDetail(text: L("從左側選擇一個更新"))
                }
            }
        }
    }

    private func sourceLabel(_ u: UpdateCandidate) -> String {
        guard let e = model.lock.skills[u.name] else { return "" }
        if e.source.hasPrefix("github:") { return String(e.source.dropFirst(7)) }
        if e.source.hasPrefix("git:") { return "git" }
        return e.source
    }

    private func commitDate(_ u: UpdateCandidate) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: u.newPath + "/SKILL.md"))?[.modificationDate] as? Date
    }
}

struct UpdateReview: View {
    @Environment(AppModel.self) private var model
    let update: UpdateCandidate
    /// What the author changed (base → new, or installed → new when the base is unknown).
    @State private var changes: [FileChange] = []
    /// The user's own edits (base → installed), when there are any.
    @State private var mine: [FileChange] = []
    @State private var merge: MergeResult?
    @State private var confirming: String?
    @State private var appeared = false

    private var edited: Bool { update.hasLocalEdits }
    private var unknownBase: Bool { update.local == .unknown }
    private var canMerge: Bool { edited && merge?.conflicts.isEmpty == true }

    var body: some View {
        let findings = changes.flatMap(\.risks).sorted { $0.severity > $1.severity }
        let high = findings.filter { $0.severity == .high }
        let medium = findings.filter { $0.severity == .medium }
        let entry = model.lock.skills[update.name]

        ZStack(alignment: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ticket(entry: entry, level: high.isEmpty ? (medium.isEmpty ? L("低") : L("中")) : L("高"),
                           levelColor: high.isEmpty ? (medium.isEmpty ? Theme.green : Theme.amber) : Theme.red)
                    Text(headline(high: high, medium: medium))
                        .font(.system(size: 30, weight: .bold, design: .serif)).tracking(-0.54)
                        .padding(.top, 26)
                    Text(lead(high: high, medium: medium))
                        .font(.system(size: 13.5)).lineSpacing(5).foregroundStyle(Theme.ink2)
                        .frame(maxWidth: 540, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)

                    if let renamed = update.renamedTo {
                        note(L("新版把名稱改成「\(renamed)」"), L("套用後，agent 會用新名稱叫用它，Tackroom 也會以新名稱列出。"))
                    }
                    if let conflicts = merge?.conflicts, edited, !conflicts.isEmpty {
                        note(L("無法自動合併"), L("你和作者都改了 \(conflicts.joined(separator: L("、"))) 的同一段。可以保留你的版本，或改用新版後再自己補回修改。"))
                    }

                    sectionLabel(L("檢查結果"))
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            stat("\(changes.count)", unknownBase ? L("不同的檔案") : L("作者改的檔案"), Theme.ink)
                            Theme.line.frame(width: 0.5)
                            stat("\(high.count)", L("高風險"), high.isEmpty ? Theme.ink : Theme.red)
                            Theme.line.frame(width: 0.5)
                            stat("\(medium.count)", L("需留意"), medium.isEmpty ? Theme.ink : Theme.amber)
                        }
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                        if findings.isEmpty {
                            Text("沒有發現風險").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 42)
                        }
                        ForEach(Array(findings.enumerated()), id: \.offset) { i, f in
                            HStack(spacing: 12) {
                                Text(f.severity == .high ? L("高") : f.severity == .medium ? L("注意") : L("提醒"))
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(color(f.severity))
                                    .frame(width: 36, height: 19)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(color(f.severity).opacity(0.12)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.text).font(.system(size: 12.5)).lineLimit(1)
                                    let why = Words.riskWhy(f.text)
                                    if !why.isEmpty {
                                        Text(why).font(.system(size: 11.5)).foregroundStyle(Theme.ink2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 4)
                                if let line = f.line {
                                    Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink3)
                                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: 180, alignment: .trailing)
                                        .help(line)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 42)
                            .overlay(alignment: .top) { if i > 0 { Theme.line.frame(height: 0.5) } }
                        }
                    }
                    .card()
                    RiskMethodNote().padding(.top, 10)

                    sectionLabel(unknownBase ? L("你的版本和新版的差異") : L("作者的變更"))
                    Text(unknownBase ? "這些差異可能來自你的修改，也可能來自作者。SKILL.md 的說明文字同樣是給 AI 的指令。"
                         : "SKILL.md 的說明文字同樣是給 AI 的指令，也需檢視。")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.ink3).padding(.bottom, 8)
                    VStack(spacing: 10) {
                        ForEach(changes) { change in
                            DiffCard(change: change, left: unknownBase ? L("你的版本") : edited ? L("原本的版本") : L("目前"), right: L("新版"))
                        }
                    }
                    if edited {
                        sectionLabel(update.local == .edited(whitespaceOnly: true) ? L("你的修改（只有空格或換行）") : L("你的修改"))
                        Text("與你當初安裝的版本相比。").font(.system(size: 11.5)).foregroundStyle(Theme.ink3).padding(.bottom, 8)
                        VStack(spacing: 10) {
                            ForEach(mine) { change in DiffCard(change: change, left: L("原本的版本"), right: L("你的版本")) }
                        }
                    }
                    Color.clear.frame(height: 90)
                }
                .padding(EdgeInsets(top: 58, leading: 40, bottom: 0, trailing: 40))
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 6)
            }
            .defaultScrollAnchor(.top)

            ActionDock {
                if let message = confirming {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(high.isEmpty ? Theme.ink : Theme.red)
                        .padding(.leading, 12).padding(.trailing, 4)
                    PillButton(title: L("取消")) { withAnimation(Theme.ease) { confirming = nil } }
                    PillButton(title: edited || unknownBase ? L("確定改用新版") : L("仍要套用"), primary: true) { confirming = nil; apply() }
                        .disabled(model.isWriting)
                } else if edited || unknownBase {
                    PillButton(title: L("保留我的版本")) { let u = update; model.propose { $0.planSkipUpdate(u) } }
                        .help("不套用這一版；上游之後再有不同的新版時會再通知")
                    PillButton(title: L("改用新版…"), primary: !canMerge) {
                        withAnimation(Theme.ease) {
                            confirming = (high.isEmpty ? "" : L("新版含高風險變更。")) + L("你的版本會被取代，可在「紀錄」退回。")
                        }
                    }
                    .disabled(model.isWriting)
                    if canMerge {
                        PillButton(title: high.isEmpty ? L("合併兩邊") : L("合併兩邊…"), primary: true) { mergeNow(high: !high.isEmpty) }
                            .help("套用作者的變更，同時保留你的修改")
                            .disabled(model.isWriting)
                    }
                } else {
                    if !high.isEmpty {
                        Label("有高風險，套用前會再確認", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.ink2).padding(.leading, 12).padding(.trailing, 4)
                    }
                    PillButton(title: L("固定目前版本")) { let n = update.name; model.propose { $0.planPin(n, pinned: true) } }
                    PillButton(title: L("略過這一版")) { let u = update; model.propose { $0.planSkipUpdate(u) } }
                    PillButton(title: high.isEmpty ? L("套用") : L("套用…"), primary: true) {
                        if high.isEmpty { apply() } else { withAnimation(Theme.ease) { confirming = L("此版本含高風險變更，確定要套用？") } }
                    }
                    .disabled(model.isWriting)
                }
            }
        }
        .task {
            let u = update
            let out = Paths.home.appendingPathComponent("Library/Caches/Tackroom/merges/\(u.name)-\(u.newHash.suffix(12))")
            let (a, b, m) = await Task.detached { () -> ([FileChange], [FileChange], MergeResult?) in
                let a = Differ.compare(old: u.authorChangesFrom, new: u.newPath)
                guard u.hasLocalEdits, let base = u.basePath else { return (a, [], nil) }
                let b = Differ.compare(old: base, new: u.oldPath)
                return (a, b, try? Merger.merge(base: base, local: u.oldPath, new: u.newPath, into: out))
            }.value
            changes = a; mine = b; merge = m
            withAnimation(Theme.ease) { appeared = true }
        }
    }

    private func note(_ head: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.amber).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(head).font(.system(size: 12.5, weight: .semibold))
                Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .card()
        .padding(.top, 14)
    }

    private func color(_ s: RiskSeverity) -> Color { s == .high ? Theme.red : s == .medium ? Theme.amber : Theme.ink2 }

    private func headline(high: [RiskFinding], medium: [RiskFinding]) -> String {
        if unknownBase { return L("你的版本和上游不同") }
        if edited { return canMerge ? L("可以合併你的修改") : merge == nil ? L("你和作者都改過") : L("你和作者改到同一段") }
        if high.contains(where: { $0.topic == .secrets }) { return L("新版會讀取密碼或金鑰") }
        if high.contains(where: { $0.topic == .addsProgram }) && medium.contains(where: { $0.topic == .network }) {
            return L("新版會連網傳送資料")
        }
        if let first = high.first { return first.text }
        if !medium.isEmpty { return L("新版有需要留意的變更") }
        return changes.allSatisfy({ $0.path.hasSuffix(".md") }) ? L("只改了說明文字") : L("小幅更新")
    }

    private func lead(high: [RiskFinding], medium: [RiskFinding]) -> String {
        if unknownBase {
            return L("Tackroom 找不到你的版本對應上游的哪一版，無法分辨差異是你改的還是作者改的。請看下方差異再決定。")
        }
        if edited {
            let risk = high.isEmpty ? "" : L("作者的變更含高風險項目，請先檢視。")
            return (canMerge ? L("作者改的地方和你改的地方沒有重疊，合併後兩邊的修改都會保留。") : L("上游有新版本，你也改過這個 skill。")) + risk
        }
        let all = (high + medium).map(\.text)
        if all.isEmpty { return L("未發現風險，檢視變更後即可套用。") }
        return high.isEmpty ? L("有幾項需要留意，請檢視後再決定。") : L("建議先檢視下方變更；套用前會再次確認。")
    }

    /// Header: what is updating and how risky, then the two versions side by side.
    private func ticket(entry: LockEntry?, level: String, levelColor: Color) -> some View {
        let installed = entry.flatMap { ISO8601DateFormatter().date(from: $0.installedAt) }
            .map { $0.formatted(.dateTime.month().day()) + L("安裝") }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 10, weight: .semibold))
                    Text("更新").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 7).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pillBg))
                Text("\(update.name) · 影響 \(entry?.harnesses.count ?? 0) 個 agent")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle().fill(levelColor).frame(width: 6, height: 6)
                    Text(L("\(level)風險")).font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(levelColor)
                .padding(.horizontal, 9).frame(height: 22)
                .background(Capsule().fill(levelColor.opacity(0.12)))
            }
            HStack(alignment: .top, spacing: 0) {
                version(L("目前版本"), update.fromCommit ?? L("本機版"),
                        edited ? L("含你的修改") : unknownBase ? L("無法對應上游版本") : installed, color: Theme.ink2)
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink3)
                    .frame(width: 44).padding(.top, 21)
                version(L("新版本"), update.toCommit, nil, color: Theme.ink)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    private func version(_ cap: String, _ value: String, _ sub: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(cap).font(.system(size: 11)).foregroundStyle(Theme.ink3)
            Text(value).font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(color)
            if let sub { Text(sub).font(.system(size: 11)).foregroundStyle(Theme.ink3) }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink2)
            .padding(.top, 30).padding(.bottom, 10)
    }

    private func stat(_ v: String, _ k: String, _ c: Color) -> some View {
        VStack(spacing: 3) {
            Text(v).font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(c)
            Text(k).font(.system(size: 11)).foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity)
    }

    private func apply() {
        let ops = model.operations
        let u = update
        Task {
            let plan = await Task.detached { ops.planApplyUpdate(u) }.value
            model.run(plan)
        }
    }

    private func mergeNow(high: Bool) {
        guard let merge else { return }
        let u = update
        if high {
            model.propose { $0.planMergeUpdate(u, merge: merge) }
        } else {
            let ops = model.operations
            Task {
                let plan = await Task.detached { ops.planMergeUpdate(u, merge: merge) }.value
                model.run(plan)
            }
        }
    }
}

struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return p
    }
}

/// One changed file as unified lines with context.
struct DiffCard: View {
    let change: FileChange
    /// Column titles for the left (old) and right (new) side.
    var left = L("目前")
    var right = L("新版")
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Theme.ease) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Text(change.path).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text(kind).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(change.severity == .high ? Theme.red : Theme.ink2)
                        .padding(.horizontal, 6).frame(height: 19)
                        .background(RoundedRectangle(cornerRadius: 6).fill((change.severity == .high ? Theme.red : Theme.ink2).opacity(0.11)))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(Theme.ink3)
                }
                .padding(.horizontal, 14).frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverTint(radius: 0))
            if expanded {
                Theme.line.frame(height: 0.5)
                if let lines = change.lines {
                    sideBySide(lines)
                } else {
                    Text("二進位檔或檔案過大，無法顯示").font(.system(size: 11.5)).foregroundStyle(Theme.ink3).padding(14)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .card()
    }

    /// Old on the left, new on the right; changed runs line up row by row.
    private func sideBySide(_ lines: [LineDiff]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(left).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
                Theme.line.frame(width: 0.5)
                Text(right).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink2)
            .frame(height: 26)
            Theme.line.frame(height: 0.5)
            ForEach(Array(Self.rows(visible(lines)).enumerated()), id: \.offset) { _, row in
                if let row {
                    HStack(alignment: .top, spacing: 0) {
                        cell(row.0, removed: true)
                        Theme.line.frame(width: 0.5)
                        cell(row.1, removed: false)
                    }
                } else {
                    Text("⋯").foregroundStyle(Theme.ink3).frame(maxWidth: .infinity).padding(.vertical, 2)
                }
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .textSelection(.enabled)
        .padding(.bottom, 4)
    }

    private func cell(_ line: LineDiff?, removed: Bool) -> some View {
        let changed = line.map { $0.kind != .same } ?? false
        let tint = removed ? Theme.red : Theme.green
        return HStack(alignment: .top, spacing: 8) {
            Text(line.map { "\((removed ? $0.oldNumber : $0.newNumber) ?? 0)" } ?? "")
                .foregroundStyle(Theme.ink3).frame(width: 24, alignment: .trailing)
            Text(line?.text ?? "").fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(changed ? tint.opacity(removed ? 0.08 : 0.09) : (line == nil ? Theme.ink3.opacity(0.04) : .clear))
    }

    /// Pairs lines into (left, right) rows: same lines on both sides, a run
    /// of removed lines next to the run of added lines that follows it.
    static func rows(_ items: [LineDiff?]) -> [(LineDiff?, LineDiff?)?] {
        var out: [(LineDiff?, LineDiff?)?] = []
        var removed: [LineDiff] = [], added: [LineDiff] = []
        func flush() {
            for i in 0..<max(removed.count, added.count) {
                out.append((i < removed.count ? removed[i] : nil, i < added.count ? added[i] : nil))
            }
            removed = []; added = []
        }
        for item in items {
            guard let line = item else { flush(); out.append(nil); continue }
            switch line.kind {
            case .removed: if !added.isEmpty { flush() }; removed.append(line)
            case .added: added.append(line)
            case .same: flush(); out.append((line, line))
            }
        }
        flush()
        return out
    }

    private var kind: String {
        switch change.kind {
        case .added: return L("新檔案")
        case .removed: return L("刪除")
        case .modified: return L("修改")
        }
    }

    /// Changed lines with two lines of context; nil marks a gap.
    private func visible(_ lines: [LineDiff]) -> [LineDiff?] {
        let changed = Set(lines.indices.filter { lines[$0].kind != .same })
        var keep = Set<Int>()
        for c in changed { for d in -2...2 where lines.indices.contains(c + d) { keep.insert(c + d) } }
        var out: [LineDiff?] = []
        var last = -1
        for i in lines.indices where keep.contains(i) {
            if last >= 0 && i > last + 1 { out.append(nil) }
            out.append(lines[i]); last = i
        }
        return out
    }
}

/// 「怎麼判斷的？」 folded under risk results.
struct RiskMethodNote: View {
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(Theme.ease) { open.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.circle").font(.system(size: 11))
                    Text("風險判斷方式").font(.system(size: 11.5, weight: .medium))
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 8.5, weight: .semibold))
                }
                .foregroundStyle(Theme.ink2)
                .padding(.vertical, 3)
            }
            .buttonStyle(HoverTint(radius: 6, hPad: 6))
            .padding(.leading, -6)
            if open {
                Text(Words.riskMethod).font(.system(size: 11.5)).foregroundStyle(Theme.ink2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
    }
}
