import AppKit
import Sparkle

/// Sparkle's update flow for an agent app.
///
/// ClaudeMenu is `LSUIElement`, so it has no Dock icon and never becomes the active
/// application on its own. Sparkle's dialogs are ordinary windows: shown as-is they
/// would open behind whatever the user is working in, with nothing in the Dock or the
/// app switcher to bring them forward, and the update would look like it hung.
///
/// So the app switches to `.regular` for the duration of an update session and returns
/// to `.accessory` when it ends.
@MainActor
final class UpdaterController: ObservableObject {
    /// Mirrors `updater.canCheckForUpdates` so the menu row can disable itself while a
    /// check is already running.
    @Published private(set) var canCheck = true

    private let controller: SPUStandardUpdaterController
    private let driverDelegate = ActivationPolicyDelegate()
    private var observation: NSKeyValueObservation?

    /// `starting: false` builds the object without launching Sparkle, for the layout
    /// diagnostics, which must not fire an update check.
    init(starting: Bool = true) {
        controller = SPUStandardUpdaterController(
            startingUpdater: starting,
            updaterDelegate: nil,
            userDriverDelegate: driverDelegate
        )
        // Check in the background, but never download or install without consent:
        // a silent install would kill the running app from under the user.
        guard starting else { return }
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = false
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// The version string Sparkle compares against the feed, shown in the panel.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

/// Raises the app to a regular, activatable application while Sparkle shows anything,
/// and lowers it back afterwards.
private final class ActivationPolicyDelegate: NSObject, SPUStandardUserDriverDelegate {
    private var raised = false

    func standardUserDriverWillShowModalAlert() { raise() }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        raise()
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {}

    func standardUserDriverWillFinishUpdateSession() { lower() }

    private func raise() {
        guard !raised else { return }
        raised = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func lower() {
        guard raised else { return }
        raised = false
        NSApp.setActivationPolicy(.accessory)
    }
}
