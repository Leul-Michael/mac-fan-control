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

/// The main panel in a plain AppKit window. The hosting view ignores the (invisible) title bar area and
/// pins the window to the panel's exact size, so there is no strip above or below the content.
@MainActor
final class PanelWindow {
    static let shared = PanelWindow()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    /// Menu bar click: hide when showing, otherwise appear just below the status item.
    func toggle(below anchor: NSRect?) {
        if isVisible && window?.isKeyWindow == true { window?.orderOut(nil); return }
        show()
        if let anchor, let window {
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            var origin = NSPoint(x: anchor.midX - window.frame.width / 2, y: anchor.minY - window.frame.height - 6)
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - window.frame.width - 8)
            window.setFrameOrigin(origin)
        }
    }

    func show() {
        if window == nil {
            let host = NSHostingView(rootView: CompactPanel(inWindow: true).environment(FanModel.shared))
            host.safeAreaRegions = []
            host.sizingOptions = [.minSize, .maxSize]
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Fan Control"
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(Theme.background)
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(button)?.isHidden = true   // the panel draws its own dots
            }
            w.contentView = host
            w.center()
            w.setFrameAutosaveName("FanControlPanel")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Menu bar item: fan glyph, a temperature and the fan speed; clicking it shows or hides the panel window.
@MainActor
final class StatusItem: NSObject {
    static let shared = StatusItem()
    private var item: NSStatusItem?
    private var timer: Timer?

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.imagePosition = .imageLeading
        self.item = item
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { StatusItem.shared.update() }
        }
    }

    private func update() {
        guard let button = item?.button else { return }
        let model = FanModel.shared
        button.image = NSImage(systemSymbolName: model.isOn ? "fan.fill" : "fan", accessibilityDescription: "Fan Control")
        var parts: [String] = []
        if !model.menuBarSensor.isEmpty, let t = model.celsius(model.menuBarSensor) { parts.append(Format.celsius(t)) }
        if model.menuBarShowsRPM, let rpm = model.fans.map(\.rpm).max() { parts.append(Format.shortRPM(rpm)) }
        let title = parts.isEmpty ? "" : " " + parts.joined(separator: " ")
        if button.title != title {
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        }
    }

    @objc private func clicked() {
        guard let button = item?.button, let window = button.window else { return PanelWindow.shared.toggle(below: nil) }
        PanelWindow.shared.toggle(below: window.convertToScreen(button.convert(button.bounds, to: nil)))
    }
}
