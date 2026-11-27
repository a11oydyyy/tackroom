import SwiftUI
import AppKit
import TackroomKit

/// MCP overview (read only, round-9 style): which MCP servers each agent is
/// set up with, which are off, plain-text secrets (where, never the value),
/// and servers that download the newest version on every start.
struct MCPView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var filter: MCPFilter = .all
    @Namespace private var ns
    @Namespace private var thumb

    enum MCPFilter { case all, attention, off }

    var body: some View {
        let groups = model.mcpGroups
        let mine = groups.filter { !$0.isPluginOnly }
        let plugins = groups.filter(\.isPluginOnly)
        let attention = mine.filter(needsAttention)
        let shown: [MCPGroup] = {
            switch filter {
            case .all: return mine
            case .attention: return attention
            case .off: return mine.filter(\.allOff)
            }
        }()
        let current = groups.first { $0.name == selected } ?? attention.first ?? mine.first ?? plugins.first

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TwoTone(strong: "MCP", rest: mine.isEmpty ? L("尚未設定任何 MCP。") :
                        attention.isEmpty ? L("\(mine.count) 個，皆正常。") : L("\(mine.count) 個，\(attention.count) 個需要留意。"))
                    .padding(EdgeInsets(top: 24, leading: 22, bottom: 6, trailing: 22))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle()).dragsWindow()
                Text("唯讀，不會修改任何設定檔。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 22).padding(.bottom, 10)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if filter == .all {
                            section(L("需要留意"), shown.filter(needsAttention), current: current)
                            section(L("正常"), shown.filter { !needsAttention($0) }, current: current)
                            section(L("隨 plugin 附帶"), plugins, current: current)
                        } else {
                            section(filter == .off ? L("關著") : L("需要留意"), shown, current: current)
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 10, bottom: 96, trailing: 10))
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottom) { filterDock(attention: attention.count).padding(.bottom, 18) }
            }
            .listColumnFrame()
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.win)

            DetailPane {
                if let current { MCPDetail(group: current).id(current.name) } else { EmptyDetail(title: L("沒有 MCP"), text: L("目前沒有 agent 設定 MCP。")) }
            }
        }
    }

    private func needsAttention(_ g: MCPGroup) -> Bool {
        g.hasPlaintextSecret || g.floating != nil || !g.duplicateHarnessIDs.isEmpty
    }

    @ViewBuilder
    private func section(_ title: String, _ groups: [MCPGroup], current: MCPGroup?) -> some View {
        if !groups.isEmpty {
            GroupHeader(title: title, n: groups.count)
            ForEach(groups) { g in
                MCPRow(group: g, isSelected: g.name == current?.name, namespace: ns)
                    .onTapGesture { withAnimation(Theme.spring) { selected = g.name } }
            }
        }
    }

    private func filterDock(attention: Int) -> some View {
        HStack(spacing: 0) {
            seg(.all, L("全部"))
            seg(.attention, attention > 0 ? L("需留意 \(attention)") : L("需留意"))
            seg(.off, L("關著"))
        }
        .padding(3)
        .background(Capsule().fill(Theme.card).shadow(color: .black.opacity(0.10), radius: 14, y: 8)
            .overlay(Capsule().strokeBorder(Theme.hair, lineWidth: 0.5)))
    }

    private func seg(_ f: MCPFilter, _ label: String) -> some View {
        Button { withAnimation(Theme.spring) { filter = f; selected = nil } } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(filter == f ? Theme.ink : Theme.ink2)
                .frame(width: 82, height: 28)
                .background { if filter == f { Capsule().fill(Theme.soft).matchedGeometryEffect(id: "thumb", in: thumb) } }
                .hoverWash(Capsule(), color: filter == f ? .clear : Theme.hover)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Plug icon used for MCP rows.
let mcpIcon = "M5 2v4M11 2v4M3.5 6h9v2.5a4.5 4.5 0 0 1-9 0zM8 13v1.5"

struct MCPRow: View {
    @Environment(AppModel.self) private var model
    let group: MCPGroup
    let isSelected: Bool
    let namespace: Namespace.ID

    var body: some View {
        let tint: Color = group.hasPlaintextSecret ? Theme.red : group.floating != nil ? Theme.amber : Theme.dynamic(0x3F72C4, 0x7EA6E6)
        TileRow(icon: mcpIcon, color: tint, isSelected: isSelected, namespace: namespace) {
            HStack {
                Text(group.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(kind).font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
            .frame(height: 19)
            Text(summary).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1).frame(height: 17)
            HStack(spacing: 10) {
                if let status { Text(status.0).fontWeight(.semibold).foregroundStyle(status.1) }
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    ForEach(group.harnessIDs, id: \.self) { id in
                        if let a = model.adapter(id) {
                            AgentLogo(adapter: a, size: 16).opacity(group.enabledHarnessIDs.contains(id) ? 1 : 0.35)
                        }
                    }
                }
            }
            .font(.system(size: 11)).frame(height: 16).padding(.top, 3)
        }
    }

    private var kind: String {
        let t = group.servers.first?.transport
        return t == .stdio ? L("本機程式") : L("網路服務")
    }

    private var summary: String {
        let s = group.servers.first
        if let address = s?.address { return address }
        return ([s?.program.map { ($0 as NSString).lastPathComponent } ?? ""] + (s?.args ?? [])).joined(separator: " ")
    }

    private var status: (String, Color)? {
        if group.hasPlaintextSecret { return (L("明文金鑰"), Theme.red) }
        if group.floating != nil { return (L("未固定版本"), Theme.amber) }
        if !group.duplicateHarnessIDs.isEmpty { return (L("重複設定"), Theme.amber) }
        if group.allOff { return (L("關著"), Theme.ink3) }
        if group.isPluginOnly { return (L("隨 plugin 附帶"), Theme.ink3) }
        return nil
    }
}

struct MCPDetail: View {
    @Environment(AppModel.self) private var model
    let group: MCPGroup
    @State private var appeared = false
    @State private var scrolled = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            PathIcon(d: mcpIcon, box: 16, size: 10, lineWidth: 2)
                            Text("MCP").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pillBg))
                        Text(scopeText).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    }
                    Text(group.name).font(.system(size: 30, weight: .bold, design: .serif)).tracking(-0.54)
                        .textSelection(.enabled).padding(.top, 10)
                    Text(lead).font(.system(size: 13.5)).lineSpacing(5).foregroundStyle(Theme.ink2)
                        .frame(maxWidth: 540, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)

                    notices

                    label(L("使用的 agent"), trailing: L("\(group.enabledHarnessIDs.count) 個啟用"))
                    VStack(spacing: 0) {
                        ForEach(Array(model.installedAdapters.enumerated()), id: \.element.id) { i, adapter in
                            agentRow(adapter, servers: group.servers.filter { $0.harnessID == adapter.id })
                                .overlay(alignment: .top) { if i > 0 { Theme.line.frame(height: 0.5) } }
                        }
                    }
                    .card()

                    label(L("連線方式"), trailing: nil)
                    setupCard

                    Color.clear.frame(height: 48)
                }
                .padding(EdgeInsets(top: 44, leading: 40, bottom: 0, trailing: 40))
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 6)
                .scrollProbe()
            }
            .tracksScroll($scrolled)
            TopFade(visible: scrolled)
            if let file = group.servers.first?.file {
                IconCircleButton(systemImage: "folder", help: L("在 Finder 顯示設定檔")) {
                    NSWorkspace.shared.selectFile(file, inFileViewerRootedAtPath: "")
                }
                .padding(.top, 14).padding(.trailing, 16)
            }
        }
        .onAppear { withAnimation(Theme.ease) { appeared = true } }
    }

    private var scopeText: String {
        var parts: [String] = []
        if let p = group.servers.compactMap(\.plugin).first { parts.append(L("隨 plugin \(p) 附帶")) }
        parts.append(group.servers.first?.transport == .stdio ? L("本機程式") : L("網路服務"))
        parts.append(group.servers.contains { $0.scope == .project } ? L("專案") : L("全域"))
        return parts.joined(separator: " · ")
    }

    private var lead: String {
        let on = group.enabledHarnessIDs.compactMap { model.adapter($0)?.name }
        let off = group.harnessIDs.filter { !group.enabledHarnessIDs.contains($0) }.compactMap { model.adapter($0)?.name }
        var parts: [String] = []
        if !on.isEmpty { parts.append(L("\(on.joined(separator: L("、"))) 會連到它")) }
        if !off.isEmpty { parts.append(L("\(off.joined(separator: L("、"))) 已設定但停用")) }
        return parts.joined(separator: L("；")) + L("。")
    }

    @ViewBuilder
    private var notices: some View {
        let secretServers = group.servers.filter { !$0.plaintextSecrets.isEmpty }
        VStack(spacing: 8) {
            if !secretServers.isEmpty {
                notice(red: true, head: L("設定檔裡有明文金鑰"),
                       text: secretServers.map { (model.adapter($0.harnessID)?.name ?? $0.harnessID) + L("：") + $0.plaintextSecrets.joined(separator: L("、")) }
                        .joined(separator: "\n"),
                       why: L("Tackroom 只顯示金鑰所在位置，不顯示內容。建議改用環境變數或系統鑰匙圈。"))
            }
            if let pkg = group.floating {
                notice(red: false, head: L("未固定版本"),
                       text: L("\(pkg) 未固定版本。"),
                       why: L("作者發布新版後，下次啟動會直接使用，不會經過審閱。"))
            }
            if !group.duplicateHarnessIDs.isEmpty {
                notice(red: false, head: L("同一 agent 重複設定"),
                       text: L("\(group.duplicateHarnessIDs.compactMap { model.adapter($0)?.name }.joined(separator: L("、"))) 在多個位置設定了同名項目。"))
            }
            if group.setupsDiffer && group.harnessIDs.count > 1 {
                notice(red: false, head: L("各 agent 的連線設定不同"), text: L("名稱相同，但連線位置或啟動方式不同。"))
            }
        }
        .padding(.top, 22)
    }

    private func notice(red: Bool, head: String, text: String, why: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: red ? "key" : "exclamationmark.triangle").font(.system(size: 13))
                .foregroundStyle(red ? Theme.red : Theme.amber)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill((red ? Theme.red : Theme.amber).opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    Text(head).font(.system(size: 12.5, weight: .semibold))
                    if let why { InfoDot(text: why) }
                }
                Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .card()
    }

    private func agentRow(_ adapter: HarnessAdapter, servers: [MCPServer]) -> some View {
        HStack(spacing: 12) {
            AgentLogo(adapter: adapter, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(adapter.name).font(.system(size: 13, weight: .medium))
                Text(servers.first.map { Paths.abbreviate($0.file) } ?? L("沒有設定"))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.ink3)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 6)
            if servers.isEmpty {
                Text("—").foregroundStyle(Theme.ink3)
            } else {
                let on = servers.contains(where: \.enabled)
                Text(on ? L("開著") : L("關著"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? Theme.green : Theme.ink3)
            }
        }
        .padding(.horizontal, 14).frame(height: 46)
        .opacity(servers.isEmpty ? 0.6 : 1)
    }

    private var setupCard: some View {
        let s = group.servers.first
        return VStack(spacing: 0) {
            ruled(L("方式"), s?.transport == .stdio ? L("在本機啟動程式") : s?.transport == .sse ? L("連到網路服務（SSE）") : L("連到網路服務"))
            if let address = s?.address { ruled(L("位置"), address, mono: true) }
            if let program = s?.program { ruled(L("啟動指令"), Paths.abbreviate(program), mono: true) }
            if let args = s?.args, !args.isEmpty { ruled(L("參數"), args.joined(separator: " "), mono: true) }
            ruled(L("用變數"), (s?.variables.isEmpty ?? true) ? L("沒有") : s!.variables.joined(separator: L("、")), mono: true)
            ruled(L("設定檔"), group.servers.map { Paths.abbreviate($0.file) }.uniqued().joined(separator: L("、")), mono: true, last: true)
        }
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))
        .card()
    }

    private func ruled(_ key: String, _ value: String, mono: Bool = false, last: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(key).font(.system(size: 11)).foregroundStyle(Theme.ink3).frame(width: 72, alignment: .leading)
            Text(value).font(mono ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .overlay(alignment: .bottom) { if !last { Theme.line.frame(height: 0.5) } }
    }

    private func label(_ text: String, trailing: String?) -> some View {
        HStack {
            Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink2)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.ink3) }
        }
        .padding(.top, 30).padding(.bottom, 10)
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
