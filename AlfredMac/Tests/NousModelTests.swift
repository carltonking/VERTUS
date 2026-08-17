// swift-tools-version: 5.9
import XCTest
import AlfredMacApp

/// Guards the NOUS-only model contract: the default model must be one of the
/// models listed in `NousModel`, and the persisted selection must round-trip
/// through UserDefaults under `alfred.selectedNousModel`.
final class NousModelTests: XCTestCase {

    func testNousModelListIsNonEmpty() {
        XCTAssertFalse(NousModel.allCases.isEmpty)
    }

    func testDefaultModelIsSolarPro4FreeMax() {
        XCTAssertEqual(AlfredModelConfig.defaultValue.selectedModel, .solarPro4FreeMax)
    }

    func testSelectedModelRoundTripsThroughUserDefaults() {
        let original = AlfredModelConfig.load()
        let picked = NousModel.longcat2FreeMax
        var config = original
        config.selectedModel = picked
        config.save()

        let loaded = AlfredModelConfig.load()
        XCTAssertEqual(loaded.selectedModel, picked)

        // Restore the original so the suite doesn't poison later runs.
        config.selectedModel = original.selectedModel
        config.save()
    }

    func testNousModelHermsModelIDMatchesRawValue() {
        for model in NousModel.allCases {
            XCTAssertEqual(model.hermesModelID, model.rawValue)
        }
    }

    func testNousModelDisplayNamesAreUnique() {
        let names = NousModel.allCases.map(\.displayName)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testSelectedModelKeyIsStable() {
        XCTAssertEqual(AlfredModelConfig.selectedModelKey, "alfred.selectedNousModel")
    }

    func testPersistedNousModelSurvivesDeleteAndReload() {
        let model = NousModel.lagunaS21FreeMax
        AlfredModelConfig(selectedModel: model).save()
        UserDefaults.standard.removeObject(forKey: AlfredModelConfig.selectedModelKey)
        XCTAssertEqual(AlfredModelConfig.load().selectedModel, model)
    }
}
