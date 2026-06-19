import Foundation
import Sparkle
import Combine

final class UpdaterManager: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController
    private var cancellable: AnyCancellable?

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        cancellable = updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: \.canCheckForUpdates, on: self)
    }

    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }
}
