import SwiftUI
import UniformTypeIdentifiers
import TackroomKit

/// Three columns as in the round-9 mockup: a floating sidebar, the list, and
/// the detail pane. Each column draws its own top, so dividers run to the top.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            if model.sidebarShown {
                @Bindable var model = model
                SidebarView()
                    .frame(width: model.sidebarWidth)
                    .overlay(alignment: .trailing) {
                        ColumnResizer(width: $model.sidebarWidth,
                                      range: AppModel.sidebarRange.lowerBound...max(AppModel.sidebarRange.lowerBound,
                                             min(AppModel.sidebarRange.upperBound, model.windowWidth - 8 - AppModel.listRange.lowerBound - AppModel.detailMin)),
                                      reset: 216, showsLine: false)
                            .offset(x: 4.5)
                    }
                    .padding([.leading, .vertical], 8)
                    .zIndex(2)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Group {
                switch model.selection ?? .overview {
                case .updates: UpdatesView()
                case .proposals: ProposalsView()
                case .activity: ActivityView()
                case .mcp: MCPView()
                case .docs: DocsView()
                default: SkillsPage(item: model.selection ?? .overview)
                }
            }
            // Pages cross-fade instead of snapping.
            .id(model.selection ?? .overview)
            .transition(.opacity.animation(.easeOut(duration: 0.16)))
            // With the sidebar hidden, leave room for the traffic lights.
            .padding(.top, model.sidebarShown ? 0 : 34)
        }
        .overlay(alignment: .topLeading) {
            if !model.sidebarShown {
                Button { withAnimation(Theme.spring) { model.sidebarShown = true } } label: {
                    PathIcon(d: "M2 3h12v10H2zM6 3v10", box: 16, size: 16, lineWidth: 1.3).frame(width: 26, height: 22)
                }
                .buttonStyle(HoverButtonStyle())
                .foregroundStyle(Theme.ink3)
                .help("顯示側欄")
                .padding(.leading, 96).padding(.top, 15)
            }
        }
        .background(Theme.win)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.windowWidth = g.size.width }
                .onChange(of: g.size.width) { model.windowWidth = g.size.width }
        })
        .ignoresSafeArea()
        .overlay { if dropTargeted { DropOverlay() } }
        .overlay(alignment: .bottom) { ToastView() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted.animation(Theme.ease)) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    model.installSource = url
                    model.showingInstall = true
                }
            }
            return true
        }
        .onAppear { model.openMain = { [openWindow] in openWindow(id: "main") } }
        .onChange(of: model.selection) { model.selectedSkill = nil; model.selectedSkills = []; model.selectedDoc = nil; model.listFilter = .all }
        .modifier(TagPrompts())
        // Confirmations rise from the bottom right, inside the window: no pop-up.
        .overlay(alignment: .bottomTrailing) {
            if let plan = model.proposal {
                PlanSheet(plan: plan)
                    .padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(IdentifiedPlan(plan: plan).id)
            }
        }
        .animation(Theme.spring, value: model.proposal.map { IdentifiedPlan(plan: $0).id })
        .sheet(isPresented: Binding(get: { model.showingInstall }, set: { model.showingInstall = $0 })) {
            InstallSheet().environment(model)
        }
        .alert("上次的操作未完成", isPresented: Binding(get: { model.interrupted != nil }, set: { _ in })) {
            Button("繼續完成") { model.resumeInterrupted() }
            Button("放棄", role: .destructive) { model.discardInterrupted() }
        } message: {
            Text(model.interrupted?.title ?? "")
        }
        .alert("無法完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Lets a plan drive `.sheet(item:)`.
struct IdentifiedPlan: Identifiable {
    let plan: Plan
    var id: String { plan.title + String(plan.steps.count) }
}

/// Shown while something is dragged over the window: a dashed brand frame.
struct DropOverlay: View {
    var body: some View {
        ZStack {
            Theme.win.opacity(0.86)
            VStack(spacing: 6) {
                PathIcon(d: "M8 2v8M5 7l3 3 3-3M2.5 11v2.5h11V11", box: 16, size: 26, lineWidth: 1.4)
                Text("放開以安裝").font(.system(size: 15, weight: .semibold))
                Text("安裝前會先顯示內容與風險").font(.system(size: 12)).foregroundStyle(Theme.ink2)
            }
            .foregroundStyle(Theme.brand)
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.brand, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).padding(8))
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

/// "已套用 X · 可以在 Activity 恢復": slides up, stays 2.5 s.
struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 10) {
                Text(toast)
                Text("可在「紀錄」中恢復").foregroundStyle(Color(hex: "#F0B38F")).fontWeight(.semibold)
            }
            .font(.system(size: 12))
            .foregroundStyle(Color(hex: "#F4F3EF"))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(Color(hex: "#1C1B19")).shadow(color: .black.opacity(0.2), radius: 11, y: 8))
            .padding(.bottom, 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast)
        }
    }
}

/// The few tag prompts: name a new tag, rename one, confirm deleting one.
struct TagPrompts: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert("新增標籤", isPresented: Binding(get: { model.newTagFor != nil }, set: { if !$0 { model.newTagFor = nil } })) {
                TextField("標籤名稱", text: $text)
                Button("取消", role: .cancel) { text = ""; model.newTagFor = nil }
                Button("新增") {
                    if let names = model.newTagFor, let tag = model.createTag(text), !names.isEmpty {
                        model.setTag(tag, on: true, for: names)
                    }
                    text = ""; model.newTagFor = nil
                }
            } message: {
                if let n = model.newTagFor?.count, n > 0 { Text(n == 1 ? L("新增後會套用到此 skill。") : L("新增後會套用到選取的 \(n) 個 skill。")) }
            }
            .alert("重新命名標籤", isPresented: Binding(get: { model.renamingTag != nil }, set: { if !$0 { model.renamingTag = nil } })) {
                TextField("新名稱", text: $text)
                Button("取消", role: .cancel) { text = ""; model.renamingTag = nil }
                Button("改名") {
                    if let old = model.renamingTag { model.renameTag(old, to: text) }
                    text = ""; model.renamingTag = nil
                }
            }
            .alert("刪除標籤「\(model.deletingTag ?? "")」？", isPresented: Binding(get: { model.deletingTag != nil }, set: { if !$0 { model.deletingTag = nil } })) {
                Button("取消", role: .cancel) { model.deletingTag = nil }
                Button("刪除", role: .destructive) {
                    if let t = model.deletingTag { model.deleteTag(t) }
                    model.deletingTag = nil
                }
            } message: {
                let n = model.deletingTag.map { model.tagBook.count(of: $0) } ?? 0
                Text(n == 0 ? L("僅刪除標籤，skill 本身不受影響。") : L("將從 \(n) 個 skill 移除此標籤，skill 本身不受影響。"))
            }
            .onChange(of: model.renamingTag) { if let t = model.renamingTag { text = t } }
    }
}
