import Foundation
import Sparkle
import Combine

final class UpdaterManager: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController
    private var cancellable: AnyCancellable?
    private var didStartUpdater = false

    init() {
        // Don't start Sparkle's scheduler synchronously in init (this runs during cold start).
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        cancellable = updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: \.canCheckForUpdates, on: self)

        // Start the scheduler one runloop turn later — off the launch critical path — so automatic
        // background update checks are preserved without blocking first paint.
        DispatchQueue.main.async { [weak self] in
            self?.startUpdater()
        }
    }

    /// Starts Sparkle's update scheduler. Sparkle requires startUpdater to run exactly once, so this
    /// is guarded and idempotent.
    func startUpdater() {
        guard !didStartUpdater else { return }
        didStartUpdater = true
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        startUpdater()
        updaterController.updater.checkForUpdates()
    }
}
