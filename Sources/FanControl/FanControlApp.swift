import CoreText
import SwiftUI

@main
struct FanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = FanModel.shared

    init() { Fonts.register() }

    var body: some Scene {
        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            #if DEBUG
            Snapshot.runIfRequested()
            #endif
            StatusItem.shared.install()
            PanelWindow.shared.show()
        }
    }

    /// Clicking the app again (Finder, Spotlight) brings the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { PanelWindow.shared.show() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { FanModel.shared.releaseOnQuit() }
    }

    /// Closing the window keeps the app in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

#if DEBUG
/// Debug builds: `FanControl --snapshot <file.png>` renders the panel to an image and exits.
enum Snapshot {
    @MainActor static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let demo = args.contains("--demo")
        if demo {
            FanModel.shared.previewRules([0: .sensor(id: "cpu-hot", startCelsius: 50, fullCelsius: 85), 1: .constant(rpm: 3600)])
        }
        let renderer = ImageRenderer(content: CompactPanel(scrolls: false, open: demo ? "fans" : nil).environment(FanModel.shared).environment(\.colorScheme, .dark))
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
        }
        exit(0)
    }
}
#endif

/// Registers the bundled font files for this process.
enum Fonts {
    static func register() {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
        // `swift run` has no app bundle: fall back to the fonts in the source tree.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Fonts").standardized
        for dir in [bundled, source].compactMap({ $0 }) {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "ttf" } ?? []
            guard !files.isEmpty else { continue }
            CTFontManagerRegisterFontURLs(files as CFArray, .process, true, nil)
            return
        }
    }
}

/// Borderless windows normally cannot take keyboard focus; the panel needs it for its menus and dialogs.
final class PanelNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The main panel in a borderless window: our own 8 pt corners instead of the system's large ones, and a
/// window pinned to the panel's exact size, so there is no strip above or below the content.
@MainActor
final class PanelWindow {
    static let shared = PanelWindow()
    static let radius: CGFloat = 8
    private var window: NSWindow?

    func show() {
        if window == nil {
            let root = CompactPanel(inWindow: true)
                .environment(FanModel.shared)
                .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
            let host = NSHostingView(rootView: root)
            host.safeAreaRegions = []
            host.sizingOptions = [.minSize, .maxSize]
            let w = PanelNSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            w.title = "Fan Control"
            w.isOpaque = false
            w.backgroundColor = .clear   // the rounded panel itself is the window's shape
            w.hasShadow = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            // Appear on whichever Space is active (desktop or a full-screen app), not the one it was first opened on.
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.contentView = host
            w.center()
            w.setFrameAutosaveName("FanControlPanel")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Menu bar item: an outlined fan icon with a Windscribe-style dropdown (power, presets, show app, quit).
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    static let shared = StatusItem()
    private var item: NSStatusItem?

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "fan", accessibilityDescription: "Fan Control")
        image?.isTemplate = true   // follows the menu bar's light or dark appearance
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self       // rebuilt each time it opens, so it shows the current state
        item.menu = menu
        self.item = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    private func rebuild(_ menu: NSMenu) {
        let model = FanModel.shared
        menu.removeAllItems()

        var status: [String] = []
        if let t = model.celsius("cpu-hot") { status.append("CPU \(Format.celsius(t))") }
        if !model.fans.isEmpty { status.append(model.fans.allSatisfy { $0.rpm < 50 } ? "fans idle" : model.fans.map { Format.shortRPM($0.rpm) }.joined(separator: " / ") + " rpm") }
        let info = NSMenuItem(title: status.joined(separator: " · "), action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())

        if model.helperInstalled {
            menu.addItem(action(model.isOn ? "Turn Off" : "Turn On") { FanModel.shared.togglePower() })
        } else {
            menu.addItem(action("Install Helper…") { FanModel.shared.installHelper() })
        }
        let presets = NSMenu()
        for preset in model.presets {
            let entry = action(preset.name) { FanModel.shared.apply(preset) }
            entry.state = preset.id == model.activePresetID ? .on : .off
            presets.addItem(entry)
        }
        let presetsItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presetsItem.submenu = presets
        menu.addItem(presetsItem)
        menu.addItem(.separator())

        menu.addItem(action("Show App") { PanelWindow.shared.show() })
        menu.addItem(action("Settings…", key: ",") {
            NSApp.activate()
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        })
        menu.addItem(.separator())
        menu.addItem(action("Quit Fan Control", key: "q") { NSApp.terminate(nil) })
    }

    private func action(_ title: String, key: String = "", _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.runAction), keyEquivalent: key)
        let target = MenuAction(run)
        item.target = target
        item.representedObject = target   // keeps the target alive as long as the item
        return item
    }
}

/// Lets a menu item run a closure.
@MainActor
final class MenuAction: NSObject {
    private let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    @objc func runAction() { run() }
}
