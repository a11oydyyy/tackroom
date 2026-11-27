import SwiftUI
import AppKit
import QuickLook
import TackroomKit

/// The right-hand pane: off-white, hairline on the left, top fade, icon buttons top right.
struct DetailPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.pane)
            .overlay(alignment: .leading) { Theme.line.frame(width: 0.5) }
    }
}

struct EmptyDetail: View {
    var title = L("未選取")
    var text = L("從左側選擇一個 skill")
    var action: (String, () -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
            if let action { PillButton(title: action.0, action: action.1).padding(.top, 10) }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dragsWindow()
    }
}

/// Round icon button used at the top right of detail panes.
struct IconCircleButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.card).shadow(color: .black.opacity(0.06), radius: 4, y: 1)
                    .overlay(Circle().strokeBorder(Theme.line, lineWidth: 0.5)))
                .hoverWash(Circle())
        }
        .buttonStyle(PressScale())
        .help(help)
    }
}

struct SkillDetail: View {
    @Environment(AppModel.self) private var model
    let name: String
    let item: SidebarItem
    @State private var appeared = false
    @State private var shaking: String?
    @State private var shakeCount: CGFloat = 0
    @State private var comparing = false
    @State private var scrolled = false
    @State private var compareChanges: [FileChange]?
    @State private var showingDrift = false
    @State private var driftChanges: [FileChange]?
    @State private var driftWhitespaceOnly: Bool?

    var body: some View {
        if let group = model.detailGroup(named: name, in: item) {
            ZStack(alignment: .topTrailing) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        content(group, scrollTo: { id in proxy.scrollTo(id, anchor: .top) })
                            .padding(EdgeInsets(top: 44, leading: 40, bottom: 0, trailing: 40))
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 6)
                            .scrollProbe()
                    }
                    .tracksScroll($scrolled)
                    .onAppear {
                        // Screen check in a stand-in home: `-detailScroll content` scrolls to a section.
                        if ProcessInfo.processInfo.environment["TACKROOM_HOME"] != nil,
                           let id = UserDefaults.standard.string(forKey: "detailScroll") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { proxy.scrollTo(id, anchor: .top) }
                        }
                    }
                }
                // Top fade under the buttons.
                TopFade(visible: scrolled)
                topButtons(group)
                    .padding(.top, 14).padding(.trailing, 16)
            }
            .task(id: group.issues.contains(.drifted)) {
                guard group.issues.contains(.drifted) else { driftWhitespaceOnly = nil; return }
                let store = Store(), name = group.name
                let current = store.location(of: name, entry: model.lock.skills[name] ?? LockEntry(source: "", contentHash: "", harnesses: []))
                driftWhitespaceOnly = await Task.detached {
                    guard let recorded = store.recordedCopy(of: name) else { return nil }
                    defer { try? FileManager.default.removeItem(at: recorded) }
                    return Differ.whitespaceOnly(old: recorded.path, new: current)
                }.value
            }
            .onAppear {
                withAnimation(Theme.ease.speed(0.92)) { appeared = true }
                // Screen check in a stand-in home: `-openCompare YES`.
                if ProcessInfo.processInfo.environment["TACKROOM_HOME"] != nil, UserDefaults.standard.bool(forKey: "openCompare"),
                   differingPair(group) != nil { compare(group) }
            }
        }
    }

    // MARK: Top buttons

    private func topButtons(_ group: SkillGroup) -> some View {
        HStack(spacing: 8) {
            IconCircleButton(systemImage: "folder", help: L("在 Finder 顯示")) {
                if let copy = group.distinctCopies.first {
                    NSWorkspace.shared.selectFile(copy.skillFile ?? copy.entryPath, inFileViewerRootedAtPath: "")
                }
            }
            Menu {
                moreMenu(group)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .frame(width: 46, height: 32)
            .background(Capsule().fill(Theme.card).shadow(color: .black.opacity(0.06), radius: 4, y: 1)
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5)))
            .hoverWash(Capsule())
            .help("更多動作")
        }
    }

    @ViewBuilder
    private func moreMenu(_ group: SkillGroup) -> some View {
        Button(model.isPinned(group.name) ? L("取消釘選") : L("釘選")) {
            withAnimation(Theme.spring) { model.setPinned(group.name, !model.isPinned(group.name)) }
        }
        Button("快速查看（空白鍵）") { model.previewURL = model.previewFile(for: group.name, in: item) }
        if let url = sourceURL(model.lock.skills[group.name]) { Button("開啟來源網頁") { NSWorkspace.shared.open(url) } }
        if differingPair(group) != nil { Button("比較兩份副本") { compare(group) } }
        Menu("標籤") { TagMenuItems(names: [group.name]) }
        if let entry = model.lock.skills[group.name], entry.remoteURL != nil, entry.linkedPath == nil {
            let n = group.name
            Button(entry.pinned ? L("取消固定版本（恢復檢查更新）") : L("固定目前版本（不再檢查更新）")) {
                model.propose { $0.planPin(n, pinned: !entry.pinned) }
            }
        }
        Divider()
        if model.isManaged(group.name) {
            Button("移除…", role: .destructive) { let n = group.name; model.propose { $0.planRemove(n) } }
        } else if model.adoptBlock(group) == nil {
            Button("納入 Tackroom 管理…") { let g = group; model.propose { $0.planAdopt(g) } }
        }
        if case .project(let pid) = item, let project = model.project(pid), model.projectLocks[pid]?.skills[group.name] != nil {
            Button("從此專案移除…", role: .destructive) { let n = group.name; model.propose { $0.planProjectRemove(n, project: project) } }
        }
    }

    // MARK: Body

    @ViewBuilder
    private func content(_ group: SkillGroup, scrollTo: @escaping (String) -> Void) -> some View {
        let style = model.tagStyle(for: group.name)
        let entry = model.lock.skills[group.name]
        let copy = group.placements.first(where: { $0.state.isActive })?.copy ?? group.distinctCopies.first

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // The tags themselves sit under the description; here only the kind.
                HStack(spacing: 5) {
                    PathIcon(d: style.icon, size: 10, lineWidth: 2.2).foregroundStyle(style.color)
                    Text("Skill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink2)
                }
                .padding(.horizontal, 7).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pillBg))
                Text(scopeText(group, entry: entry)).font(.system(size: 12)).foregroundStyle(Theme.ink2)
            }

            Text(group.name)
                .font(.system(size: 30, weight: .bold, design: .serif))
                .tracking(-0.54)
                .textSelection(.enabled)
                .padding(.top, 10)

            Text(group.description.isEmpty ? L("無說明") : group.description)
                .font(.system(size: 13.5))
                .lineSpacing(13.5 * 0.7 - 4)
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 10)

            SkillTagRow(name: group.name)
                .padding(.top, 14)

            notices(group)
            driftComparison(group)
            comparison(group)

            label(L("使用的 agent"), icon: "rectangle.on.rectangle", trailing: L("\(group.activeHarnessIDs.count) 個使用中"))
            agentCard(group)

            label(L("內容"), icon: "doc.text", trailing: nil).id("content")
            SkillDocument(folder: copy?.isFlatFile == true ? nil : copy?.resolvedPath, entryFile: copy?.skillFile,
                          scrollTo: scrollTo)

            label(L("資訊"), icon: "doc.plaintext", trailing: nil)
            skillCard(group, entry: entry, copy: copy)

            Color.clear.frame(height: 48)
        }
    }

    private func label(_ text: String, icon: String, trailing: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.ink3)
            Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink2)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.ink3) }
        }
        .padding(.top, 30).padding(.bottom, 10)
    }

    // MARK: Notices

    @ViewBuilder
    private func notices(_ group: SkillGroup) -> some View {
        let list = noticeList(group)
        if !list.isEmpty {
            VStack(spacing: 8) {
                ForEach(list, id: \.head) { n in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: n.red ? "exclamationmark.octagon" : n.neutral ? "tray.and.arrow.down" : "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(n.red ? Theme.red : (n.neutral ? Theme.ink2 : Theme.amber))
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill((n.red ? Theme.red : (n.neutral ? Theme.ink2 : Theme.amber)).opacity(0.13)))
                        // Buttons sit beside the text when it fits on one line, else below it.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                noticeText(n).fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 6)
                                noticeButtons(n)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                noticeText(n)
                                noticeButtons(n).padding(.leading, n.dismiss == nil ? 0 : -10)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    .card()
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)),
                                            removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))))
                }
            }
            .padding(.top, 12)
        }
        let quiet = group.issues.filter { model.dismissed.contains(group, $0) }
        if !quiet.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                Text(L("已忽略：") + quiet.map(Words.issueName).joined(separator: L("、")))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink2)
                Spacer()
                Button("恢復提醒") { withAnimation(Theme.ease) { quiet.forEach { model.setDismissed(group, $0, false) } } }
                    .buttonStyle(HoverTint(radius: 12, hPad: 8, height: 24)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.ink)
            }
            .padding(.top, 10)
        }
    }

    private func noticeText(_ n: Notice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(n.head).font(.system(size: 12.5, weight: .semibold))
                if let why = n.why { InfoDot(text: why) }
            }
            Text(n.text).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func noticeButtons(_ n: Notice) -> some View {
        HStack(spacing: 2) {
            if let dismiss = n.dismiss {
                Button("忽略", action: dismiss)
                    .buttonStyle(HoverTint(radius: 14, hPad: 10, height: 28))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink2)
                    .help("不再提醒；情況有變化時會重新出現")
            }
            if let second = n.secondary {
                Button(second.title, action: second.run)
                    .buttonStyle(HoverTint(radius: 14, hPad: 10, height: 28))
                    .font(.system(size: 12, weight: .medium))
            }
            if let act = n.action {
                Button(act.title, action: act.run)
                    .buttonStyle(HoverTint(radius: 14, base: Theme.soft, hPad: 12, height: 28))
                    .font(.system(size: 12, weight: .semibold))
            }
        }
    }

    struct Notice {
        var head: String
        var text: String
        var red = false
        var neutral = false
        var action: (title: String, run: () -> Void)?
        /// A quieter second button, left of the main one.
        var secondary: (title: String, run: () -> Void)?
        /// How Tackroom decided this, in plain words.
        var why: String?
        var dismiss: (() -> Void)?
    }

    private func noticeList(_ group: SkillGroup) -> [Notice] {
        var out: [Notice] = []
        if let update = model.updates.first(where: { $0.name == group.name }) {
            let high = model.severity(of: update) == .high
            let text: String
            switch update.local {
            case .none: text = high ? L("新版有高風險的改動。") : L("\(update.fromCommit ?? L("本機版")) → \(update.toCommit)")
            case .edited: text = L("上游有新版本，你也改過這個 skill。")
            case .unknown: text = L("上游的版本與你的不同。")
            }
            out.append(Notice(head: L("有新版本"), text: text, red: high, action: (L("查看更新"), { model.selection = .updates }),
                              why: update.local == .unknown ? L("Tackroom 找不到你的版本對應上游的哪一版，所以無法分辨差異是你改的還是作者改的。") : nil))
        }
        for issue in model.openIssues(group) {
            let quiet = { withAnimation(Theme.ease) { model.setDismissed(group, issue, true) } }
            switch issue {
            case .versionsDiffer:
                let names = group.activeHarnessIDs.compactMap { model.adapter($0)?.name }.joined(separator: L("、"))
                out.append(Notice(head: L("各 agent 使用的版本不同"), text: L("\(names) 各有一份，內容不一致。"),
                                  action: differingPair(group).map { _ in (comparing ? L("收起比較") : L("並排比較"), { compare(group) }) },
                                  why: L("Tackroom 逐一比對各份的所有檔案後發現內容不同，其中可能有較舊的版本。若為刻意保留，可選擇「忽略」。"),
                                  dismiss: quiet))
            case .drifted:
                let n = group.name
                out.append(Notice(head: L("在 Tackroom 外部被修改"),
                                  text: driftWhitespaceOnly == true ? L("只有空格或換行不同。") : L("檔案與上次記錄的內容不同。"),
                                  action: (L("保留修改…"), { model.propose { $0.planAcceptDrift(n) } }),
                                  secondary: (showingDrift ? L("收起修改") : L("查看修改"), { toggleDrift(group) }),
                                  why: L("檔案內容與 Tackroom 上次記錄的不同，可能由你或某個 agent 修改。保留：記為你的版本，之後上游更新時會分開顯示你的修改和作者的修改。不想要：在比較下方選「還原」。")))
            case .duplicate(let id):
                out.append(Notice(head: L("重複載入"), text: L("\(model.adapter(id)?.name ?? id) 會同時載入每一份。"),
                                  why: L("此 agent 讀取的資料夾中有多份同名 skill，AI 可能收到不一致的說明。"),
                                  dismiss: quiet))
            case .brokenLink:
                out.append(Notice(head: L("捷徑失效"), text: L("連結指向的資料夾已不存在，agent 無法載入。"), red: true,
                                  why: L("這是符號連結（symlink），但其目標位置不存在。"), dismiss: quiet))
            case .problem(let text):
                out.append(Notice(head: L("格式有誤"), text: text,
                                  why: L("SKILL.md 開頭的名稱或說明格式不正確，部分 agent 可能會略過。"), dismiss: quiet))
            }
        }
        if !model.isManaged(group.name), !group.isHarnessOwned, out.isEmpty {
            if let why = model.adoptBlock(group) {
                out.append(Notice(head: L("未由 Tackroom 管理"), text: why, neutral: true))
            } else {
                out.append(Notice(head: L("尚未納入 Tackroom 管理"), text: L("納入管理後，可為各 agent 開關，也會檢查更新。"), neutral: true,
                                  action: (L("納入管理…"), { let g = group; model.propose { $0.planAdopt(g) } })))
            }
        }
        if group.isOffEverywhere, out.isEmpty {
            out.append(Notice(head: L("目前沒有 agent 使用"), text: L("檔案仍保存在 Tackroom，在下方打開任一個 agent 即可恢復。"), neutral: true))
        }
        return out
    }

    // MARK: Agents card

    private func agentCard(_ group: SkillGroup) -> some View {
        let managed = model.isManaged(group.name)
        let adapters = model.installedAdapters
        return VStack(alignment: .leading, spacing: 0) {
        VStack(spacing: 0) {
            ForEach(Array(adapters.enumerated()), id: \.element.id) { index, adapter in
                let placements = group.placements.filter { $0.harnessID == adapter.id }
                let active = placements.first { $0.state.isActive }
                let isOn = managed && adapter.writeDir != nil
                    ? model.lock.skills[group.name]?.harnesses.contains(adapter.id) == true
                    : active != nil
                let readOnly = adapter.writeDir == nil
                // Switched off here, yet loaded through a folder another agent's switch fills.
                let via = managed && !isOn ? active.flatMap { p in
                    model.adapters.first { other in
                        other.id != adapter.id && other.writeDir.map { dir in
                            let d = Paths.expand(dir)
                            return (Paths.realpath(d) ?? d) == (Paths.realpath(p.rootPath) ?? p.rootPath)
                        } == true
                    }
                } : nil
                let key = group.name + adapter.id
                HStack(spacing: 12) {
                    AgentLogo(adapter: adapter, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(adapter.name).font(.system(size: 13, weight: .medium))
                        Text(via.map { L("經由 \($0.name) 的資料夾使用中") }
                             ?? active.map { Paths.abbreviate($0.copy.entryPath) } ?? placements.first.map { Words.shortState($0) } ?? (managed ? L("未開啟") : L("未安裝")))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 6)
                    if readOnly || !managed {
                        HStack(spacing: 4) {
                            Image(systemName: "lock").font(.system(size: 9))
                            Text(shaking == key ? (readOnly ? L("唯讀") : L("請先納入管理")) : (readOnly ? L("唯讀") : L("未管理")))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(shaking == key ? Theme.amber : Theme.ink3)
                        .padding(.trailing, 10)
                    }
                    BrandSwitch(isOn: isOn, readOnly: readOnly || !managed) {
                        if readOnly || !managed {
                            shaking = key
                            withAnimation(.easeInOut(duration: 0.36)) { shakeCount += 1 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if shaking == key { shaking = nil } }
                        } else {
                            model.toggle(group.name, harness: adapter.id, on: !isOn)
                        }
                    }
                    .modifier(Shake(amount: shaking == key ? shakeCount : 0))
                    .disabled(model.isWriting)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .overlay(alignment: .top) { if index > 0 { Theme.line.frame(height: 0.5) } }
            }
        }
        .card()
        readOnlyNote(adapters)
        }
    }

    @ViewBuilder
    private func readOnlyNote(_ adapters: [HarnessAdapter]) -> some View {
        let names = adapters.filter { $0.writeDir == nil }.map(\.name)
        if !names.isEmpty {
            HStack(spacing: 2) {
                Text("\(names.joined(separator: L("、"))) 目前為唯讀。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                InfoDot(text: L("尚未在這台電腦驗證 Tackroom 修改其資料夾後，這些 agent 會沿用而不覆寫。驗證後將開放。"), size: 10.5)
            }
            .padding(.top, 6).padding(.horizontal, 4)
        }
    }

    // MARK: Skill card

    private func skillCard(_ group: SkillGroup, entry: LockEntry?, copy: SkillCopy?) -> some View {
        let scripts = copy?.resolvedPath.map(model.scriptCount) ?? 0
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                stat("\(copy?.fileCount ?? 0)", L("檔案"), color: Theme.ink)
                Theme.line.frame(width: 0.5)
                stat("\(scripts)", L("程式"), color: scripts > 0 ? Theme.amber : Theme.ink)
                Theme.line.frame(width: 0.5)
                stat("\(group.distinctCopies.count)", L("副本"), color: Theme.ink)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }

            VStack(spacing: 0) {
                ruled(L("來源"), sourceLong(entry))
                if let line = model.upstreamLine(group.name) {
                    ruled(L("更新"), line.text, color: line.tone)
                }
                ruled(L("最後更新"), model.updatedDate(of: group).map { $0.formatted(date: .long, time: .omitted) } ?? "—")
                if let entry, let date = ISO8601DateFormatter().date(from: entry.installedAt) {
                    ruled(L("納入管理"), date.formatted(date: .long, time: .omitted))
                }
                ruled(L("存放位置"), copy.map { Paths.abbreviate($0.resolvedPath ?? $0.entryPath) } ?? "—", mono: true, last: true)
            }
            .padding(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))
        }
        .card()
    }

    private func stat(_ value: String, _ label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity)
    }

    private func ruled(_ key: String, _ value: String, mono: Bool = false, last: Bool = false, color: Color = Theme.ink) -> some View {
        HStack(spacing: 0) {
            Text(key).font(.system(size: 11)).foregroundStyle(Theme.ink3).frame(width: 72, alignment: .leading)
            Text(value).font(mono ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .foregroundStyle(color)
                .lineLimit(1).truncationMode(.middle).help(value)
            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .overlay(alignment: .bottom) { if !last { Theme.line.frame(height: 0.5) } }
    }

    // MARK: Helpers

    private func scopeText(_ group: SkillGroup, entry: LockEntry?) -> String {
        var parts: [String] = []
        if let entry {
            parts.append(L("由 Tackroom 管理"))
            parts.append(entry.source.hasPrefix("github:") ? "GitHub" : entry.linkedPath != nil ? L("自訂資料夾")
                         : entry.remoteURL != nil ? "git" : L("本機建立"))
            if entry.hasLocalEdits == true { parts.append(L("含你的修改")) }
        } else if group.isHarnessOwned {
            parts.append(L("隨 agent 附帶"))
        } else {
            parts.append(L("未管理"))
        }
        parts.append(group.hasProjectCopy ? L("專案") : L("全域"))
        if group.distinctCopies.count > 1 { parts.append(L("\(group.distinctCopies.count) 份副本")) }
        if group.placements.contains(where: { $0.state.isActive }) && group.placements.filter({ $0.state.isActive }).allSatisfy({ !$0.modelCanUse }) {
            parts.append(L("手動呼叫"))
        }
        return parts.joined(separator: " · ")
    }

    private func sourceLong(_ entry: LockEntry?) -> String {
        guard let entry else { return L("尚未納入 Tackroom 管理") }
        if entry.source.hasPrefix("github:") { return String(entry.source.dropFirst(7)) + (entry.path.map { " · " + $0 } ?? "") }
        if let linked = entry.linkedPath { return L("自訂資料夾 \(Paths.abbreviate(linked))") }
        if entry.source.hasPrefix("git:") { return "git " + String(entry.source.dropFirst(4)) + (entry.path.map { " · " + $0 } ?? "") }
        if entry.source.hasPrefix("local:") { return L("從 \(String(entry.source.dropFirst(6))) 安裝") }
        return L("本機建立（未連結 GitHub）")
    }

    private func sourceURL(_ entry: LockEntry?) -> URL? {
        guard let entry, entry.source.hasPrefix("github:") else { return nil }
        var s = "https://github.com/" + entry.source.dropFirst(7)
        if let path = entry.path { s += "/tree/\(entry.ref ?? "HEAD")/" + path }
        return URL(string: s)
    }

    private func scriptCount(_ path: String) -> Int {
        guard let walker = FileManager.default.enumerator(atPath: path) else { return 0 }
        var n = 0
        for case let rel as String in walker {
            // Leftovers like __pycache__ or node_modules are not the skill's own programs.
            if Scanner.isIgnored((rel as NSString).lastPathComponent) { walker.skipDescendants(); continue }
            if Scanner.scriptExtensions.contains((rel as NSString).pathExtension.lowercased()) { n += 1 }
        }
        return n
    }

    /// Two copies with different content, each with the agents that use it.
    private func differingPair(_ group: SkillGroup) -> (a: SkillCopy, b: SkillCopy)? {
        guard group.issues.contains(.versionsDiffer) else { return nil }
        let copies = group.distinctCopies.filter { !$0.isBrokenLink && $0.resolvedPath != nil }
        guard let a = copies.first, let b = copies.first(where: { $0.contentHash != a.contentHash }) else { return nil }
        return (a, b)
    }

    private func users(of copy: SkillCopy, in group: SkillGroup) -> String {
        let ids = group.placements.filter { $0.copy.contentHash == copy.contentHash }.map(\.harnessID)
        let names = model.adapters.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? Paths.abbreviate(copy.entryPath) : L("\(names.joined(separator: L("、"))) 用的")
    }

    /// Opens or closes the side-by-side comparison inside the pane.
    private func compare(_ group: SkillGroup) {
        withAnimation(Theme.ease) { comparing.toggle() }
        guard comparing, compareChanges == nil, let pair = differingPair(group),
              let a = pair.a.resolvedPath, let b = pair.b.resolvedPath else { return }
        Task {
            let changes = await Task.detached { Differ.compare(old: a, new: b) }.value
            withAnimation(Theme.ease) { compareChanges = changes }
        }
    }

    /// Recorded version next to the files now.
    private func toggleDrift(_ group: SkillGroup) {
        withAnimation(Theme.ease) { showingDrift.toggle() }
        guard showingDrift, driftChanges == nil, let entry = model.lock.skills[group.name] else { return }
        let store = Store(), name = group.name
        let current = store.location(of: name, entry: entry)
        Task {
            let changes = await Task.detached { () -> [FileChange] in
                guard let recorded = store.recordedCopy(of: name) else { return [] }
                defer { try? FileManager.default.removeItem(at: recorded) }
                return Differ.compare(old: recorded.path, new: current)
            }.value
            withAnimation(Theme.ease) { driftChanges = changes }
        }
    }

    @ViewBuilder
    private func driftComparison(_ group: SkillGroup) -> some View {
        if showingDrift, group.issues.contains(.drifted) {
            VStack(alignment: .leading, spacing: 0) {
                label(L("外部修改"), icon: "rectangle.split.2x1", trailing: L("左：上次記錄　右：現在"))
                if let changes = driftChanges {
                    VStack(spacing: 10) {
                        ForEach(changes) { change in DiffCard(change: change, left: L("上次記錄"), right: L("現在")) }
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        PillButton(title: L("還原成上次記錄…")) { let n = group.name; model.propose { $0.planRestoreDrift(n) } }
                        PillButton(title: L("保留修改…"), primary: true) { let n = group.name; model.propose { $0.planAcceptDrift(n) } }
                    }
                    .padding(.top, 10)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
                }
            }
            .transition(.opacity.combined(with: .offset(y: -8)))
        }
    }

    @ViewBuilder
    private func comparison(_ group: SkillGroup) -> some View {
        if comparing, let pair = differingPair(group) {
            VStack(alignment: .leading, spacing: 0) {
            label(L("並排比較"), icon: "rectangle.split.2x1", trailing: L("唯讀，不會修改檔案"))
            if let changes = compareChanges {
                VStack(spacing: 10) {
                    ForEach(changes) { change in
                        DiffCard(change: change, left: users(of: pair.a, in: group), right: users(of: pair.b, in: group))
                    }
                    if changes.isEmpty {
                        Text("檔案內容相同，僅權限或連結不同。").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
            }
            }
            .transition(.opacity.combined(with: .offset(y: -8)))
        }
    }
}
