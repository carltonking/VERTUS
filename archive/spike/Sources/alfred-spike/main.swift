import Foundation

// Unbuffered stdout so `watch`'s live progress reaches logs/pipes immediately.
setvbuf(stdout, nil, _IONBF, 0)

// Alfred — Phase 0 de-risk CLI.
// Proves the foundation is real on THIS machine before the app is built:
//   doctor  — env + reachability of Ollama and Screenpipe, RAM/disk snapshot
//   model   — hermes3:8b returns a valid structured tool call (the agent-loop primitive)
//   capture — pull recent OCR/transcript memory out of Screenpipe

func now() -> Date { Date() }
func ms(since start: Date) -> String { String(format: "%.0f ms", now().timeIntervalSince(start) * 1000) }

func pass(_ s: String) { print("✅ PASS  \(s)") }
func fail(_ s: String) { print("❌ FAIL  \(s)") }
func info(_ s: String) { print("•  \(s)") }

// MARK: - doctor

func freeDiskGB() -> Double? {
    let url = URL(fileURLWithPath: NSHomeDirectory())
    guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
          let bytes = v.volumeAvailableCapacityForImportantUsage else { return nil }
    return Double(bytes) / 1_073_741_824.0
}

func physicalRAMGB() -> Double {
    Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
}

func runDoctor() async {
    print("=== alfred doctor ===")
    info(String(format: "RAM: %.0f GB physical", physicalRAMGB()))
    if let d = freeDiskGB() { info(String(format: "Disk: %.0f GB free (storage retention is mandatory — see threat-model.md)", d)) }

    let ollama = OllamaClient()
    let os = await ollama.status()
    os.up ? pass("Ollama reachable") : fail("Ollama down")
    os.hasModel ? pass("Model \(ollama.model) present") : fail(os.detail)

    let sp = ScreenpipeClient()
    let ss = await sp.status()
    ss.up ? pass("Screenpipe reachable") : fail(ss.detail)

    print("\nNext: `swift run alfred-spike model`, then `... capture`")
}

// MARK: - model (tool-call capability test)

func runModelTest() async {
    print("=== hermes3 tool-call test ===")
    // A tool Alfred will really need: create a file. We only check that the model
    // emits a well-formed CALL with the right args — nothing is executed here.
    let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "create_file",
            "description": "Create a text file with given contents.",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "absolute file path"],
                    "contents": ["type": "string", "description": "file body"]
                ],
                "required": ["path", "contents"]
            ]
        ]
    ]
    let prompt = "Create a file at /tmp/alfred_hello.txt containing exactly: hello from alfred"

    let client = OllamaClient()
    let start = now()
    do {
        let (calls, _) = try await client.toolCall(userPrompt: prompt, tool: tool)
        info("latency: \(ms(since: start))")
        guard let call = calls.first else {
            fail("model returned no tool call (did not use tools). hermes3:8b should — check the model is pulled.")
            return
        }
        pass("tool call emitted: \(call.name)")
        if call.name == "create_file",
           let path = call.arguments["path"] as? String,
           let contents = call.arguments["contents"] as? String {
            pass("valid schema-conformant args")
            info("path: \(path)")
            info("contents: \(contents)")
        } else {
            fail("args did not match schema: \(call.arguments)")
        }
    } catch {
        fail("\(error)")
    }
}

// MARK: - capture (read real memory)

func runCapture() async {
    print("=== screenpipe capture pull ===")
    let sp = ScreenpipeClient()
    let start = now()
    do {
        let mems = try await sp.search(query: "", contentType: "all", limit: 5)
        info("latency: \(ms(since: start))")
        if mems.isEmpty {
            fail("0 results — Screenpipe running but nothing captured yet, or empty query unsupported. Let it record, retry.")
            return
        }
        pass("\(mems.count) memory rows returned")
        for (i, m) in mems.enumerated() {
            let app = m.app.map { " [\($0)]" } ?? ""
            let snippet = m.text.replacingOccurrences(of: "\n", with: " ").prefix(120)
            info("\(i + 1). \(m.type)\(app): \(snippet)")
        }
    } catch {
        fail("\(error)")
    }
}

// MARK: - native capture (the real Alfred path: ScreenCaptureKit + Vision OCR)

func runScreenOCR() async {
    print("=== native screen OCR (ScreenCaptureKit grab + Vision) ===")
    info("requires Screen Recording permission for the host terminal/IDE")
    let start = now()
    do {
        let (wrote, lines) = try NativeCapture.grabScreenAndOCR()
        info("latency: \(ms(since: start))")
        guard wrote else {
            fail("screen grab failed — grant Screen Recording permission (System Settings ▸ Privacy & Security ▸ Screen Recording) to your terminal/IDE, then retry.")
            return
        }
        if lines.isEmpty {
            fail("frame captured but OCR found no text (blank screen?). Try with text visible.")
            return
        }
        pass("\(lines.count) text lines OCR'd from the live screen; frame discarded")
        for l in lines.prefix(12) {
            info(String(format: "[%.2f] %@", l.confidence, l.text))
        }
        if lines.count > 12 { info("… +\(lines.count - 12) more") }
    } catch {
        fail("\(error)")
    }
}

func runImageOCR(_ path: String?) async {
    print("=== Vision OCR on image file (no permission needed) ===")
    guard let path else { fail("usage: alfred-spike ocr <image-path>"); return }
    guard let img = NativeCapture.loadImage(path: path) else { fail("could not load image at \(path)"); return }
    do {
        let lines = try NativeCapture.ocr(img)
        lines.isEmpty ? fail("no text found") : pass("\(lines.count) lines")
        for l in lines.prefix(20) { info(String(format: "[%.2f] %@", l.confidence, l.text)) }
    } catch { fail("\(error)") }
}

// MARK: - Phase 1: capture loop + memory + retrieval

import AppKit

/// One capture tick: grab screen, OCR, join high-confidence lines, tag frontmost app.
func captureOnce() throws -> (app: String?, text: String)? {
    let (wrote, lines) = try NativeCapture.grabScreenAndOCR()
    guard wrote else { return nil }
    let text = lines.filter { $0.confidence >= 0.3 }
        .map { $0.text }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let app = NSWorkspace.shared.frontmostApplication?.localizedName
    return (app, text)
}

func runWatch(intervalSec: Double) async {
    print("=== alfred watch (capture → OCR → embed → store) ===")
    info("interval: \(intervalSec)s · Ctrl-C to stop")
    guard let store = try? Store() else { fail("could not open store"); return }
    info("db: \(store.path)")
    let ollama = OllamaClient()
    var lastText = (try? store.mostRecentText()) ?? ""
    var saved = 0, skipped = 0

    while true {
        do {
            if let cap = try captureOnce() {
                // dedup: skip frames whose text is identical to the last stored one
                if cap.text == lastText {
                    skipped += 1
                } else {
                    let id = try store.insertMemory(ts: now(), app: cap.app, text: cap.text)
                    if let vec = try? await ollama.embed(cap.text) {
                        try store.insertEmbedding(memoryID: id, vector: vec)
                    }
                    lastText = cap.text
                    saved += 1
                    let preview = cap.text.replacingOccurrences(of: "\n", with: " ").prefix(60)
                    print("  +#\(id) [\(cap.app ?? "?")] \(preview)")
                }
            }
        } catch {
            fail("\(error)")
        }
        if (saved + skipped) % 10 == 0 { info("saved \(saved) · skipped(dup) \(skipped)") }
        try? await Task.sleep(nanoseconds: UInt64(intervalSec * 1_000_000_000))
    }
}

func runAsk(_ question: String?) async {
    guard let question else { fail("usage: alfred-spike ask \"your question\""); return }
    print("=== alfred ask ===")
    guard let store = try? Store() else { fail("could not open store"); return }
    let r = Retrieval(store: store, ollama: OllamaClient())
    let start = now()
    do {
        let (answer, sources) = try await r.ask(question)
        print("\n\(answer)\n")
        info("latency: \(ms(since: start))")
        if !sources.isEmpty {
            info("sources:")
            let fmt = DateFormatter(); fmt.dateFormat = "MMM d HH:mm"
            for s in sources.prefix(5) {
                let when = fmt.string(from: s.memory.ts)
                info(String(format: "  [%.2f] %@ %@", s.score, when, s.memory.app ?? ""))
            }
        }
    } catch { fail("\(error)") }
}

func runStats() {
    guard let store = try? Store() else { fail("could not open store"); return }
    let s = (try? store.stats()) ?? (memories: 0, embeddings: 0)
    print("=== alfred memory ===")
    info("db: \(store.path)")
    info("memories: \(s.memories) · embeddings: \(s.embeddings)")
}

// MARK: - Phase 2: writing-style assistant

func styleEngine() -> Style? {
    guard let store = try? Store() else { fail("could not open store"); return nil }
    return Style(store: store, ollama: OllamaClient())
}

func runStyleHarvest() async {
    print("=== style-harvest (mine authored prose from screen memory) ===")
    guard let s = styleEngine() else { return }
    info("scanning recent memory with hermes3:8b — this can take a bit…")
    do {
        let r = try await s.harvest()
        pass("scanned \(r.scanned) prose-like blocks · kept \(r.kept) authored samples")
        let total = (try? s.store.styleSampleCount()) ?? 0
        info("total style samples: \(total)")
        if r.kept == 0 { info("none found — screen memory is mostly code/UI right now. Use `style-add \"<your text>\"` to seed clean samples.") }
    } catch { fail("\(error)") }
}

func runStyleAdd(_ text: String?) async {
    guard let text, text.count >= 10 else { fail("usage: alfred-spike style-add \"a real sentence or two you wrote\""); return }
    guard let s = styleEngine() else { return }
    do {
        let added = try s.store.addStyleSample(ts: now(), source: "manual", text: text)
        added ? pass("sample added") : info("duplicate — already stored")
        info("total style samples: \(try s.store.styleSampleCount())")
    } catch { fail("\(error)") }
}

func runStyleBuild() async {
    print("=== style-build (distill your style card) ===")
    guard let s = styleEngine() else { return }
    do {
        let card = try await s.buildCard()
        pass("style card built")
        print("\n\(card)\n")
    } catch { fail("\(error)") }
}

func runDraft(_ intent: String?) async {
    guard let intent else { fail("usage: alfred-spike draft \"what to write, e.g. reply to Sam declining the meeting\""); return }
    print("=== draft (in your voice) ===")
    guard let store = try? Store() else { fail("could not open store"); return }
    let ollama = OllamaClient()
    let style = Style(store: store, ollama: ollama)
    // Phase 3: if the intent names someone Alfred knows, ground the draft in that history.
    let pc = try? People(store: store, ollama: ollama).knownPersonMentioned(in: intent)
    if let pc { info("grounding in your history with \(pc.name)") }
    let start = now()
    do {
        let text = try await style.draft(intent: intent, personContext: pc)
        try? store.setLastOutput(kind: "draft", intent: intent, output: text, ts: now())
        print("\n\(text)\n")
        info("latency: \(ms(since: start)) — read-only, nothing was sent")
        info("feedback: `feedback good` · `feedback bad \"why\"` · `feedback edit \"better version\"`")
    } catch { fail("\(error)") }
}

// MARK: - Phase 3: relationship map

func runPeopleScan() async {
    print("=== people-scan (extract your relationships from screen memory) ===")
    guard let store = try? Store() else { fail("could not open store"); return }
    let p = People(store: store, ollama: OllamaClient())
    info("scanning memory with hermes3:8b — can take a bit…")
    do {
        let r = try await p.scan()
        pass("scanned \(r.scanned) blocks · \(r.people) people · \(r.interactions) interactions added")
        if r.people == 0 { info("none found — screen memory has no personal conversations yet. Capture some chats/emails, then rescan.") }
    } catch { fail("\(error)") }
}

func runPeople() {
    guard let store = try? Store() else { fail("could not open store"); return }
    print("=== people (relationship map) ===")
    let fmt = DateFormatter(); fmt.dateFormat = "MMM d HH:mm"
    do {
        let all = try store.people()
        if all.isEmpty { info("no people yet — run people-scan"); return }
        for p in all {
            info("\(p.name) — \(p.count) interactions · last \(fmt.string(from: p.lastSeen))")
        }
    } catch { fail("\(error)") }
}

func runPeopleClean() {
    print("=== people-clean (drop orgs/self, merge duplicates) ===")
    guard let store = try? Store() else { fail("could not open store"); return }
    let p = People(store: store, ollama: OllamaClient())
    do {
        let r = try p.clean()
        pass("removed \(r.removed) non-people · merged \(r.merged) duplicates")
        let remaining = try store.people()
        info("\(remaining.count) people remain:")
        for person in remaining { info("  \(person.name) — \(person.count) interactions") }
    } catch { fail("\(error)") }
}

func runPerson(_ name: String?) async {
    guard let name else { fail("usage: alfred-spike person \"Name\""); return }
    print("=== person: \(name) ===")
    guard let store = try? Store() else { fail("could not open store"); return }
    let p = People(store: store, ollama: OllamaClient())
    do {
        guard let r = try await p.summarize(name: name) else { fail("no one named \(name) in the map — run people-scan or check spelling"); return }
        print("\n\(r.summary)\n")
        info("\(r.interactions.count) interactions on file")
    } catch { fail("\(error)") }
}

func runStyleExport() async {
    guard let s = styleEngine() else { return }
    do {
        let r = try s.exportJSONL()
        pass("exported \(r.count) samples → \(r.path)")
        info("MLX LoRA-ready ({\"text\": …}); fine-tune later once the corpus is large enough")
    } catch { fail("\(error)") }
}

// MARK: - Phase 4: action gateway

func cliGateway() -> ActionGateway {
    ActionGateway(autonomous: Config.load().autonomous, confirm: { prompt in
        print("\n\(prompt) [y/N] ", terminator: "")
        let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return line == "y" || line == "yes"
    })
}

func runConfig(_ a: [String]) {
    var cfg = Config.load()
    if a.count >= 3, a[1] == "autonomous" {
        cfg.autonomous = (a[2] == "on" || a[2] == "true" || a[2] == "1")
        cfg.save()
    }
    print("=== alfred config ===")
    info("autonomous: \(cfg.autonomous)  \(cfg.autonomous ? "(no prompts — acts fully autonomously; audit log is the review-after net)" : "(confirms irreversible/outward actions)")")
    info("change: config autonomous on | off")
}

func runAct(_ a: [String]) {
    // a = ["act", sub, rest...]; CLI input is USER-originated by definition.
    guard a.count >= 2 else {
        print("""
        act <sub>:
          create <path> <text…>   create a file (confirm only if overwriting)
          append <path> <text…>   append to a file
          open <app>              open an application
          run <cmd…>              run a shell command (confirm if destructive/outward)
          delete <path>           delete a file (always confirms)
          screen-test             prove a screen-originated action is BLOCKED
        """)
        return
    }
    let gw = cliGateway()
    let sub = a[1]
    let rest = Array(a.dropFirst(2))
    let outcome: ActionGateway.Outcome

    switch sub {
    case "create":
        guard rest.count >= 2 else { fail("usage: act create <path> <text>"); return }
        outcome = gw.perform(.createFile(path: rest[0], contents: rest[1...].joined(separator: " ")), origin: .user)
    case "append":
        guard rest.count >= 2 else { fail("usage: act append <path> <text>"); return }
        outcome = gw.perform(.appendFile(path: rest[0], contents: rest[1...].joined(separator: " ")), origin: .user)
    case "open":
        guard let app = rest.first else { fail("usage: act open <app>"); return }
        outcome = gw.perform(.openApp(rest.joined(separator: " ")), origin: .user)
        _ = app
    case "run":
        guard !rest.isEmpty else { fail("usage: act run <cmd>"); return }
        outcome = gw.perform(.runShell(rest.joined(separator: " ")), origin: .user)
    case "delete":
        guard let path = rest.first else { fail("usage: act delete <path>"); return }
        outcome = gw.perform(.deleteFile(path: path), origin: .user)
    case "screen-test":
        // Simulate an action proposed from attacker-controlled screen text.
        print("simulating screen-originated action: createFile /tmp/alfred_pwned.txt …")
        outcome = gw.perform(.createFile(path: "/tmp/alfred_pwned.txt", contents: "owned"), origin: .screen)
    default:
        fail("unknown act sub: \(sub)"); return
    }
    print(outcome)
}

// MARK: - Phase 5: agent loop

func runDo(_ request: String?) async {
    guard let request else { fail("usage: alfred-spike do \"what you want done\""); return }
    print("=== alfred do (agent loop) ===")
    guard let store = try? Store() else { fail("could not open store"); return }
    let agent = Agent(store: store, ollama: OllamaClient(), gateway: cliGateway())
    let start = now()
    do {
        let r = try await agent.run(request)
        try? store.setLastOutput(kind: "do", intent: request, output: r.summary, ts: now())
        if !r.actions.isEmpty {
            info("actions:")
            for a in r.actions { info("  \(a)") }
        }
        print("\n\(r.summary)\n")
        info("\(r.steps) step(s) · \(ms(since: start))")
    } catch { fail("\(error)") }
}

// MARK: - Phase 6: self-learning (feedback)

func runFeedback(_ a: [String]) async {
    guard a.count >= 2 else { fail("usage: feedback good | bad \"reason\" | edit \"better version\""); return }
    guard let store = try? Store() else { fail("could not open store"); return }
    let learn = Learning(store: store, ollama: OllamaClient())
    let sub = a[1]
    let rest = a.count > 2 ? a[2...].joined(separator: " ") : ""
    do {
        switch sub {
        case "good":
            print(try learn.accept())
        case "bad":
            guard !rest.isEmpty else { fail("usage: feedback bad \"why it was wrong\""); return }
            let rules = try await learn.reject(reason: rest)
            rules.isEmpty ? info("no rule derived") : { pass("learned:"); rules.forEach { info("  • \($0)") } }()
        case "edit":
            guard !rest.isEmpty else { fail("usage: feedback edit \"your better version\""); return }
            let rules = try await learn.edit(edited: rest)
            pass("saved your edit as a gold sample")
            rules.isEmpty ? info("no rule derived") : { info("learned:"); rules.forEach { info("  • \($0)") } }()
        default:
            fail("unknown feedback: \(sub) (good|bad|edit)")
        }
    } catch { fail("\(error)") }
}

func runPrefs() {
    guard let store = try? Store() else { fail("could not open store"); return }
    print("=== learned preferences ===")
    let prefs = (try? store.preferences()) ?? []
    prefs.isEmpty ? info("none yet — give feedback on a draft to teach Alfred") :
        prefs.forEach { info("  [\($0.weight)] \($0.text)") }
}

// MARK: - Phase 7: UI automation

func runUI(_ a: [String]) {
    guard a.count >= 2 else {
        print("ui <sub>: list | click \"<button title>\" | type \"<text>\"")
        return
    }
    if !UIControl.isTrusted() {
        fail("Accessibility permission not granted. Enable your terminal/IDE in System Settings ▸ Privacy & Security ▸ Accessibility, then retry.")
        return
    }
    let gw = cliGateway()
    let sub = a[1]
    let rest = Array(a.dropFirst(2)).joined(separator: " ")
    switch sub {
    case "list":
        let els = UIControl.listElements()
        print("=== UI elements (frontmost app) ===")
        els.isEmpty ? info("none found") : els.forEach { info("  \($0.role): \($0.title)") }
    case "click":
        guard !rest.isEmpty else { fail("usage: ui click \"<title>\""); return }
        print(gw.perform(.clickUI(title: rest), origin: .user))
    case "type":
        guard !rest.isEmpty else { fail("usage: ui type \"<text>\""); return }
        print(gw.perform(.typeText(rest), origin: .user))
    default:
        fail("unknown ui sub: \(sub)")
    }
}

func runAudit() {
    let gw = cliGateway()
    print("=== audit log (\(gw.auditLogPath)) ===")
    let lines = gw.recentAudit()
    lines.isEmpty ? info("(empty)") : lines.forEach { print("  \($0)") }
}

// MARK: - dispatch

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "doctor"
switch command {
case "doctor":   await runDoctor()
case "model":    await runModelTest()
case "screen":   await runScreenOCR()
case "ocr":      await runImageOCR(args.count > 1 ? args[1] : nil)
case "capture":  await runCapture()   // optional: pull from a running Screenpipe instead
case "watch":    await runWatch(intervalSec: Double(args.count > 1 ? args[1] : "5") ?? 5)
case "ask":      await runAsk(args.count > 1 ? args[1...].joined(separator: " ") : nil)
case "stats":    runStats()
case "style-harvest": await runStyleHarvest()
case "style-add":     await runStyleAdd(args.count > 1 ? args[1...].joined(separator: " ") : nil)
case "style-build":   await runStyleBuild()
case "draft":         await runDraft(args.count > 1 ? args[1...].joined(separator: " ") : nil)
case "style-export":  await runStyleExport()
case "people-scan":   await runPeopleScan()
case "people":        runPeople()
case "people-clean":  runPeopleClean()
case "person":        await runPerson(args.count > 1 ? args[1...].joined(separator: " ") : nil)
case "act":           runAct(args)
case "audit":         runAudit()
case "do":            await runDo(args.count > 1 ? args[1...].joined(separator: " ") : nil)
case "feedback":      await runFeedback(args)
case "prefs":         runPrefs()
case "ui":            runUI(args)
case "config":        runConfig(args)
default:
    print("""
    alfred-spike — Alfred CLI

    Phase 0 (de-risk):
      doctor      check Ollama + RAM/disk
      model       hermes3:8b tool-call + schema test
      screen      native ScreenCaptureKit grab + Vision OCR of the live screen
      ocr <p>     Vision OCR on an image file (no permission needed)

    Phase 1 (memory + retrieval):
      watch [s]   capture loop: screen → OCR → embed → store every s sec (default 5)
      ask "q"     answer a question from your screen memory (RAG via hermes3:8b)
      stats       memory store counts + path

    Phase 2 (writing style):
      style-harvest   mine authored prose from screen memory into style samples
      style-add "t"   add a clean writing sample manually
      style-build     distill your style card from samples
      draft "intent"  write something in your voice (read-only, never sends)
      style-export    dump samples as MLX LoRA-ready JSONL (for later fine-tuning)

    Phase 3 (relationship map):
      people-scan     extract people + interactions from screen memory
      people          list everyone you talk to (counts, last contact)
      people-clean    drop orgs/self/junk + merge duplicate name variants
      person "Name"   summarize your relationship + recent threads with someone

    Phase 4 (action gateway):
      act <sub>       create/append/open/run/delete (confirm only if irreversible/outward)
      act screen-test prove a screen-originated action is BLOCKED (injection defense)
      audit           show the append-only action log

    Phase 5 (agent loop):
      do "request"    natural language → tool calls → gateway, grounded in memory + people

    Phase 6 (self-learning):
      feedback good          reinforce the last output
      feedback bad "why"     learn a preference rule from a complaint
      feedback edit "better"  learn from your edited version
      prefs                  show learned preferences

    Phase 7 (UI automation — needs Accessibility permission):
      ui list                list clickable controls in the frontmost app
      ui click "<title>"     click a button by title (confirms if send/delete/pay/…)
      ui type "<text>"       type into the focused field

    Settings:
      config                 show settings
      config autonomous on   act with NO prompts (audit log is the review-after net)
      config autonomous off  confirm irreversible/outward actions (default)

    Optional:
      capture     pull OCR from a running Screenpipe instance
    """)
}
