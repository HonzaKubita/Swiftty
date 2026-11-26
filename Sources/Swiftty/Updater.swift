import Foundation
import Observation
import Sparkle

/// In-app updates from Swiftty's GitHub releases, via Sparkle.
///
/// The feed (appcast.xml) is attached to the latest GitHub release, and every
/// update is checked against the EdDSA public key in Info.plist before it's installed.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    /// Updates work in builds that carry a feed and a public key (release builds).
    let isAvailable: Bool
    private(set) var canCheckForUpdates = false

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let configured = info["SUFeedURL"] != nil && info["SUPublicEDKey"] != nil
        #if DEBUG
        isAvailable = false
        #else
        isAvailable = configured
        #endif
        guard isAvailable else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        observations.append(controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        })
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
