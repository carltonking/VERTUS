import XCTest
@testable import Alfred

/// Guards the cloud/local model-mode contract: the local default must be one
/// of the models actually installed, and its advertised context must clear
/// Hermes' hard 32K floor (it refuses to run on a model it can't give 32K of
/// context — verified live with alfred-brain).
final class ModelModeTests: XCTestCase {

    func testLocalDefaultIsOneOfTheInstalledModels() {
        XCTAssertTrue(LocalModels.all.contains(LocalModels.brain))
        XCTAssertEqual(LocalModels.all.count, 4)
    }

    func testLocalContextClearsHermesMinimum() {
        XCTAssertGreaterThanOrEqual(LocalModels.contextLength, 32_000)
    }

    func testLocalBaseURLIsOllamaEndpoint() {
        XCTAssertEqual(LocalModels.ollamaBaseURL, "http://127.0.0.1:11434/v1")
    }

    func testModelModeRoundTrips() {
        XCTAssertEqual(ModelMode(rawValue: "cloud"), .cloud)
        XCTAssertEqual(ModelMode(rawValue: "local"), .local)
        XCTAssertNil(ModelMode(rawValue: "hybrid"))
        XCTAssertEqual(ModelMode.allCases.map(\.id).count, 2)
    }

    func testCloudIsTheDefaultWhenNothingPersisted() {
        // The default must stay today's behavior: cloud.
        XCTAssertEqual(ModelMode.allCases.first, .cloud)
    }
}
