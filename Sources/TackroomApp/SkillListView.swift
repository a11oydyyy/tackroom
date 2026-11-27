import SwiftUI
import UniformTypeIdentifiers
import TackroomKit

/// Skill pages (overview, a project, an agent, a tag): list column + detail.
struct SkillsPage: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        HStack(spacing: 0) {
            SkillListColumn(item: item)
                .listColumnFrame()
                // Settle on one skill once the list is ready, so the list and the
                // detail agree even when the order changes later (usage counts).
                .task(id: model.firstVisibleSkill(in: item)) {
                    if model.selectedSkill == nil || model.shownSkill(in: item) != model.selectedSkill {
                        model.selectedSkill = model.shownSkill(in: item)
                    }
                }
            DetailPane {
                if model.isMultiSelecting {
                    BatchPanel(names: model.selectedSkills.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, item: item)
                        .transition(.opacity)
                        // Esc lets go of the selection.
                        .background {
                            Button("") { model.clearMultiSelection() }
                                .keyboardShortcut(.cancelAction)
                                .opacity(0)
                        }
                } else if let path = model.selectedDoc, let doc = model.docs(for: item).first(where: { $0.path == path }) {
                    DocEditor(doc: doc).id(path)
                } else if let name = model.shownSkill(in: item) {
                    SkillDetail(name: name, item: item).id(name)
                } else {
                    EmptyDetail(title: L("沒有符合的 skill"), text: L("清除搜尋或改為顯示全部。"))
                }
            }
        }
        .onAppear { model.refreshDocs() }
    }
}

enum ListFilter: String, CaseIterable {
    case all, attention, manual
}

/// Managed by Tackroom or not: a second, independent filter above the list.
enum ManageFilter: String, CaseIterable {
    case all, managed, unmanaged
}

/// The small mark on rows Tackroom manages (and on the 「已管理」 switch, so the two read together).
struct ManagedMark: View {
    var size: CGFloat = 10.5
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size))
            .foregroundStyle(Theme.ink2)
            .help("由 Tackroom 管理")
            .accessibilityLabel("由 Tackroom 管理")
    }
}

struct SkillListColumn: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem
    @State private var showOwned = false
    @Namespace private var selection

    private var filter: ListFilter { model.listFilter }
    private var manageFilter: ManageFilter { model.manageFilter(for: item) }

    var body: some View {
        let unfiltered = model.groups(for: item)
        let all = unfiltered.filter { model.passes($0, manageFilter) }
        let mine = all.filter { !$0.isHarnessOwned }
        let owned = manageFilter == .all ? all.filter(\.isHarnessOwned) : []
        let attention = mine.filter { model.needsAttention($0) }
        let shown = model.visibleGroups(in: item).filter { !$0.isHarnessOwned }
        let selected = model.shownSkill(in: item)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    TwoTone(strong: title, rest: subtitle(total: mine.count, attention: attention.count))
                    if case .project(let id) = item, let path = model.project(id).map({ Paths.abbreviate($0.path) }) {
                        Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink3)
                            .lineLimit(1).truncationMode(.middle).help(path)
                    }
                }
                SearchField()
                if !isProject && model.hasScanned {
                    ManageSwitch(groups: unfiltered.filter { !$0.isHarnessOwned })
                }
            }
            .padding(EdgeInsets(top: 24, leading: 22, bottom: 12, trailing: 22))
            .contentShape(Rectangle())
            .dragsWindow()

            if !model.hasScanned {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem = projectProblem {
                unreachable(problem)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        docRows()
                        if isProject {
                            group(L("專案內"), shown.filter(\.hasProjectCopy), selected: selected)
                            group(L("全域"), shown.filter { !$0.hasProjectCopy }, selected: selected)
                        } else if filter == .all {
                            if !attention.isEmpty && model.searchText.isEmpty { attentionHint(attention.count) }
                            let pinned = shown.filter { model.isPinned($0.name) }
                            let used = shown.filter { !model.isPinned($0.name) && (model.usage[$0.name] ?? 0) > 0 }
                            if pinned.isEmpty && used.isEmpty {
                                rows(shown, selected: selected)
                            } else {
                                group(L("釘選"), pinned, selected: selected)
                                group(L("常用"), used, selected: selected)
                                group(L("其他"), shown.filter { !model.isPinned($0.name) && (model.usage[$0.name] ?? 0) == 0 }, selected: selected)
                            }
                        } else {
                            group(filter == .manual ? L("手動呼叫") : L("需要留意"), shown, selected: selected)
                        }
                        if filter == .all, !owned.isEmpty {
                            Button { withAnimation(Theme.ease) { showOwned.toggle() } } label: {
                                groupHeader(showOwned ? L("Plugin 與內建") : L("顯示 Plugin 與內建"), owned.count)
                            }
                            .buttonStyle(.plain)
                            if showOwned { rows(owned, selected: selected) }
                        }
                        if shown.isEmpty {
                            emptyList
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 10, bottom: 96, trailing: 10))
                    .animation(Theme.ease, value: filter)
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottom) {
                    Dock(filter: Binding(get: { model.listFilter }, set: { model.listFilter = $0 }), attention: attention.count)
                        .padding(.bottom, 18)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.win)
        .onChange(of: filter) { model.selectedSkill = nil }
        .onChange(of: manageFilter) { model.selectedSkill = nil }
    }

    /// One quiet line instead of a to-do section: what to look at, and how it is decided.
    private func attentionHint(_ n: Int) -> some View {
        Button { withAnimation(Theme.spring) { model.listFilter = .attention } } label: {
            HStack(spacing: 8) {
                Circle().fill(Theme.amber).frame(width: 6, height: 6)
                Text("\(n) 個需要留意").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                Spacer()
                Text("只顯示這些").font(.system(size: 11.5)).foregroundStyle(Theme.ink2)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.amber.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("包含有新版本、版本不一致、外部修改、連結失效或格式有誤的 skill。可在右側選擇「忽略」。")
        .padding(.horizontal, 2).padding(.bottom, 10)
    }

    /// Nothing listed: say why, and offer the way back.
    private var emptyList: some View {
        VStack(spacing: 10) {
            Text(model.searchText.isEmpty ? (filter == .all && manageFilter == .all ? L("沒有 skill")
                    : manageFilter == .managed && filter == .all ? L("還沒有由 Tackroom 管理的 skill")
                    : manageFilter == .unmanaged && filter == .all ? L("每個 skill 都已由 Tackroom 管理") : L("沒有符合篩選條件的 skill"))
                 : L("找不到符合「\(model.searchText)」的 skill"))
                .font(.system(size: 12)).foregroundStyle(Theme.ink2)
            if !model.searchText.isEmpty, case .agent = item {
                let elsewhere = model.groups(for: .overview).count
                if elsewhere > 0 {
                    Text("其他 agent 有 \(elsewhere) 筆符合").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                }
            }
            HStack(spacing: 8) {
                if !model.searchText.isEmpty {
                    PillButton(title: L("清除搜尋")) { withAnimation(Theme.ease) { model.searchText = "" } }
                }
                if filter != .all || manageFilter != .all {
                    PillButton(title: L("顯示全部")) {
                        withAnimation(Theme.spring) {
                            model.listFilter = .all
                            if manageFilter != .all { model.manageFilter = .all }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private var agentID: String? { if case .agent(let id) = item { return id } else { return nil } }
    private var isProject: Bool { if case .project = item { return true } else { return false } }

    private var title: String {
        switch item {
        case .overview: return L("Skill 總覽")
        case .project(let id): return model.project(id)?.name ?? L("專案")
        case .agent(let id): return model.adapter(id)?.name ?? id
        case .tag(let name): return name
        case .mcp: return "MCP"
        case .docs: return L("文件")
        default: return "Skill"
        }
    }

    private func subtitle(total: Int, attention: Int) -> String {
        switch item {
        default:
            return L("\(total) 個 skill。")
        }
    }

    private var projectProblem: String? {
        guard case .project(let id) = item, let scan = model.projectScans[id] else { return nil }
        return Words.access(scan.access)
    }

    @ViewBuilder
    private func group(_ title: String, _ groups: [SkillGroup], selected: String?) -> some View {
        if !groups.isEmpty {
            groupHeader(title, groups.count)
            rows(groups, selected: selected)
        }
    }

    private func groupHeader(_ title: String, _ n: Int) -> some View {
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

    private func rows(_ groups: [SkillGroup], selected: String?) -> some View {
        ForEach(groups) { group in
            let multi = model.isMultiSelecting
            let isSelected = multi ? model.selectedSkills.contains(group.name) : (model.selectedDoc == nil && group.name == selected)
            // Right-click and drag act on the whole selection when this row is part of it.
            let targets = multi && model.selectedSkills.contains(group.name)
                ? displayOrder().filter { model.selectedSkills.contains($0) } : [group.name]
            SkillRowView(group: group, agentPage: agentID, isSelected: isSelected, multi: multi, namespace: selection)
                .contextMenu {
                    if targets.count > 1 { Text("已選取 \(targets.count) 個") }
                    Menu("標籤") { TagMenuItems(names: targets) }
                    let allPinned = targets.allSatisfy(model.isPinned)
                    Button(allPinned ? L("取消釘選") : L("釘選")) {
                        withAnimation(Theme.spring) { targets.forEach { model.setPinned($0, !allPinned) } }
                    }
                    let adoptable = model.adoptableGroups(targets, in: item)
                    if !adoptable.isEmpty {
                        Divider()
                        Button(adoptable.count == 1 ? L("納入 Tackroom 管理…") : L("納入 Tackroom 管理 \(adoptable.count) 個…")) {
                            let groups = adoptable
                            model.propose { adoptable.count == 1 ? $0.planAdopt(groups[0]) : $0.planAdoptMany(groups) }
                        }
                    }
                }
                // While dragging, a small chip follows the pointer instead of the whole row.
                .onDrag {
                    NSItemProvider(object: targets.joined(separator: "\n") as NSString)
                } preview: {
                    DragChip(title: targets.count == 1 ? group.name : L("\(targets.count) 個 skill"),
                             style: model.tagStyle(for: group.name), stacked: targets.count > 1)
                }
                .onTapGesture { click(group.name, selected: selected) }
        }
    }

    /// The instruction files this agent reads (or this project holds), above its skills.
    @ViewBuilder
    private func docRows() -> some View {
        let docs = model.docs(for: item)
        if !docs.isEmpty && model.searchText.isEmpty && filter == .all {
            groupHeader(L("指令文件"), docs.count)
            ForEach(docs) { doc in
                TileRow(icon: "M4 1.8h5.5L12.5 5v9.2H4zM9.5 1.8V5h3M6 8h4.5M6 10.5h4.5",
                        color: doc.readBy != nil ? Theme.brand : Theme.ink2,
                        isSelected: model.selectedDoc == doc.path && !model.isMultiSelecting, namespace: selection) {
                    HStack {
                        Text(doc.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        Spacer()
                        if model.docDrafts[doc.path] != nil {
                            Text("未儲存").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.amber)
                        }
                    }
                    .frame(height: 19)
                    Text(doc.projectID.flatMap { model.project($0)?.name } ?? L("全域"))
                        .font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1).frame(height: 17)
                    Text(doc.readBy ?? L("參考文件"))
                        .font(.system(size: 11)).foregroundStyle(doc.readBy != nil ? Theme.ink2 : Theme.ink3)
                        .frame(height: 16).padding(.top, 3)
                }
                .onTapGesture {
                    withAnimation(Theme.spring) { model.selectedSkills = []; model.selectedDoc = doc.path }
                }
            }
        }
    }

    /// Plain click picks one; ⌘-click adds or removes; ⇧-click picks a run.
    private func click(_ name: String, selected: String?) {
        let flags = NSEvent.modifierFlags
        withAnimation(Theme.spring) {
            if flags.contains(.command) {
                var set = model.selectedSkills.isEmpty ? Set([selected].compactMap { $0 }) : model.selectedSkills
                if set.contains(name) { set.remove(name) } else { set.insert(name) }
                model.selectedSkills = set
                if set.count == 1 { model.selectedSkill = set.first; model.selectedSkills = [] }
                else if set.contains(name) { model.selectedSkill = name }
            } else if flags.contains(.shift), let anchor = model.selectedSkill ?? selected {
                let order = displayOrder()
                if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: name) {
                    model.selectedSkills = Set(order[min(a, b)...max(a, b)])
                    if model.selectedSkills.count < 2 { model.selectedSkills = [] }
                }
            } else {
                model.selectedSkills = []
                model.selectedDoc = nil
                model.selectedSkill = name
            }
        }
    }

    /// Skill names in the order the list shows them, for ⇧-click runs.
    private func displayOrder() -> [String] {
        let all = model.groups(for: item)
        let shown = model.visibleGroups(in: item).filter { !$0.isHarnessOwned }
        var order: [SkillGroup]
        if isProject {
            order = shown.filter(\.hasProjectCopy) + shown.filter { !$0.hasProjectCopy }
        } else if filter == .all {
            let pinned = shown.filter { model.isPinned($0.name) }
            let used = shown.filter { !model.isPinned($0.name) && (model.usage[$0.name] ?? 0) > 0 }
            let rest = shown.filter { !model.isPinned($0.name) && (model.usage[$0.name] ?? 0) == 0 }
            order = pinned.isEmpty && used.isEmpty ? shown : pinned + used + rest
        } else {
            order = shown
        }
        if filter == .all && showOwned && manageFilter == .all { order += all.filter(\.isHarnessOwned) }
        return order.map(\.name)
    }

    @ViewBuilder
    private func unreachable(_ message: String) -> some View {
        if case .project(let id) = item {
            VStack(spacing: 12) {
                Text("無法檢查").font(.system(size: 15, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                ReconnectButton(projectID: id)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One 72 pt row: tag tile, name + time, description, then tag · status · agents.
struct SkillRowView: View {
    @Environment(AppModel.self) private var model
    let group: SkillGroup
    var agentPage: String?
    let isSelected: Bool
    var multi = false
    let namespace: Namespace.ID
    @State private var hovering = false

    var body: some View {
        let style = model.tagStyle(for: group.name)
        let tags = model.tags(of: group.name)
        HStack(spacing: 12) {
            PathIcon(d: style.icon, size: 20, lineWidth: 1.7)
                .foregroundStyle(style.color)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.color.opacity(0.13)))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(group.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .tracking(-0.07)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if model.isPinned(group.name) {
                        Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(Theme.ink3)
                    }
                    if let n = model.usage[group.name], n > 0 {
                        Text("近 30 天 \(n) 次").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.ink2)
                    } else {
                        Text(When.text(model.updatedDate(of: group)))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .frame(height: 19)
                Text(group.description.isEmpty ? L("無說明") : group.description)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .frame(height: 17, alignment: .leading)
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Circle().fill(style.color).frame(width: 6, height: 6)
                        Text(style.name).lineLimit(1)
                        if tags.count > 1 {
                            Text("+\(tags.count - 1)").foregroundStyle(Theme.ink3)
                                .help(tags.dropFirst().joined(separator: L("、")))
                        }
                    }
                    .foregroundStyle(tags.isEmpty ? Theme.ink3 : Theme.ink2)
                    if let status = model.status(of: group, agent: agentPage) {
                        Text(status.text).fontWeight(.semibold).foregroundStyle(status.color)
                    }
                    Spacer(minLength: 4)
                    if model.isManaged(group.name) { ManagedMark().padding(.trailing, agentPage == nil ? 3 : 0) }
                    if agentPage == nil {
                        HStack(spacing: 3) {
                            ForEach(group.activeHarnessIDs, id: \.self) { id in
                                if let a = model.adapter(id) { AgentLogo(adapter: a, size: 16) }
                            }
                        }
                    }
                }
                .font(.system(size: 11))
                .frame(height: 16)
                .padding(.top, 3)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 72)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.card)
                    .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(multi ? Theme.brandSoft : Theme.selStroke, lineWidth: 1))
                    .matchedGeometryEffect(id: multi ? "selection-\(group.name)" : "selection", in: namespace)
            } else if hovering {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.hover)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .transition(.opacity.combined(with: .offset(y: 4)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// 「全部 · 已管理 · 未管理」 with counts, under the search field.
struct ManageSwitch: View {
    @Environment(AppModel.self) private var model
    let groups: [SkillGroup]
    @Namespace private var thumb

    var body: some View {
        let managed = groups.filter { model.isManaged($0.name) }.count
        HStack(spacing: 4) {
            chip(.all, L("全部"), groups.count)
            chip(.managed, L("已管理"), managed, mark: true)
            chip(.unmanaged, L("未管理"), groups.count - managed)
            Spacer(minLength: 0)
            InfoDot(text: L("已管理：由 Tackroom 保管，可在這裡為各 agent 開關、檢查上游更新、發現外部修改並退回。未管理：Tackroom 只顯示，不會改動，也不檢查更新。"), size: 10.5)
        }
    }

    private func chip(_ f: ManageFilter, _ label: String, _ n: Int, mark: Bool = false) -> some View {
        let on = model.manageFilter == f
        return Button {
            withAnimation(Theme.spring) { model.manageFilter = f }
        } label: {
            HStack(spacing: 4) {
                if mark { ManagedMark(size: 9.5) }
                Text(label)
                Text("\(n)").monospacedDigit().foregroundStyle(on ? Theme.ink2 : Theme.ink3)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(on ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 9).frame(height: 24)
            .background {
                if on { Capsule().fill(Theme.soft).matchedGeometryEffect(id: "manage", in: thumb) }
            }
            .hoverWash(Capsule(), color: on ? .clear : Theme.hover)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Floating segmented filter and the round install button.
struct Dock: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: ListFilter
    let attention: Int
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                segment(.all, L("全部"))
                segment(.attention, attention > 0 ? L("需留意 \(attention)") : L("需留意"))
                segment(.manual, L("手動呼叫"))
            }
            .padding(3)
            .background(Capsule().fill(Theme.card).shadow(color: .black.opacity(0.10), radius: 14, y: 8)
                .overlay(Capsule().strokeBorder(Theme.hair, lineWidth: 0.5)))

            Button {
                model.installSource = nil
                model.showingInstall = true
            } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onSolid)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.solid).shadow(color: .black.opacity(0.18), radius: 9, y: 6))
                    .hoverWash(Circle(), color: Theme.onSolid.opacity(0.14))
            }
            .buttonStyle(PressScale())
            .help("安裝 skill（也可直接拖入視窗）")
        }
    }

    private func segment(_ f: ListFilter, _ label: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { filter = f }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(filter == f ? Theme.ink : Theme.ink2)
                .frame(width: 82, height: 28)
                .background {
                    if filter == f { Capsule().fill(Theme.soft).matchedGeometryEffect(id: "thumb", in: thumb) }
                }
                .hoverWash(Capsule(), color: filter == f ? .clear : Theme.hover)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Search box: soft fill, brand ring when focused, ⌘F.
struct SearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 7) {
            PathIcon(d: "M7 2.5a4.5 4.5 0 1 0 .01 0M10.5 10.5l3 3", box: 16, size: 13, lineWidth: 1.7)
                .foregroundStyle(Theme.ink3)
            TextField("", text: $model.searchText, prompt: Text("搜尋名稱、說明或標籤").foregroundStyle(Theme.ink3))
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { model.searchText = ""; focused = false }
            Text("⌘F")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, 4)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hair, lineWidth: 0.5))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.soft))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.brandSoft, lineWidth: focused ? 3 : 0))
        .animation(.easeOut(duration: 0.15), value: focused)
        .background { Button("") { focused = true }.keyboardShortcut("f").hidden() }
    }
}

/// Lets the user point a project at its folder again.
struct ReconnectButton: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    @State private var picking = false

    var body: some View {
        Button("重新連接資料夾…") { picking = true }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.relocateProject(projectID, to: url) }
            }
    }
}
