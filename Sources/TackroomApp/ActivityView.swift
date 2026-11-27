import SwiftUI
import TackroomKit

/// Everything that changed, newest first: by you, by an agent, or from an
/// unknown source. Entries that can be undone offer 恢復.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @Namespace private var ns

    enum Item: Identifiable {
        case commit(ActivityEntry)
        case external(ExternalLog.Entry)
        var id: String {
            switch self {
            case .commit(let e): return e.id
            case .external(let e): return "ext-" + e.name + e.date.description
            }
        }
        var date: Date {
            switch self {
            case .commit(let e): return e.date
            case .external(let e): return e.date
            }
        }
    }

    var body: some View {
        let items = (model.activity.map(Item.commit) + model.externalLog.map(Item.external)).sorted { $0.date > $1.date }
        let current = items.first { $0.id == selected } ?? items.first
        let days = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.date) }
        HStack(spacing: 0) {
            ListColumn(strong: L("紀錄"), rest: items.isEmpty ? L("尚無紀錄。") : L("\(items.count) 筆紀錄。")) {
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    let list = days[day]!
                    GroupHeader(title: dayTitle(day), n: list.count)
                    ForEach(list) { item in row(item, isSelected: item.id == current?.id) }
                }
            } footer: { EmptyView() }
            DetailPane {
                if let current { ActivityDetail(item: current).id(current.id) } else { EmptyDetail(title: L("尚無紀錄"), text: L("之後的每次變更都會記錄在此，並可恢復。")) }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return L("今天") }
        if Calendar.current.isDateInYesterday(day) { return L("昨天") }
        return day.formatted(.dateTime.month().day())
    }

    @ViewBuilder
    private func row(_ item: Item, isSelected: Bool) -> some View {
        switch item {
        case .commit(let e):
            let who = actorInfo(e.actor)
            TileRow(icon: icon(for: e.op), color: who.color, isSelected: isSelected, namespace: ns) {
                HStack {
                    Text(e.title).font(.system(size: 13, weight: .semibold)).strikethrough(e.undone).lineLimit(1)
                    Spacer()
                    Text(e.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.ink3)
                }
                .frame(height: 19)
                Text(who.name + (e.undone ? L(" · 已恢復") : e.canUndo ? L(" · 可以恢復") : ""))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(who.color).frame(height: 16).padding(.top, 2)
            }
            .opacity(e.undone ? 0.6 : 1)
            .onTapGesture { withAnimation(Theme.spring) { selected = item.id } }
        case .external(let x):
            TileRow(icon: "M8 2 14.5 13.5h-13zM8 6.5v3M8 11.5v.2", color: Theme.amber, isSelected: isSelected, namespace: ns) {
                HStack {
                    Text("\(x.name) 在外部被修改").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(x.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.ink3)
                }
                .frame(height: 19)
                Text("來源未知").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.amber).frame(height: 16).padding(.top, 2)
            }
            .onTapGesture { withAnimation(Theme.spring) { selected = item.id } }
        }
    }

    private func icon(for op: JournalOp?) -> String {
        switch op {
        case .toggle: return "M3 8h10M9 4l4 4-4 4"
        case .remove, .projectRemove: return "M3 5h10M6 5V3.5h4V5M4.5 5l.8 8.5h5.4l.8-8.5"
        case .update: return "M8 2a6 6 0 1 0 .01 0M8 5v6M5.5 8.5 8 11l2.5-2.5"
        case .undo: return "M4 6h6a3 3 0 0 1 0 6H6M4 6l2.5-2.5M4 6l2.5 2.5"
        default: return "M8 3v10M3 8h10"
        }
    }

    func actorInfo(_ actor: String) -> (name: String, color: Color) {
        if actor == "gui" { return (L("你"), Theme.brand) }
        if actor.hasPrefix("cli:") {
            let id = String(actor.dropFirst(4))
            if let a = model.adapter(id) { return (a.name, Color(hex: AgentLogo.color(a))) }
            return (id, Theme.ink2)
        }
        return (L("來源未知"), Theme.amber)
    }
}

struct ActivityDetail: View {
    @Environment(AppModel.self) private var model
    let item: ActivityView.Item
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    switch item {
                    case .commit(let e):
                        Text(who(e.actor) + " · " + e.date.formatted(date: .long, time: .shortened))
                            .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                        Text(e.title).font(.system(size: 30, weight: .bold, design: .serif)).tracking(-0.54)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(e.undone ? L("此紀錄已恢復。") : e.canUndo ? L("恢復前會先列出受影響的檔案，確認後才執行。") : L("此紀錄無法恢復。"))
                            .font(.system(size: 13.5)).foregroundStyle(Theme.ink2)
                        Text(L("紀錄編號 ") + String(e.id.prefix(7))).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink3)
                            .padding(.top, 20)
                    case .external(let x):
                        Text(L("來源未知 · ") + x.date.formatted(date: .long, time: .shortened)).font(.system(size: 12)).foregroundStyle(Theme.amber)
                        Text("\(x.name) 在 Tackroom 外部被修改").font(.system(size: 30, weight: .bold, design: .serif)).tracking(-0.54)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("無法判斷變更來源。可在該 skill 頁面恢復，或保留目前內容。")
                            .font(.system(size: 13.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(EdgeInsets(top: 58, leading: 40, bottom: 90, trailing: 40))
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 6)
            }
            switch item {
            case .commit(let e) where e.canUndo:
                ActionDock { PillButton(title: L("恢復…"), primary: true) { model.propose { $0.planUndo(e) } } }
            case .external(let x):
                ActionDock {
                    PillButton(title: L("查看 skill")) { model.selection = .overview; model.selectedSkill = x.name }
                }
            default:
                EmptyView()
            }
        }
        .onAppear { withAnimation(Theme.ease) { appeared = true } }
    }

    private func who(_ actor: String) -> String {
        if actor == "gui" { return L("你") }
        if actor.hasPrefix("cli:") { return model.adapter(String(actor.dropFirst(4)))?.name ?? String(actor.dropFirst(4)) }
        return L("來源未知")
    }
}
