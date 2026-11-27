import SwiftUI
import AppKit
import TackroomKit

/// Menu bar item (round 9): the Tackroom mark, a red dot only when something
/// waits, a popover panel, and drop-to-install on the icon itself.
@MainActor
final class StatusController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: 28)
    private let popover = NSPopover()
    private var dropView: StatusDropView!
    private let model: AppModel
    private var observer: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = !Theme.reduceMotion
        popover.contentViewController = NSHostingController(rootView: MenuPanel(close: { [weak self] in self?.popover.performClose(nil) })
            .environment(model).environment(\.locale, AppLanguage.locale))

        guard let button = item.button else { return }
        dropView = StatusDropView(frame: button.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.onClick = { [weak self] in self?.toggle() }
        dropView.onDrop = { [weak self] url in self?.received(url) }
        dropView.onHot = { [weak self] _ in self?.redraw() }
        button.addSubview(dropView)
        button.setAccessibilityLabel("Tackroom")
        redraw()

        // Screen check in a stand-in home: `-showMenuPanel YES` opens the panel.
        if ProcessInfo.processInfo.environment["TACKROOM_HOME"] != nil, UserDefaults.standard.bool(forKey: "showMenuPanel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.toggle() }
        }
        // `-testReopen <path>`: close the main window, then drop <path> on the icon.
        if ProcessInfo.processInfo.environment["TACKROOM_HOME"] != nil,
           let path = UserDefaults.standard.string(forKey: "testReopen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }.forEach { $0.close() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.received(URL(fileURLWithPath: path)) }
        }

        // The icon itself has no badge (things waiting show inside the panel),
        // so nothing needs watching here.
    }

    func remove() {
        observer?.cancel()
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(item)
    }

    private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) } else {
            // Follow the app's light/dark look, not the menu bar's.
            popover.appearance = NSApp.effectiveAppearance
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func received(_ url: URL) {
        model.installSource = url
        model.showingInstall = true
        model.showMainWindow()
    }

    private func redraw(pop: Bool = false) {
        item.button?.image = MenuBarIcon.image(attention: false, hot: dropView?.hot ?? false)
    }
}

/// Transparent view over the status button: forwards clicks and accepts drops.
final class StatusDropView: NSView {
    var onClick: (() -> Void)?
    var onDrop: ((URL) -> Void)?
    var onHot: ((Bool) -> Void)?
    private(set) var hot = false { didSet { onHot?(hot) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hot = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hot = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hot = false
        guard let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else { return false }
        onDrop?(url)
        return true
    }
}

enum MenuBarIcon {
    /// The mark: a small house-like tag shape with a hole, drawn as a template.
    static func image(attention: Bool, hot: Bool = false) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            let s: CGFloat = 1.0
            let ox: CGFloat = 3, oy: CGFloat = 1
            if hot {
                Theme.nsColor(0xA4502A).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 22, height: 18), xRadius: 5, yRadius: 5).fill()
            }
            let p = NSBezierPath()
            p.move(to: NSPoint(x: ox + 8 * s, y: oy + 1.8 * s))
            p.line(to: NSPoint(x: ox + 13 * s, y: oy + 6 * s))
            p.line(to: NSPoint(x: ox + 13 * s, y: oy + 13.2 * s))
            p.line(to: NSPoint(x: ox + 3 * s, y: oy + 13.2 * s))
            p.line(to: NSPoint(x: ox + 3 * s, y: oy + 6 * s))
            p.close()
            p.appendOval(in: NSRect(x: ox + 6.8, y: oy + 5.1, width: 2.4, height: 2.4))
            p.lineWidth = 1.5
            p.lineJoinStyle = .round
            (hot ? NSColor.white : NSColor.labelColor).setStroke()
            p.stroke()
            if attention && !hot {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 8, y: 1, width: 7, height: 7)).fill()
            }
            return true
        }
        image.isTemplate = !attention && !hot
        return image
    }
}

/// The popover: two-tone summary, one row per kind of waiting item, the drop
/// hint, then 打開 Tackroom and 立即檢查更新.
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        let n = model.attentionCount
        VStack(alignment: .leading, spacing: 4) {
            TwoTone(strong: "Tackroom", rest: n == 0 ? L("沒有待處理事項。") : "", size: 17)
                .padding(EdgeInsets(top: 2, leading: 6, bottom: 10, trailing: 6))

            if !model.updates.isEmpty {
                let high = model.updates.filter { model.severity(of: $0) == .high }
                row(icon: "M8 2a6 6 0 1 0 .01 0M8 5v6M5.5 8.5 8 11l2.5-2.5", tint: Theme.red,
                    title: L("\(model.updates.count) 個新版本"),
                    sub: high.first.map { L("\($0.name) 有 \(model.riskSummary(of: $0))") } ?? model.updates.map(\.name).joined(separator: L("、"))) {
                    open(.updates)
                }
            }
            if !model.openDrifted.isEmpty {
                row(icon: "M8 2 14.5 13.5h-13zM8 6.5v3M8 11.5v.2", tint: Theme.amber,
                    title: L("\(model.openDrifted.count) 個在外部被修改"), sub: model.openDrifted.joined(separator: L("、"))) {
                    model.listFilter = .attention
                    open(.overview)
                }
            }
            if !model.pendingProposals.isEmpty {
                row(icon: "M2 9.5 3.8 3h8.4L14 9.5V13H2zM2 9.5h3.5l1 1.5h3l1-1.5H14", tint: Theme.ink,
                    title: L("\(model.pendingProposals.count) 個 agent 請求"),
                    sub: Set(model.pendingProposals.compactMap { model.adapter($0.agent)?.name }).sorted().joined(separator: L("、"))) {
                    open(.proposals)
                }
            }

            HStack(spacing: 10) {
                PathIcon(d: "M8 2v8M5 7l3 3 3-3M2.5 11v2.5h11V11", box: 16, size: 18, lineWidth: 1.4)
                Text("將資料夾或 .zip 拖到選單列圖示即可安裝").font(.system(size: 12))
            }
            .foregroundStyle(Theme.ink2)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pillBg)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hair, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))))
            .padding(.top, 8)

            Theme.line.frame(height: 1).padding(.vertical, 6).padding(.horizontal, 4)
            menuItem(L("打開 Tackroom"), key: "⌘O") { open(nil) }.keyboardShortcut("o")
            menuItem(model.isCheckingUpdates ? L("檢查中…") : L("立即檢查更新"), key: "") { model.checkUpdates() }
            Text(model.lastCheckProblem.map { L("無法檢查：") + $0 }
                 ?? model.lastUpdateCheck.map { L("上次檢查：") + When.text($0) + " " + $0.formatted(date: .omitted, time: .shortened) } ?? L("還沒檢查過更新"))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 2)
        }
        .padding(14)
        .frame(width: 340)
        .foregroundStyle(Theme.ink)
        .background(Theme.win.opacity(0.96))
    }

    private func row(icon: String, tint: Color, title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PathIcon(d: icon, box: 16, size: 15, lineWidth: 1.5)
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(sub).font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink2)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 9))
    }

    private func menuItem(_ title: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(key).font(.system(size: 11)).foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 7))
    }

    private func open(_ item: SidebarItem?) {
        if let item { model.selection = item }
        close()
        model.showMainWindow()
    }
}
