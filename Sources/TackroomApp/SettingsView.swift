import SwiftUI
import TackroomKit

/// Read-only for now: shows where each agent's skills are read from and
/// where to override them.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("一般") {
                LanguagePicker()
                AppearancePicker()
                Toggle("在選單列顯示 Tackroom 圖示", isOn: $model.menuBarOn)
                Text("可將資料夾或 .zip 拖到圖示上安裝。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("依對話紀錄統計常用 skill", isOn: $model.usageCounting)
                Text("僅統計近 30 天各 skill 的使用次數，不保存或傳送對話內容。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(model.dismissed.keys.isEmpty ? L("沒有已忽略的提醒") : L("已忽略的提醒：\(model.dismissed.keys.count) 個"))
                    Spacer()
                    Button("全部恢復") { model.restoreAllDismissed() }.disabled(model.dismissed.keys.isEmpty)
                }
            }
            Section("Agent 資料夾") {
                ForEach(model.adapters) { adapter in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            AgentLogo(adapter: adapter, size: 18)
                            Text(adapter.name).font(.headline)
                        }
                        ForEach(adapter.roots, id: \.self) { root in
                            Text("\(root.scope == .global ? L("全域") : L("專案"))\(root.role == .builtin ? L("（附帶）") : root.role == .legacy ? L("（舊位置）") : "")：\(root.path)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("Agent 命令列工具") {
                CLIInstallRow()
            }
            Section {
                Text("要改路徑或新增 agent，編輯 \(Paths.abbreviate(AdapterConfig.defaultURL.path))，再按「重新掃描」。")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
    }
}

/// Links `~/.local/bin/tackroom` to the copy inside the app (no admin password needed).
struct CLIInstallRow: View {
    @State private var message: String?

    private var bundled: String? { Bundle.main.path(forResource: "tackroom", ofType: nil) }
    private var linkPath: String { Paths.expand("~/.local/bin/tackroom") }
    private var installed: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == bundled }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(installed ? L("已安裝：~/.local/bin/tackroom") : L("Agent 可透過 `tackroom` 查詢 skill 及送出請求。"))
                Spacer()
                Button(installed ? L("重新安裝") : L("安裝")) { install() }
                    .disabled(bundled == nil)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if bundled == nil {
                Text("從 build/Tackroom.app 打開時才能安裝。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func install() {
        guard let bundled else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: (linkPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            // Replace only an older link to a Tackroom app; leave anything else alone.
            if let old = try? fm.destinationOfSymbolicLink(atPath: linkPath), old.contains("Tackroom.app/") {
                try fm.removeItem(atPath: linkPath)
            }
            guard !fm.fileExists(atPath: linkPath) else {
                message = L("~/.local/bin/tackroom 已經是別的檔案，沒有覆蓋。")
                return
            }
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: bundled)
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            message = path.contains("/.local/bin") ? L("完成。") : L("已完成。若終端機找不到 tackroom，請將 ~/.local/bin 加入 PATH。")
        } catch {
            message = L("安裝失敗：\(error.localizedDescription)")
        }
    }
}

/// 跟隨系統／淺色／深色, stored under "appearance".
enum Appearance {
    static let choices: [(key: String, title: String)] = [("system", L("跟隨系統")), ("light", L("淺色")), ("dark", L("深色"))]

    @MainActor static func apply(_ key: String?) {
        switch key {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }
}

struct AppearancePicker: View {
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        Picker("外觀", selection: $appearance) {
            ForEach(Appearance.choices, id: \.key) { Text($0.title).tag($0.key) }
        }
        .onChange(of: appearance) { Appearance.apply(appearance) }
    }
}

/// 語言：跟隨系統／繁體中文／简体中文／English. macOS reads an app's language
/// once at launch, so the choice applies after Tackroom starts again.
struct LanguagePicker: View {
    @State private var chosen = AppLanguage.chosen
    private let atLaunch = AppLanguage.chosen

    var body: some View {
        Picker("語言", selection: $chosen) {
            ForEach(AppLanguage.choices, id: \.code) { Text($0.name).tag($0.code) }
        }
        .onChange(of: chosen) { AppLanguage.chosen = chosen }
        if chosen != atLaunch {
            HStack {
                Text("重新開啟 Tackroom 後套用。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("立即重新開啟") { Relaunch.now() }
            }
        }
    }
}

/// Starts a fresh copy of the app, then quits this one.
enum Relaunch {
    @MainActor static func now() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// View menu: 外觀 ▸ 跟隨系統／淺色／深色.
struct AppearanceMenu: View {
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        Picker("外觀", selection: Binding(get: { appearance }, set: { appearance = $0; Appearance.apply($0) })) {
            ForEach(Appearance.choices, id: \.key) { Text($0.title).tag($0.key) }
        }
    }
}
