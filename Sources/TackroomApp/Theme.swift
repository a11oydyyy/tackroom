import SwiftUI
import AppKit
import TackroomKit

// Design tokens from the confirmed round-9 mockup (2026-11-26).

enum Theme {
    // Surfaces
    static let win = dynamic(0xFFFFFF, 0x1B1B1A)
    static let pane = dynamic(0xF8F8F6, 0x201F1E)
    static let side = dynamic(0xF3F3F1, 0x252423)
    static let card = dynamic(0xFFFFFF, 0x272625)
    static let soft = dynamic(0xEFEFEC, 0x2F2E2C)
    static let paper = dynamic(0xFFFEFB, 0x2B2A28)
    // Ink
    static let ink = dynamic(0x191917, 0xF0EFEB)
    static let ink2 = dynamic(0x6B6A66, 0xA2A19C)
    static let ink3 = dynamic(0x85847F, 0x8C8B86)
    // Overlays
    static let hover = dynamicA(0x000000, 0.035, 0xFFFFFF, 0.04)
    /// Hover wash laid over buttons and chips in the panes.
    static let tint = dynamicA(0x000000, 0.05, 0xFFFFFF, 0.08)
    static let sel = dynamicA(0x000000, 0.055, 0xFFFFFF, 0.07)
    static let line = dynamicA(0x000000, 0.07, 0xFFFFFF, 0.07)
    static let hair = dynamicA(0x000000, 0.08, 0xFFFFFF, 0.09)
    static let pillBg = dynamicA(0x000000, 0.05, 0xFFFFFF, 0.06)
    static let selStroke = dynamicA(0x000000, 0.13, 0xFFFFFF, 0.16)
    // Accents
    static let brand = dynamic(0xA4502A, 0xD9774F)
    static let brandSoft = dynamicA(0xA4502A, 0.32, 0xD9774F, 0.45)
    static let solid = dynamic(0x191917, 0xF0EFEB)
    static let onSolid = dynamic(0xFFFFFF, 0x1B1B1A)
    static let amber = dynamic(0xB06A00, 0xE9AD5E)
    static let red = dynamic(0xC0392B, 0xFF8D7E)
    static let green = dynamic(0x22693A, 0x7FD39A)
    static let swOff = dynamic(0xE0DFDB, 0x45443F)
    static let knob = dynamic(0xFFFFFF, 0xF3F2EE)

    // Motion (round 9): quick, light, only what changed.
    // With 「減少動態效果」 on, everything becomes a short plain fade.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var spring: Animation { reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.74) }
    static var ease: Animation { reduceMotion ? .easeInOut(duration: 0.15) : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24) }
    static var exit: Animation { reduceMotion ? .easeInOut(duration: 0.12) : .timingCurve(0.4, 0, 1, 1, duration: 0.12) }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        dynamicA(light, 1, dark, 1)
    }

    static func dynamicA(_ light: UInt32, _ la: CGFloat, _ dark: UInt32, _ da: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(isDark ? dark : light, isDark ? da : la)
        })
    }

    static func nsColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Tags: name, color (light/dark) and icon path, as in the mockup.
struct TagStyle {
    var name: String
    var caps: String
    var color: Color
    var icon: String

    /// The palette a tag's color key picks from (light, dark).
    static let colors: [String: Color] = [
        "blue": Theme.dynamic(0x3F72C4, 0x7EA6E6), "purple": Theme.dynamic(0x7C55BD, 0xB494E6),
        "green": Theme.dynamic(0x23866F, 0x6CC7B2), "orange": Theme.dynamic(0xBF6A1D, 0xEDA766),
        "red": Theme.dynamic(0xC0453A, 0xF08A80), "pink": Theme.dynamic(0xB8457E, 0xEB8DBA),
        "teal": Theme.dynamic(0x1F7F95, 0x6CC2D6), "gray": Theme.dynamic(0x6B6A66, 0xA2A19C),
    ]
    static let colorNames: [String: String] = [
        "blue": L("藍"), "purple": L("紫"), "green": L("綠"), "orange": L("橘"), "red": L("紅"), "pink": L("粉紅"), "teal": L("青"), "gray": L("灰"),
    ]

    /// The mockup's four tags keep their own icons and English caps, under
    /// their Traditional Chinese names and the names they start with in the
    /// current language (a book made in another language keeps its names).
    private static let presets: [String: (caps: String, icon: String)] = {
        var all = sourcePresets
        for (name, value) in sourcePresets { all[String(localized: String.LocalizationValue(name))] = value }
        return all
    }()
    private static let sourcePresets: [String: (caps: String, icon: String)] = [
        "自動化": ("AUTOMATION", "M11 2.5 4.5 11h5l-1 6.5L15 9h-5z"),
        "寫作與文件": ("WRITING", "M4.5 15.5l.8-3.3 8-8a1.6 1.6 0 0 1 2.3 2.3l-8 8zM12 5.5l2.5 2.5"),
        "前端與設計": ("DESIGN", "M10 3a7 7 0 1 0 0 14c.9 0 1.4-.6 1.4-1.3 0-1.2.9-2 2.1-2h1.2a2.3 2.3 0 0 0 2.3-2.3C17 6.1 13.9 3 10 3zM6.8 9.3h.01M9 6.3h.01M12.6 6.8h.01"),
        "開發工具": ("DEV TOOLS", "M7.5 6 3.5 10l4 4M12.5 6l4 4-4 4"),
    ]
    /// Any other tag: a tag shape.
    static let tagIcon = "M3.5 3.5h6l7 7-6 6-7-7zM7 7h.01"

    static let untagged = TagStyle(name: L("未分類"), caps: "SKILL", color: Theme.ink2,
                                   icon: "M5.5 3h6l3 3v11h-9zM11.5 3v3h3M8 10h4.5M8 13h4.5")

    static func of(_ tag: String?, colorKey: String?) -> TagStyle {
        guard let tag else { return untagged }
        let preset = presets[tag]
        return TagStyle(name: tag, caps: preset?.caps ?? tag.uppercased(),
                        color: colors[colorKey ?? "gray"] ?? Theme.ink2, icon: preset?.icon ?? tagIcon)
    }
}

// MARK: - Small components

/// Draws an SVG-style path ("M x y L …", with C, Q, A, z) in a 20×20 (or given) box.
struct PathIcon: View {
    let d: String
    var box: CGFloat = 20
    var size: CGFloat = 20
    var lineWidth: CGFloat = 1.7
    var filled = false

    var body: some View {
        SVGPath(d: d, box: box)
            .stroke(style: StrokeStyle(lineWidth: lineWidth * size / box, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// Minimal SVG path parser (M L H V C Q A Z, absolute and relative) for the mockup's icons.
struct SVGPath: Shape {
    let d: String
    let box: CGFloat

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / box
        var p = Path()
        var tokens = tokenize(d)[...]
        var cur = CGPoint.zero, start = CGPoint.zero
        var cmd: Character = "M"
        func num() -> CGFloat { CGFloat(Double(tokens.popFirst() ?? "0") ?? 0) }
        func pt(_ rel: Bool) -> CGPoint { let x = num(), y = num(); return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
        func s(_ q: CGPoint) -> CGPoint { CGPoint(x: rect.minX + q.x * scale, y: rect.minY + q.y * scale) }
        while let t = tokens.first {
            if let c = t.first, c.isLetter { cmd = c; tokens.removeFirst() }
            let rel = cmd.isLowercase
            switch cmd.uppercased().first! {
            case "M":
                cur = pt(rel); start = cur; p.move(to: s(cur)); cmd = rel ? "l" : "L"
            case "L":
                cur = pt(rel); p.addLine(to: s(cur))
            case "H":
                let x = num(); cur.x = rel ? cur.x + x : x; p.addLine(to: s(cur))
            case "V":
                let y = num(); cur.y = rel ? cur.y + y : y; p.addLine(to: s(cur))
            case "C":
                let c1 = pt(rel), c2 = pt(rel), e = pt(rel)
                p.addCurve(to: s(e), control1: s(c1), control2: s(c2)); cur = e
            case "Q":
                let c1 = pt(rel), e = pt(rel)
                p.addQuadCurve(to: s(e), control: s(c1)); cur = e
            case "A":
                let rx = num(), _ = num(), _ = num(), large = num(), sweep = num()
                let e = pt(rel)
                addArc(&p, from: cur, to: e, r: rx, large: large != 0, sweep: sweep != 0, map: s)
                cur = e
            case "Z":
                p.closeSubpath(); cur = start
                if tokens.first.map({ !($0.first?.isLetter ?? false) }) == true { tokens.removeFirst() }
            default:
                tokens.removeFirst()
            }
        }
        return p
    }

    private func tokenize(_ d: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in d {
            if ch.isLetter && ch != "e" {
                if !cur.isEmpty { out.append(cur); cur = "" }
                out.append(String(ch))
            } else if ch == " " || ch == "," {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else if ch == "-" && !cur.isEmpty && cur.last != "e" {
                out.append(cur); cur = "-"
            } else if ch == "." && cur.contains(".") {
                out.append(cur); cur = "."
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Circular-arc approximation (icons only use circles).
    private func addArc(_ p: inout Path, from a: CGPoint, to b: CGPoint, r: CGFloat, large: Bool, sweep: Bool,
                        map: (CGPoint) -> CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        let d = max(hypot(dx, dy), 0.0001)
        let radius = max(r, d / 2)
        let h = sqrt(max(radius * radius - d * d / 4, 0))
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let sign: CGFloat = (large == sweep) ? -1 : 1
        let center = CGPoint(x: mid.x + sign * h * (-dy) / d, y: mid.y + sign * h * dx / d)
        let start = atan2(a.y - center.y, a.x - center.x)
        let end = atan2(b.y - center.y, b.x - center.x)
        let mc = map(center)
        let scale = map(CGPoint(x: 1, y: 0)).x - map(.zero).x
        p.addArc(center: mc, radius: radius * scale, startAngle: .radians(start), endAngle: .radians(end), clockwise: !sweep)
    }
}

/// Agent mark: a small rounded square with two letters, as in the mockup.
struct AgentLogo: View {
    let adapter: HarnessAdapter
    var size: CGFloat = 16

    var body: some View {
        Text(Self.letters(adapter))
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color(hex: Self.color(adapter))))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(Theme.dynamicA(0x000000, 0.12, 0xFFFFFF, 0.28), lineWidth: 0.5))
            .help(adapter.name)
            .accessibilityLabel(adapter.name)
    }

    static func letters(_ a: HarnessAdapter) -> String {
        switch a.id {
        case "claude-code": return "CC"
        case "codex": return "Cx"
        case "antigravity": return "AG"
        case "deepseek": return "DS"
        case "cursor": return "Cu"
        case "opencode": return "OC"
        case "gemini-cli": return "Ge"
        case "copilot": return "Co"
        case "devin": return "Dv"
        default: return String(a.shortName.prefix(2))
        }
    }

    static func color(_ a: HarnessAdapter) -> String {
        switch a.id {
        case "claude-code": return "#D97757"
        case "codex": return "#2A2A2A"
        case "antigravity": return "#4A78D8"
        case "deepseek": return "#5163D6"
        default: return a.accentHex
        }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0x8E8E93
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Count pill in the sidebar; `hot` uses the brand color and pops in once.
struct CountPill: View {
    let n: Int
    var hot = false
    @State private var shown = false

    var body: some View {
        Text("\(n)")
            .font(.system(size: 10.5, weight: hot ? .bold : .regular).monospacedDigit())
            .foregroundStyle(hot ? Color.white : Theme.ink2)
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 5).fill(hot ? Theme.brand : Theme.pillBg))
            .scaleEffect(hot && !shown ? 0.01 : 1)
            .contentTransition(.numericText())
            .onAppear { withAnimation(Theme.spring.delay(0.3)) { shown = true } }
    }
}

/// Two-tone heading: the first part in ink, the rest in the light gray.
/// Two-line heading. Headings carry no closing 「。」 (dropped here, so
/// every page follows the same rule).
struct TwoTone: View {
    let strong: String
    let rest: String
    var size: CGFloat = 22

    init(strong: String, rest: String, size: CGFloat = 22) {
        func bare(_ s: String) -> String { s.hasSuffix("。") || s.hasSuffix(".") ? String(s.dropLast()) : s }
        self.strong = bare(strong)
        self.rest = bare(rest)
        self.size = size
    }

    var body: some View {
        (Text(strong).foregroundStyle(Theme.ink) + Text(rest.isEmpty ? "" : "\n" + rest).foregroundStyle(Theme.ink3))
            .font(.system(size: size, weight: .semibold))
            .tracking(-0.012 * size)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The mockup's switch: brand when on, springy knob; read-only shakes.
struct BrandSwitch: View {
    let isOn: Bool
    var readOnly = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.brand : Theme.swOff)
                Circle().fill(Theme.knob)
                    .frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .padding(2)
            }
            .frame(width: 32, height: 19)
            .opacity(readOnly ? 0.38 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 3 * sin(amount * .pi * 4), y: 0))
    }
}

extension View {
    /// Card surface: white, rounded, hairline and soft lift.
    func card(_ radius: CGFloat = 12) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card)
            .shadow(color: .black.opacity(0.04), radius: 7, y: 2)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5)))
    }

    /// Lets the user drag the window by this view (the title bar is hidden).
    @ViewBuilder
    func dragsWindow() -> some View {
        if #available(macOS 15.0, *) {
            self.gesture(WindowDragGesture())
        } else {
            self
        }
    }
}

/// Relative time in plain words.
enum When {
    static func text(_ date: Date?) -> String {
        guard let date else { return "" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date),
                                                   to: Calendar.current.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<1: return L("今天")
        case 1: return L("昨天")
        case 2...6: return L("\(days) 天前")
        case 7...13: return L("上週")
        case 14...29: return L("\(days / 7) 週前")
        case 30...364: return L("\(days / 30) 個月前")
        default: return L("\(days / 365) 年前")
        }
    }
}

// MARK: Scroll-aware top fade

/// How far a pane's scroll content has moved up.
struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    /// On the content inside a ScrollView that has `.tracksScroll`.
    func scrollProbe() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: ScrollOffsetKey.self, value: g.frame(in: .named("paneScroll")).minY)
        })
    }

    /// On the ScrollView: `scrolled` turns true once the content has moved up.
    func tracksScroll(_ scrolled: Binding<Bool>) -> some View {
        coordinateSpace(name: "paneScroll")
            .onPreferenceChange(ScrollOffsetKey.self) { y in
                let moved = y < -2
                if scrolled.wrappedValue != moved { scrolled.wrappedValue = moved }
            }
    }
}

/// The fade under a pane's top buttons. It only shows once the content has
/// scrolled, so text sitting at the top at rest is never washed out by it.
struct TopFade: View {
    var visible: Bool

    var body: some View {
        LinearGradient(stops: [.init(color: Theme.pane, location: 0.45), .init(color: Theme.pane.opacity(0), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 56)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: visible)
            .allowsHitTesting(false)
    }
}

/// A small ⓘ that shows a longer explanation on click (and on hover).
struct InfoDot: View {
    let text: String
    var size: CGFloat = 11
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: size))
                .foregroundStyle(hovering || open ? Theme.ink : Theme.ink3)
                .frame(width: size + 8, height: size + 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(text)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.ink).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(14)
        }
    }
}

// MARK: Column resizing

/// An invisible strip on a column edge: drag to resize, double-click to reset.
/// On hover the cursor changes and a thin line shows where the edge is.
struct ColumnResizer: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    var reset: CGFloat
    var showsLine = true
    /// Where the hover line sits from the strip's middle (to land on the visible edge).
    var lineOffset: CGFloat = 0
    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            if showsLine {
                Theme.selStroke.frame(width: 1).offset(x: lineOffset).opacity(hovering || start != nil ? 1 : 0)
            }
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .modifier(ResizeCursor())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil { start = width }
                    width = min(max((start ?? width) + v.translation.width, range.lowerBound), range.upperBound)
                    // Keep the arrows while dragging, even when the pointer runs ahead of the edge.
                    NSCursor.resizeLeftRight.set()
                }
                .onEnded { _ in start = nil; if !hovering { NSCursor.arrow.set() } }
        )
        .onTapGesture(count: 2) { withAnimation(Theme.spring) { width = reset } }
        .help("拖動調整寬度，按兩下恢復")
    }
}

/// The ↔ pointer over a column edge. On macOS 15+ SwiftUI keeps it in charge,
/// so the text views next to the edge can't swap it for their own cursor.
private struct ResizeCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.columnResize)
        } else {
            content.onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
        }
    }
}

/// A plain arrow pointer over floating controls that sit on top of text.
private struct ArrowPointer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.default)
        } else {
            content.onContinuousHover { phase in if case .active = phase { NSCursor.arrow.set() } }
        }
    }
}

extension View {
    func arrowPointer() -> some View { modifier(ArrowPointer()) }
}

/// The list column's width, with its resize edge on the right.
struct ListColumnFrame: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        // Never wider than leaves the detail pane its minimum.
        let room = model.windowWidth - (model.sidebarShown ? model.sidebarWidth + 8 : 0) - AppModel.detailMin
        let upper = max(AppModel.listRange.lowerBound, min(AppModel.listRange.upperBound, room))
        content
            .frame(width: model.listColumnWidth)
            .overlay(alignment: .trailing) {
                // Inside the list's own edge, clear of the detail pane's text.
                ColumnResizer(width: $model.listWidth, range: AppModel.listRange.lowerBound...upper, reset: 392, lineOffset: 3.5)
                    .offset(x: 1)
            }
            .zIndex(1)
    }
}

extension View {
    func listColumnFrame() -> some View { modifier(ListColumnFrame()) }
}


// MARK: Hover

/// Text and chip buttons in the panes: a faint wash on hover, a slight press.
/// It draws the padding, height and resting fill itself, so the wash covers
/// the whole button and not only its text.
struct HoverTint: ButtonStyle {
    var radius: CGFloat = 8
    var base: Color = .clear
    var hPad: CGFloat = 0
    var height: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        HoverTintBody(configuration: configuration, radius: radius, base: base, hPad: hPad, height: height)
    }
}

private struct HoverTintBody: View {
    let configuration: ButtonStyleConfiguration
    let radius: CGFloat
    let base: Color
    let hPad: CGFloat
    let height: CGFloat?
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .padding(.horizontal, hPad)
            .frame(height: height)
            .background(shape.fill(base))
            .overlay(shape.fill(hovering && enabled ? Theme.tint : .clear).allowsHitTesting(false))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.5)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Hover wash for buttons that draw their own shape (pills, round icons).
struct HoverWash<S: Shape>: ViewModifier {
    let shape: S
    var color: Color = Theme.tint
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(shape.fill(hovering ? color : .clear).allowsHitTesting(false))
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

extension View {
    func hoverWash<S: Shape>(_ shape: S, color: Color = Theme.tint) -> some View { modifier(HoverWash(shape: shape, color: color)) }
}
