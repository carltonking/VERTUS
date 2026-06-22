import Foundation

/// Turns a natural-language task plus the Semantic Object Map into an action script in the exact
/// grammar `ComputerControlCapability` parses. Provider-agnostic: it goes through `LLMRouter`, so
/// it works identically with a cloud API key or the local model. The script is then validated by
/// `planFromActionScript` (sensitive/destructive/cap guards) and confirmed before anything runs.
struct LLMComputerControlPlanner {
    enum Outcome {
        case script(String)
        case cannot(String)
    }

    /// One iteration of the plan-act-observe loop.
    enum StepOutcome {
        case actions(String)   // the next 1-3 actions toward the goal
        case done              // goal achieved
        case cannot(String)    // can't proceed
    }

    private static let stepSystem = """
    You operate a Mac toward a GOAL over multiple steps. The screen changes after every action, so
    each turn you are shown the CURRENT clickable ELEMENTS and the actions already taken.
    Output ONLY the NEXT 1-3 actions that make progress, in this grammar (one per line, no prose):
      click element N
      double click element N
      click "label"
      type "text"
      hotkey key1 key2
      press key KEY
      wait SECONDS
    Or output exactly:
      DONE                      (the goal is already achieved — nothing left to do)
      CANNOT: <short reason>    (the goal can't be reached with these actions/elements)
    Rules: use only element numbers/labels from the current list; never invent them. Don't repeat an
    action that clearly had no effect last turn. Never type passwords/secrets/payments. Never do
    destructive/irreversible actions (delete, erase, buy, send money). Keep each step minimal.
    """

    /// Ask for the next step given the goal, the freshly-captured object map, and what's been done.
    func nextStep(goal: String, objectMap: String, history: [String], router: LLMRouter) async -> StepOutcome {
        let prompt = """
        GOAL: \(goal)

        ACTIONS TAKEN SO FAR:
        \(history.isEmpty ? "(none yet)" : history.joined(separator: "\n"))

        CURRENT ELEMENTS (clickable, in the front window):
        \(objectMap.isEmpty ? "(none detected)" : objectMap)

        NEXT:
        """

        guard let raw = try? await router.complete(prompt: prompt, system: Self.stepSystem) else {
            return .cannot("the model did not respond")
        }

        let cleaned = raw
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.uppercased() == "DONE" || cleaned.uppercased().hasPrefix("DONE\n") || cleaned.uppercased().hasPrefix("DONE ") {
            return .done
        }
        if cleaned.uppercased().hasPrefix("CANNOT") {
            let reason = cleaned.dropFirst("CANNOT".count).drop { $0 == ":" || $0 == " " }
            return .cannot(reason.isEmpty ? "the request can't be done with available on-screen actions" : String(reason))
        }
        return cleaned.isEmpty ? .done : .actions(cleaned)
    }

    private static let system = """
    You operate a Mac for the user by emitting an ACTION SCRIPT: one action per line, no prose, no markdown.
    Allowed actions ONLY:
      click element N
      double click element N
      click "label"
      type "text"
      hotkey key1 key2        (e.g. hotkey cmd t, hotkey cmd l)
      press key KEY           (e.g. press key return, press key escape)
      wait SECONDS
    Rules:
    - Use element numbers/labels strictly from the ELEMENTS list; never invent numbers.
    - Keep it minimal; at most 20 actions.
    - NEVER type passwords, payment details, or secrets. NEVER do destructive or irreversible actions (delete, erase, buy, send money, transfer).
    - If the task cannot be accomplished with these actions and the listed elements, output exactly one line: CANNOT: <short reason>
    Output ONLY the action script, or the CANNOT line. No explanation.
    """

    func plan(task: String, objectMap: String, router: LLMRouter) async -> Outcome {
        let prompt = """
        ELEMENTS (clickable, in the front window):
        \(objectMap.isEmpty ? "(none detected)" : objectMap)

        TASK: \(task)

        ACTION SCRIPT:
        """

        guard let raw = try? await router.complete(prompt: prompt, system: Self.system) else {
            return .cannot("the model did not respond")
        }

        var cleaned = raw
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.uppercased().hasPrefix("CANNOT") {
            let reason = cleaned.dropFirst("CANNOT".count).drop { $0 == ":" || $0 == " " }
            return .cannot(reason.isEmpty ? "the request can't be done with available on-screen actions" : String(reason))
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? .cannot("no actions were produced") : .script(cleaned)
    }
}
