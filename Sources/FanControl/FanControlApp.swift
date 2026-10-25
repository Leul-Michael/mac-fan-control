import CoreText
import SwiftUI

@main
struct FanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = FanModel.shared

    init() { Fonts.register() }

    var body: some Scene {
        MenuBarExtra {
            CompactPanel().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

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
