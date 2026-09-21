import SwiftUI

@main
struct ClaudeMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var viewModel = UsageViewModel()

    var body: some Scene {
        MenuBarExtra {
            UsagePanelView()
                .environmentObject(viewModel)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text(viewModel.menuBarTitle)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Development aids, both opt-in through the environment:
///
/// - `CLAUDEMENU_DEBUG_WINDOW=1` shows the panel in a regular window.
/// - `CLAUDEMENU_SNAPSHOT=<path.png>` renders the panel off screen into a PNG and quits.
///   Nothing on the user's screen is read or captured, so it is safe to run at any time.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var debugWindow: NSWindow?
    /// Built only for the two development modes. In normal mode it stays nil, so the app
    /// runs a single `UsageViewModel` and polls Anthropic's gauge on one schedule.
    private var debugModel: UsageViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["CLAUDEMENU_SNAPSHOT"], !path.isEmpty {
            let model = UsageViewModel()
            debugModel = model
            Task { await snapshot(model, to: path) }
            return
        }
        guard env["CLAUDEMENU_DEBUG_WINDOW"] == "1" else { return }
        let model = UsageViewModel()
        debugModel = model
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ClaudeMenu (debug)"
        let hosting = NSHostingView(rootView: UsagePanelView().environmentObject(model))
        window.contentView = hosting
        // Size to the panel itself, so the debug window shows the real popover geometry.
        window.setContentSize(hosting.fittingSize)
        // The panel settles its height one layout pass after the content is measured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak window] in
            guard let window else { return }
            window.setContentSize(hosting.fittingSize)
            FileHandle.standardError.write(Data("panel size: \(hosting.fittingSize)\n".utf8))
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = window
    }

    /// Waits for the first refresh, then renders the panel with `ImageRenderer`.
    private func snapshot(_ model: UsageViewModel, to path: String) async {
        for _ in 0..<40 {
            if model.gauge != nil || model.gaugeError != nil,
               model.stats.scannedAt != .distantPast { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let dark = ProcessInfo.processInfo.environment["CLAUDEMENU_SNAPSHOT_DARK"] == "1"
        let view = UsagePanelView(scrolls: false)
            .environmentObject(model)
            // The popover's own material is not part of the view, so stand in a plain ground.
            .background(dark ? Color(white: 0.13) : Color(white: 0.96))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("snapshot written: \(path)\n".utf8))
        } else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
        }
        NSApplication.shared.terminate(nil)
    }
}
