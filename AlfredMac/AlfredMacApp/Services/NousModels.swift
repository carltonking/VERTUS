//
//  NousModels.swift
//  AlfredMacApp
//
//  The NOUS Portal models offered in the sessions prompt bar's model menu,
//  and the persisted selection. Hermes authenticates NOUS from its own
//  credential pool (~/.hermes/auth.json); neither surface stores a key.
//
//  The selection is persisted under `alfred.selectedNousModel`, the same key
//  the menu-bar app reads when it writes Hermes' config — so picking a model
//  here is picked up on the Mac's next turn.
//

import Foundation

/// The NOUS Portal models, identical to the menu-bar app's registry so the two
/// surfaces present the same list.
public enum NousModel: String, CaseIterable, Identifiable, Sendable, Codable {
    case solarPro4FreeMax = "solar-pro4-free"
    case longcat2FreeMax = "longcat-2.0-free"
    case hy3FreeMax = "hy3-free"
    case lagunaS21FreeMax = "laguna-s-2.1-free"
    case step37FlashFreeMax = "step-3.7-flash-free"
    case lagunaXs21FreeMax = "laguna-xs-2.1-free"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .solarPro4FreeMax: return "Solar Pro 4"
        case .longcat2FreeMax: return "Longcat 2.0"
        case .hy3FreeMax: return "Hy3"
        case .lagunaS21FreeMax: return "Laguna S 2.1"
        case .step37FlashFreeMax: return "Step 3.7 Flash"
        case .lagunaXs21FreeMax: return "Laguna Xs 2.1"
        }
    }

    public var hermesModelID: String { rawValue }
}

/// The shared model choice, persisted under `alfred.selectedNousModel` — the
/// menu-bar app reads the same key when it writes Hermes' config.
public struct AlfredModelConfig: Sendable, Codable {
    public var selectedModel: NousModel

    public static var defaultValue: AlfredModelConfig { AlfredModelConfig(selectedModel: .solarPro4FreeMax) }

    public static func load() -> AlfredModelConfig {
        if let raw = UserDefaults.standard.string(forKey: selectedModelKey),
           let model = NousModel(rawValue: raw) {
            return AlfredModelConfig(selectedModel: model)
        }
        return .defaultValue
    }

    public func save() {
        UserDefaults.standard.set(selectedModel.rawValue, forKey: AlfredModelConfig.selectedModelKey)
    }

    public static let selectedModelKey = "alfred.selectedNousModel"
}
