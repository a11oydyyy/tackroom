import SwiftUI
import UniformTypeIdentifiers
import TackroomKit

/// Floating rounded sidebar (round 9): views, projects, agents, tags, and the
/// Tackroom library row at the bottom.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var pickingProject = false
    @State private var relocating: UUID?
    @Namespace private var selectionNS

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Traffic lights sit here; the collapse button sits beside them.
            HStack {
                Spacer()
                Button { withAnimation(Theme.spring) { model.sidebarShown = false } } label: {
                    PathIcon(d: "M2 3h12v10H2zM6 3v10", box: 16, size: 16, lineWidth: 1.3)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(HoverButtonStyle())
                .foregroundStyle(Theme.ink3)
                .help("收起側欄")
            }
            .frame(height: 22)
            .padding(.bottom, 18)
            .contentShape(Rectangle())
            .dragsWindow()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    item(.overview, L("Skill 總覽"), icon: "M2 2h5v5H2zM9 2h5v5H9zM2 9h5v5H2zM9 9h5v5H9z", count: model.skillCount)
                    item(.updates, L("更新"), icon: "M8 2a6 6 0 1 0 .01 0M8 5v6M5.5 8.5 8 11l2.5-2.5",
                         count: model.updates.count, hot: true)
                    item(.proposals, L("Agent 請求"), icon: "M2 9.5 3.8 3h8.4L14 9.5V13H2zM2 9.5h3.5l1 1.5h3l1-1.5H14",
                         count: model.pendingProposals.count, hot: true)
                    item(.activity, L("紀錄"), icon: "M8 2a6 6 0 1 0 .01 0M8 4.8V8l2.2 1.5")
                    item(.docs, L("文件"), icon: "M4 1.8h5.5L12.5 5v9.2H4zM9.5 1.8V5h3M6 8h4.5M6 10.5h4.5",
                         count: model.globalDocs.count + model.projectDocs.values.reduce(0) { $0 + $1.count })
                    item(.mcp, "MCP", icon: "M5 2v4M11 2v4M3.5 6h9v2.5a4.5 4.5 0 0 1-9 0zM8 13v1.5",
                         count: model.mcpGroups.filter { !$0.isPluginOnly }.count)

                    section(L("專案"))
                    ForEach(model.projects) { project in
                        projectRow(project)
                    }
                    Button { pickingProject = true } label: {
                        row(icon: "M8 3.5v9M3.5 8h9", title: L("登記專案…"), dim: true)
                    }
                    .buttonStyle(HoverButtonStyle())

                    section("AGENT", caps: true)
                    ForEach(model.installedAdapters) { adapter in
                        let n = model.globalResults.first { $0.adapter.id == adapter.id }?.activeCount ?? 0
                        Button { model.selection = .agent(adapter.id) } label: {
                            HStack(spacing: 9) {
                                AgentLogo(adapter: adapter, size: 17)
                                Text(adapter.name).lineLimit(1)
                                Spacer(minLength: 4)
                                if n > 0 { CountPill(n: n) }
                            }
                            .rowFrame(selected: model.selection == .agent(adapter.id))
                        }
                        .buttonStyle(HoverButtonStyle())
                    }

                    section(L("標籤"))
                    ForEach(model.tagCounts, id: \.name) { tag in
                        SidebarTagRow(name: tag.name, count: tag.count)
                    }
                    Button { model.newTagFor = [] } label: {
                        row(icon: "M8 3.5v9M3.5 8h9", title: L("新增標籤…"), dim: true)
                    }
                    .buttonStyle(HoverButtonStyle())
                }
            }

            Button { openSettings() } label: {
                HStack(spacing: 9) {
                    PathIcon(d: "M8 1.8 13 6v7.2H3V6zM8 5.1a1.2 1.2 0 1 0 .01 0", box: 16, size: 12, lineWidth: 1.6)
                        .foregroundStyle(Theme.onSolid)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.solid))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Tackroom").font(.system(size: 12, weight: .semibold))
                        Text("~/.tackroom").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.ink3)
                    }
                    Spacer()
                    Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                }
                .padding(.horizontal, 8)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(radius: 9))
            .help("設定")
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
        // The selected fill slides from row to row.
        .environment(\.sidebarSelection, selectionNS)
        .animation(Theme.spring, value: model.selection)
        .padding(EdgeInsets(top: 14, leading: 8, bottom: 8, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.side)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hair, lineWidth: 0.5)))
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.pathExtension != "zip" }
            folders.forEach { model.addProject($0) }
            return !folders.isEmpty
        }
        .fileImporter(isPresented: $pickingProject, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.addProject(url) }
        }
        .fileImporter(isPresented: Binding(get: { relocating != nil }, set: { if !$0 { relocating = nil } }),
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result, let id = relocating { model.relocateProject(id, to: url) }
            relocating = nil
        }
    }

    private func section(_ title: String, caps: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(caps ? 0.77 : 0.22)
            .foregroundStyle(Theme.ink3)
            .padding(EdgeInsets(top: 20, leading: 8, bottom: 6, trailing: 8))
    }

    private func item(_ target: SidebarItem, _ title: String, icon: String, count: Int = 0, hot: Bool = false) -> some View {
        Button { model.selection = target } label: {
            HStack(spacing: 9) {
                PathIcon(d: icon, box: 16, size: 15, lineWidth: 1.4)
                    .foregroundStyle(model.selection == target ? Theme.ink : Theme.ink2)
                Text(title)
                Spacer(minLength: 4)
                if count > 0 { CountPill(n: count, hot: hot) }
            }
            .rowFrame(selected: model.selection == target)
        }
        .buttonStyle(HoverButtonStyle())
    }

    private func row(icon: String, title: String, dim: Bool = false) -> some View {
        HStack(spacing: 9) {
            PathIcon(d: icon, box: 16, size: 15, lineWidth: 1.4).foregroundStyle(Theme.ink2)
            Text(title).foregroundStyle(dim ? Theme.ink3 : Theme.ink)
            Spacer()
        }
        .rowFrame(selected: false)
    }

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        let scan = model.projectScans[project.id]
        let problem = scan.flatMap { Words.access($0.access) }
        Button { model.selection = .project(project.id) } label: {
            HStack(spacing: 9) {
                PathIcon(d: "M2 4.5c0-.6.4-1 1-1h3.2l1.3 1.5H13c.6 0 1 .4 1 1V12c0 .6-.4 1-1 1H3c-.6 0-1-.4-1-1z", box: 16, size: 15, lineWidth: 1.4)
                    .foregroundStyle(problem == nil ? Theme.ink2 : Theme.red)
                Text(project.name).lineLimit(1)
                Spacer(minLength: 4)
                if problem != nil {
                    Text(scan?.access == .missing ? L("找不到") : L("無法讀取")).font(.system(size: 11)).foregroundStyle(Theme.red)
                } else if let n = model.projectSkillCount(project.id), n > 0 {
                    CountPill(n: n)
                }
            }
            .rowFrame(selected: model.selection == .project(project.id))
        }
        .buttonStyle(HoverButtonStyle())
        .help(problem ?? Paths.abbreviate(project.path))
        .contextMenu {
            Button("在 Finder 顯示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
            Button("重新指定位置…") { relocating = project.id }
            Divider()
            Button("移除登記", role: .destructive) { model.removeProject(project.id) }
        }
    }
}

extension EnvironmentValues {
    @Entry var sidebarSelection: Namespace.ID? = nil
}

/// Sidebar row: 28 pt, rounded; the selected one has a soft fill (same weight, no bold).
private struct RowFrame: ViewModifier {
    let selected: Bool
    @Environment(\.sidebarSelection) private var ns

    func body(content: Content) -> some View {
        content
            .padding(.leading, 8).padding(.trailing, 6)
            .frame(height: 28)
            .background {
                if selected {
                    let fill = RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.sel)
                    if let ns { fill.matchedGeometryEffect(id: "sidebar-selection", in: ns) } else { fill }
                }
            }
            .contentShape(Rectangle())
    }
}

extension View {
    func rowFrame(selected: Bool) -> some View { modifier(RowFrame(selected: selected)) }
}

/// Plain button that shows the mockup's faint hover fill.
struct HoverButtonStyle: ButtonStyle {
    var radius: CGFloat = 8
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A tag in the sidebar: click to list its skills, right-click to rename,
/// recolor or delete, and drop skills from the list onto it to tag them.
struct SidebarTagRow: View {
    @Environment(AppModel.self) private var model
    let name: String
    let count: Int
    @State private var targeted = false

    var body: some View {
        let style = model.style(ofTag: name)
        Button { model.selection = .tag(name) } label: {
            HStack(spacing: 9) {
                PathIcon(d: style.icon, size: 15, lineWidth: 1.8).foregroundStyle(style.color)
                Text(name).lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 { CountPill(n: count) }
            }
            .rowFrame(selected: model.selection == .tag(name))
            // While skills are dragged over it: a soft wash in the tag's color.
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(style.color.opacity(targeted ? 0.16 : 0)))
            .animation(.easeOut(duration: 0.15), value: targeted)
        }
        .buttonStyle(HoverButtonStyle())
        .contextMenu {
            Button("重新命名…") { model.renamingTag = name }
            Menu("顏色") {
                ForEach(TagBook.palette, id: \.self) { key in
                    Toggle(isOn: Binding(get: { model.tagBook.tag(named: name)?.color == key },
                                         set: { _ in model.recolorTag(name, to: key) })) {
                        Text(TagStyle.colorNames[key] ?? key)
                    }
                }
            }
            Divider()
            Button("刪除標籤…", role: .destructive) { model.deletingTag = name }
        }
        // Skill rows dragged from the list carry their names, one per line.
        .dropDestination(for: String.self) { items, _ in
            let names = items.flatMap { $0.split(separator: "\n").map(String.init) }.filter { !$0.isEmpty }
            guard !names.isEmpty else { return false }
            model.setTag(name, on: true, for: names)
            return true
        } isTargeted: { targeted = $0 }
        .help(count == 0 ? L("將 skill 拖到此處即可加上此標籤") : L("\(count) 個 skill"))
    }
}
