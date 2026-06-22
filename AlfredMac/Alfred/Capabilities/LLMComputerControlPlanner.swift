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

    /// Turn a provider error into something actionable. The most common failure is the local model
    /// (Ollama) not running, which otherwise surfaced as a useless "the model did not respond".
    static func friendlyError(_ error: Error) -> String {
        if let urlError = error as? URLError,
           [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost].contains(urlError.code) {
            return "couldn't reach the AI provider — if you're using the local model, make sure Ollama is running (run `ollama serve`); otherwise check your API key and connection"
        }
        return error.localizedDescription
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
    Output ONLY the NEXT 1-3 actions that make progress (no prose), using this grammar:
    \(grammar)
    Or output exactly one of:
      DONE                      (the goal is already achieved — nothing left to do)
      CANNOT: <short reason>    (the goal can't be reached with these actions/elements)
    Also: don't repeat an action that clearly had no effect last turn.
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

        let raw: String
        do {
            raw = try await router.complete(prompt: prompt, system: Self.stepSystem)
        } catch {
            return .cannot(Self.friendlyError(error))
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

    private static let grammar = """
    Allowed actions ONLY (one per line, exactly this format):
      click element N         (N is a number from the ELEMENTS list)
      double click element N
      click "label"
      type "text"
      hotkey cmd t            (a key combination — list the real keys; use cmd/shift/option/control + one key)
      press key return        (a SINGLE key — use the real key name: return, escape, tab, space, up, down…)
      wait 1
    Format rules — follow EXACTLY:
    - PREFER keyboard shortcuts (hotkey / type / press key) over clicking when they do the same job —
      they're far more reliable and don't depend on the elements list. E.g. to go to a URL use
      `hotkey cmd l` then `type "..."` then `press key return`, instead of clicking the address bar.
    - For key COMBINATIONS use `hotkey` with real key names, e.g. `hotkey cmd t`, `hotkey cmd l`.
      NEVER write the literal word KEY, and NEVER put quotes around key names.
    - For a single key use `press key <name>`, e.g. `press key return`. Never `press key "x" KEY "y"`.
    - Only use `click element N` when the ELEMENTS list is non-empty and contains N. If the list is
      empty or the target isn't listed, use a keyboard action instead.
    - Keep it minimal; at most 20 actions.
    - NEVER type passwords, payment details, or secrets. NEVER do destructive or irreversible actions (delete, erase, buy, send money, transfer).

    EXAMPLES (task → script):
    - open a new tab → hotkey cmd t
    - focus the address bar and go to github.com → hotkey cmd l ; type "github.com" ; press key return
    - save the document → hotkey cmd s
    - click the Submit button (it is element 4) → click element 4
    """

    private static let system = """
    You operate a Mac for the user by emitting an ACTION SCRIPT: one action per line, no prose, no markdown.
    \(grammar)
    If the task cannot be accomplished with these actions and the listed elements, output exactly one line: CANNOT: <short reason>
    Output ONLY the action script, or the CANNOT line. No explanation.
    """

    func plan(task: String, objectMap: String, router: LLMRouter) async -> Outcome {
        let prompt = """
        ELEMENTS (clickable, in the front window):
        \(objectMap.isEmpty ? "(none detected)" : objectMap)

        TASK: \(task)

        ACTION SCRIPT:
        """

        let raw: String
        do {
            raw = try await router.complete(prompt: prompt, system: Self.system)
        } catch {
            return .cannot(Self.friendlyError(error))
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
