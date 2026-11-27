import SwiftUI
import TackroomKit

/// Where a tag stands across the skills being edited.
enum TagState { case all, some, none }

extension AppModel {
    func tagState(_ tag: String, for names: [String]) -> TagState {
        let n = names.filter { tags(of: $0).contains(tag) }.count
        return n == 0 ? .none : n == names.count ? .all : .some
    }

    /// Clicking a tag: on for everyone unless everyone already has it.
    func toggleTag(_ tag: String, for names: [String]) {
        setTag(tag, on: tagState(tag, for: names) != .all, for: names)
    }
}

/// Menu items: every tag with a check, then 「新增標籤…」. Used in the 「…」 menu
/// and in the list's right-click menu (for one skill or the whole selection).
struct TagMenuItems: View {
    @Environment(AppModel.self) private var model
    let names: [String]

    var body: some View {
        ForEach(model.tagBook.tags, id: \.name) { tag in
            let state = model.tagState(tag.name, for: names)
            Toggle(isOn: Binding(get: { state == .all }, set: { _ in model.toggleTag(tag.name, for: names) })) {
                Text(state == .some ? L("\(tag.name)（部分）") : tag.name)
            }
        }
        Divider()
        Button("新增標籤…") { model.newTagFor = names }
    }
}

/// Small tag chip: colored dot + name.
struct TagChip: View {
    @Environment(AppModel.self) private var model
    let name: String
    var state: TagState = .all
    var removable = false
    var action: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        let style = model.style(ofTag: name)
        let label = HStack(spacing: 5) {
            Circle()
                .strokeBorder(style.color, lineWidth: state == .none ? 1.2 : 0)
                .background(Circle().fill(state == .none ? .clear : style.color).opacity(state == .some ? 0.45 : 1))
                .frame(width: 7, height: 7)
            Text(name).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(state == .none ? Theme.ink2 : Theme.ink)
            if removable && hovering {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.ink3)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 9).frame(height: 24)
        .background(Capsule().fill(state == .none ? .clear : style.color.opacity(0.11)))
        .overlay(Capsule().strokeBorder(state == .none ? Theme.hair : .clear, lineWidth: 0.5))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }

        if let action {
            Button(action: action) { label }.buttonStyle(HoverTint(radius: 12))
        } else {
            label
        }
    }
}

/// A tag on one skill. The main (first) one shows its icon, which is the icon
/// the list uses; click another to make it the main one. × takes a tag off.
struct SkillTagChip: View {
    @Environment(AppModel.self) private var model
    let skill: String
    let tag: String
    let primary: Bool
    var single = false
    @State private var hovering = false

    var body: some View {
        let style = model.style(ofTag: tag)
        HStack(spacing: 0) {
            Button {
                if !primary { model.makePrimaryTag(tag, for: skill) }
            } label: {
                HStack(spacing: 5) {
                    if primary && !single {
                        PathIcon(d: style.icon, size: 11, lineWidth: 2).foregroundStyle(style.color)
                    } else {
                        Circle().fill(style.color).frame(width: 7, height: 7)
                    }
                    Text(tag).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.ink)
                }
                .padding(.leading, 9).padding(.trailing, hovering ? 3 : 9).frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(primary ? (single ? tag : L("主要標籤：清單圖示依此顯示")) : L("設為主要標籤"))
            if hovering {
                Button { model.setTag(tag, on: false, for: [skill]) } label: {
                    Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Theme.ink2)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Theme.tint))
                        .padding(.trailing, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help("移除「\(tag)」")
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .background(Capsule().fill(style.color.opacity(primary ? 0.16 : 0.09)))
        .overlay(Capsule().strokeBorder(style.color.opacity(primary && !single ? 0.35 : 0), lineWidth: 0.8))
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hovering = h } }
    }
}

/// The detail pane's tag row: the skill's tags, then 「＋ 標籤」.
struct SkillTagRow: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var picking = false

    var body: some View {
        FlowRow(spacing: 6) {
            let tags = model.tags(of: name)
            ForEach(Array(tags.enumerated()), id: \.element) { i, tag in
                SkillTagChip(skill: name, tag: tag, primary: i == 0, single: tags.count == 1)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            Button { picking = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                    Text(model.tags(of: name).isEmpty ? L("新增標籤") : L("標籤")).font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 9).frame(height: 24)
                .overlay(Capsule().strokeBorder(Theme.selStroke, style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
            }
            .buttonStyle(HoverTint(radius: 12))
            .popover(isPresented: $picking, arrowEdge: .bottom) { TagPicker(names: [name]).environment(model) }
        }
    }
}

/// Popover: type to find or create a tag; click to put it on or take it off.
struct TagPicker: View {
    @Environment(AppModel.self) private var model
    let names: [String]
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let query = text.trimmingCharacters(in: .whitespaces)
        let shown = model.tagBook.tags.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        let exact = model.tagBook.tag(named: query) != nil

        VStack(alignment: .leading, spacing: 6) {
            TextField("搜尋或新增標籤", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pillBg))
                .focused($focused)
                .onSubmit { submit(query, exact: exact, first: shown.first?.name) }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(shown, id: \.name) { tag in
                        let state = model.tagState(tag.name, for: names)
                        Button { model.toggleTag(tag.name, for: names) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(model.style(ofTag: tag.name).color).frame(width: 8, height: 8)
                                Text(tag.name).font(.system(size: 12.5))
                                Spacer(minLength: 8)
                                if state != .none {
                                    Image(systemName: state == .all ? "checkmark" : "minus")
                                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.brand)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverTint(radius: 6, hPad: 8, height: 28))
                    }
                    if !query.isEmpty && !exact {
                        Button { submit(query, exact: false, first: nil) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                                Text("新增「\(query)」").font(.system(size: 12.5, weight: .medium))
                                Spacer()
                            }
                            .foregroundStyle(Theme.brand)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverTint(radius: 6, hPad: 8, height: 28))
                    }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 240)
        .onAppear { focused = true }
    }

    private func submit(_ query: String, exact: Bool, first: String?) {
        guard !query.isEmpty else { return }
        if exact { model.toggleTag(query, for: names) }
        else if let created = model.createTag(query) { model.setTag(created, on: true, for: names) }
        text = ""
    }
}

/// Shown when more than one skill is selected in the list.
struct BatchPanel: View {
    @Environment(AppModel.self) private var model
    let names: [String]
    let item: SidebarItem

    var body: some View {
        let allPinned = names.allSatisfy(model.isPinned)
        let adoptable = model.adoptableGroups(names, in: item)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("已選取 \(names.count) 個 skill")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                Text("批次編輯")
                    .font(.system(size: 30, weight: .bold, design: .serif)).tracking(-0.54)
                    .padding(.top, 10)
                Text(names.joined(separator: L("、")))
                    .font(.system(size: 13)).foregroundStyle(Theme.ink2).lineSpacing(4)
                    .lineLimit(3).truncationMode(.tail)
                    .padding(.top, 8)

                sectionLabel(L("標籤"), trailing: L("點選以加上或移除"))
                FlowRow(spacing: 6) {
                    ForEach(model.tagBook.tags, id: \.name) { tag in
                        TagChip(name: tag.name, state: model.tagState(tag.name, for: names)) {
                            model.toggleTag(tag.name, for: names)
                        }
                    }
                    Button { model.newTagFor = names } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                            Text("新增標籤").font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(Theme.ink2)
                    }
                    .buttonStyle(HoverTint(radius: 12, hPad: 9, height: 24))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                sectionLabel(L("其他"), trailing: nil)
                HStack(spacing: 8) {
                    if !adoptable.isEmpty {
                        PillButton(title: L("納入 Tackroom 管理（\(adoptable.count) 個）…"), primary: true) {
                            let groups = adoptable
                            model.propose { $0.planAdoptMany(groups) }
                        }
                    }
                    PillButton(title: allPinned ? L("全部取消釘選") : L("全部釘選")) {
                        withAnimation(Theme.spring) { names.forEach { model.setPinned($0, !allPinned) } }
                    }
                    PillButton(title: L("取消選取")) { model.clearMultiSelection() }
                }

                Text("⌘ 點選可加選或取消，⇧ 點選可連續選取；也可拖到左側標籤。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22).padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 44, leading: 40, bottom: 0, trailing: 40))
        }
    }

    private func sectionLabel(_ text: String, trailing: String?) -> some View {
        HStack {
            Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink2)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.ink3) }
        }
        .padding(.top, 30).padding(.bottom, 10)
    }
}

/// What follows the pointer when skills are dragged: icon and name in a small
/// card; several skills show as a short stack.
struct DragChip: View {
    let title: String
    let style: TagStyle
    var stacked = false

    var body: some View {
        ZStack {
            if stacked {
                card.rotationEffect(.degrees(-4)).offset(x: -3, y: 3).opacity(0.55)
            }
            card
        }
        .padding(10)
    }

    private var card: some View {
        HStack(spacing: 8) {
            PathIcon(d: style.icon, size: 13, lineWidth: 1.8)
                .foregroundStyle(style.color)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(style.color.opacity(0.14)))
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
        }
        .padding(.leading, 6).padding(.trailing, 12).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card)
            .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hair, lineWidth: 0.5)))
    }
}
