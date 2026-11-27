import SwiftUI
import TackroomKit
import AppKit

@main
struct TackroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Tackroom", id: "main") {
            ContentView()
                .environment(model)
                .environment(\.locale, AppLanguage.locale)
                .frame(minWidth: 900, minHeight: 540)
                .task {
                    model.applyMenuBarSetting()
                    await model.refresh()
                }
        }
        .defaultSize(width: 1180, height: 760)
        // No shared title bar: each column draws its own top, so the column
        // dividers run all the way up.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(before: .sidebar) {
                AppearanceMenu()
                Divider()
            }
            CommandGroup(after: .newItem) {
                Button("重新掃描") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Button("立即檢查更新") { model.checkUpdates() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("安裝 skill…") { model.installSource = nil; model.showingInstall = true }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.locale, AppLanguage.locale)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` has no bundle; make it a normal app with a Dock icon.
        NSApp.setActivationPolicy(.regular)
        // `-appearance dark|light` on launch, for checking both looks.
        Appearance.apply(UserDefaults.standard.string(forKey: "appearance"))
        NSApp.activate(ignoringOtherApps: true)
        // Move the traffic lights inside the floating sidebar (round 9: 14 pt from its top, 16 from its edge).
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                // Delivered on the main queue, so the window can be used there.
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    if let window { Self.placeLights(window) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.windows.forEach(Self.placeLights) }
        // Screen check in a stand-in home: `-snapshot <file.png>` saves the main
        // window as drawn, even when it is not on screen.
        if ProcessInfo.processInfo.environment["TACKROOM_HOME"] != nil,
           let out = UserDefaults.standard.string(forKey: "snapshot") {
            let delay = max(UserDefaults.standard.double(forKey: "snapshotDelay"), 6)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }),
                      let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
        }
    }

    @MainActor
    static func placeLights(_ window: NSWindow) {
        // The settings window keeps the system title bar; give it a spaced title.
        if window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
            || ["設定", "设置", "Settings"].contains(where: window.title.hasSuffix) {
            let title = L("Tackroom 設定")
            if window.title != title { window.title = title }
            return
        }
        // Only the main window has the floating sidebar the lights sit in.
        guard window.identifier?.rawValue.hasPrefix("main") == true,
              window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton), let container = close.superview else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let spacing: CGFloat = 20
        let top: CGFloat = 8 + 14  // sidebar inset + padding
        for (i, type) in buttons.enumerated() {
            guard let b = window.standardWindowButton(type) else { continue }
            let y = container.frame.height - top - b.frame.height
            b.setFrameOrigin(NSPoint(x: 8 + 16 + CGFloat(i) * spacing, y: y))
        }
    }

    // Keep running in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
