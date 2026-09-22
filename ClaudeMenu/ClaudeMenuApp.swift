import SwiftUI

@main
struct ClaudeMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var viewModel = UsageViewModel()
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        MenuBarExtra {
            UsagePanelView()
                .environmentObject(viewModel)
                .environmentObject(updater)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.menuBarSymbol)
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
    /// Diagnostics never start Sparkle: measuring a panel must not fire an update check.
    private let diagnosticUpdater = UpdaterController(starting: false)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if env["CLAUDEMENU_TIMERTEST"] == "1" { timerTest(); return }
        if env["CLAUDEMENU_MEASURE"] == "1" {
            let model = UsageViewModel()
            debugModel = model
            Task { await measure(model) }
            return
        }
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
        let hosting = NSHostingView(rootView: UsagePanelView().environmentObject(model).environmentObject(diagnosticUpdater))
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

    /// Diagnostic: which timers keep firing while the run loop tracks events, the mode an
    /// open `MenuBarExtra` popover puts the app in. Run with `CLAUDEMENU_TIMERTEST=1`.
    private func timerTest() {
        var scheduled = 0, production = 0
        // `t1` is the pattern this app used to use; `t2` is the helper it uses now, so the
        // test exercises the production code path rather than a copy of it.
        let t1 = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in scheduled += 1 }
        let t2 = UsageViewModel.repeatingTimer(every: 0.2) { production += 1 }
        let tracking = RunLoop.Mode(rawValue: "NSEventTrackingRunLoopMode")

        func spin(_ mode: RunLoop.Mode, _ label: String) {
            scheduled = 0; production = 0
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.05))
            }
            FileHandle.standardError.write(Data(
                "2s in \(label): scheduledTimer fired \(scheduled)x, app timer fired \(production)x\n".utf8))
        }
        spin(.default, ".default")
        spin(tracking, ".eventTracking")
        t1.invalidate(); t2.invalidate()
        NSApplication.shared.terminate(nil)
    }

    /// Reports the size the panel asks for, the way a popover asks for it.
    ///
    /// `MenuBarExtra(.window)` sizes its window from the SwiftUI view's ideal size, which is
    /// what `NSHostingController` publishes as `preferredContentSize` under
    /// `.preferredContentSize` sizing. `NSHostingView.fittingSize` answers differently and is
    /// not a substitute: it once reported 640pt for a panel the real popover sized to 10pt.
    private func measure(_ model: UsageViewModel) async {
        let scrolls = ProcessInfo.processInfo.environment["CLAUDEMENU_MEASURE_PLAIN"] != "1"
        let controller = NSHostingController(rootView: UsagePanelView(scrolls: scrolls).environmentObject(model).environmentObject(diagnosticUpdater))
        controller.sizingOptions = [.preferredContentSize]
        // Host it in an off-screen window so SwiftUI actually lays the view out.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.orderBack(nil)
        for _ in 0..<40 {
            if model.gauge != nil || model.gaugeError != nil,
               model.stats.scannedAt != .distantPast { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let size = controller.preferredContentSize
        // Report the data state too: a height measured while the gauge is failing describes
        // the error card, not the real panel.
        let state = model.gauge == nil
            ? "gauge unavailable"
            : "gauge ok, \(model.gauge?.weeklyMeters.count ?? 0) weekly meters, session \(model.gauge?.session == nil ? "absent" : "present")"
        FileHandle.standardError.write(Data("popover size: \(Int(size.width))x\(Int(size.height))  [\(state)]\n".utf8))
        NSApplication.shared.terminate(nil)
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
            .environmentObject(diagnosticUpdater)
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
