import XCTest
@testable import Alfred

/// Covers the pure, deterministic parts of the opencode coding-agent adapter
/// (HermesSession engine parameterization + AppDelegate routing). Everything
/// here avoids touching the disk key ring or spawning a subprocess: provider
/// mapping, model mapping, the OPENCODE_AUTH_CONTENT / OPENCODE_CONFIG_CONTENT
/// builders, and the query→engine router.
final class CodingAgentAdapterTests: XCTestCase {

    // MARK: - Engine routing (AppDelegate.engine(for:))

    func testCodeMarkersRouteToOpencode() {
        XCTAssertEqual(AppDelegate.engine(for: "refactor the query parser in pi"), .opencode)
        XCTAssertEqual(AppDelegate.engine(for: "fix the failing unit test in opencode"), .opencode)
        XCTAssertEqual(AppDelegate.engine(for: "the build error is a stack trace"), .opencode)
        XCTAssertEqual(AppDelegate.engine(for: "git push --force broke the merge conflict"), .opencode)
        XCTAssertEqual(AppDelegate.engine(for: "update package.json dependencies"), .opencode)
    }

    func testGeneralChatStaysWithHermes() {
        XCTAssertEqual(AppDelegate.engine(for: "summarize the market this week"), .hermes)
        XCTAssertEqual(AppDelegate.engine(for: "what's my schedule today"), .hermes)
        XCTAssertEqual(AppDelegate.engine(for: "draft a reply to Sarah"), .hermes)
    }

    func testExplicitEscapeHatches() {
        XCTAssertEqual(AppDelegate.engine(for: "code: add a retry loop to the downloader"), .opencode)
        XCTAssertEqual(AppDelegate.engine(for: "/code inspect the repo layout"), .opencode)
        // "class" alone must not route; only the explicit hermes: prefix forces it.
        XCTAssertEqual(AppDelegate.engine(for: "hermes: refactor the class design"), .hermes)
        XCTAssertEqual(AppDelegate.engine(for: "what happened in class today"), .hermes)
    }

    // MARK: - Prime-agent routing

    func testPrimePrefixRoutesToPrimeAgent() {
        XCTAssertEqual(AppDelegate.engine(for: "prime: run your self-improvement loop on the pi router"), .primeAgent)
        XCTAssertEqual(AppDelegate.engine(for: "/prime review your own output for the week"), .primeAgent)
    }

    func testPrimeMarkersRouteToPrimeAgent() {
        // The narrow markers that invoke the self-improving RLM loop.
        XCTAssertEqual(AppDelegate.engine(for: "run a self-improving pass on the tokenizer"), .primeAgent)
        XCTAssertEqual(AppDelegate.engine(for: "help me self improve my prompt library"), .primeAgent)
        XCTAssertEqual(AppDelegate.engine(for: "act as an rlm agent and refine your skills"), .primeAgent)
        XCTAssertEqual(AppDelegate.engine(for: "refine your skills on this codebase"), .primeAgent)
        // The natural phrasings "self-improve" and "self-improvement" must
        // route too — the marker is a prefix, not a single exact phrase.
        XCTAssertEqual(AppDelegate.engine(for: "help me self-improve my workflows"), .primeAgent)
        XCTAssertEqual(AppDelegate.engine(for: "run a self-improvement loop on the router"), .primeAgent)
    }

    func testCodeMarkersStillGoToOpencodeNotPrime() {
        // Coding work stays with opencode even when a sentence happens to
        // contain the word "prime" or "refine"; only the explicit escape
        // hatches and markers route to the self-improving agent.
        XCTAssertEqual(AppDelegate.engine(for: "refine the query parser and fix the stack trace"), .opencode)
        XCTAssertEqual(AppDelegate.engine(for: "prime the cache before the test suite"), .opencode)
        XCTAssertEqual(AppDelegate.engine(for: "add a prime number sieve unit test"), .opencode)
    }

    // MARK: - Prime provider mapping (HermesSession.primeAgentProviderID)

    func testPrimeProviderMapping() {
        XCTAssertEqual(HermesSession.primeAgentProviderID(for: .gemini), "google")
        XCTAssertEqual(HermesSession.primeAgentProviderID(for: .zai), "zai")
        XCTAssertEqual(HermesSession.primeAgentProviderID(for: .kimi), "moonshotai")
        XCTAssertEqual(HermesSession.primeAgentProviderID(for: .minimax), "minimax")
        XCTAssertEqual(HermesSession.primeAgentProviderID(for: .deepseek), "deepseek")
        XCTAssertEqual(HermesSession.primeAgentProviderID(for: .groq), "groq")
        XCTAssertEqual(HermesSession.primeAgentProviderID(for: .openrouter), "openrouter")
        XCTAssertEqual(HermesSession.primeAgentProviderID(for: .nvidia), "nvidia")
        // No native registry entry in prime-agent → deliberately skipped.
        XCTAssertNil(HermesSession.primeAgentProviderID(for: .stepfun))
        XCTAssertNil(HermesSession.primeAgentProviderID(for: .alibaba))
        XCTAssertNil(HermesSession.primeAgentProviderID(for: .puter))
        XCTAssertNil(HermesSession.primeAgentProviderID(for: .freellmpool))
    }

    // MARK: - Prime model mapping (HermesSession.primeAgentModel)

    func testPrimeModelMapping() {
        XCTAssertEqual(HermesSession.primeAgentModel(for: .gemini), "google/gemini-3-flash")
        XCTAssertEqual(HermesSession.primeAgentModel(for: .zai), "zai/glm-4.5-air")
        XCTAssertEqual(HermesSession.primeAgentModel(for: .kimi), "moonshotai/kimi-k2.5")
        XCTAssertEqual(HermesSession.primeAgentModel(for: .deepseek), "deepseek/deepseek-chat")
        XCTAssertEqual(HermesSession.primeAgentModel(for: .groq), "groq/llama-3.1-8b-instant")
        XCTAssertEqual(HermesSession.primeAgentModel(for: .openrouter), "openrouter/free")
        // Providers prime-agent can't serve natively → nil.
        XCTAssertNil(HermesSession.primeAgentModel(for: .stepfun))
        XCTAssertNil(HermesSession.primeAgentModel(for: .alibaba))
        XCTAssertNil(HermesSession.primeAgentModel(for: .puter))
        XCTAssertNil(HermesSession.primeAgentModel(for: .freellmpool))
    }

    // MARK: - Provider mapping (HermesSession.opencodeProviderID)

    func testProviderMapping() {
        XCTAssertEqual(HermesSession.opencodeProviderID(for: .gemini), "google")
        XCTAssertEqual(HermesSession.opencodeProviderID(for: .zai), "zai")
        XCTAssertEqual(HermesSession.opencodeProviderID(for: .kimi), "moonshotai")
        XCTAssertEqual(HermesSession.opencodeProviderID(for: .minimax), "minimax")
        XCTAssertEqual(HermesSession.opencodeProviderID(for: .groq), "groq")
        XCTAssertEqual(HermesSession.opencodeProviderID(for: .openrouter), "openrouter")
        XCTAssertEqual(HermesSession.opencodeProviderID(for: .nvidia), "nvidia")
        // No native registry entry in the fork → deliberately skipped.
        XCTAssertNil(HermesSession.opencodeProviderID(for: .deepseek))
        XCTAssertNil(HermesSession.opencodeProviderID(for: .stepfun))
        XCTAssertNil(HermesSession.opencodeProviderID(for: .alibaba))
        XCTAssertNil(HermesSession.opencodeProviderID(for: .puter))
        XCTAssertNil(HermesSession.opencodeProviderID(for: .freellmpool))
    }

    // MARK: - Model mapping (HermesSession.opencodeModel)

    func testModelMapping() {
        XCTAssertEqual(HermesSession.opencodeModel(for: .gemini), "google/gemini-flash-lite-latest")
        XCTAssertEqual(HermesSession.opencodeModel(for: .zai), "zai/glm-4.5-flash")
        XCTAssertEqual(HermesSession.opencodeModel(for: .kimi), "moonshotai/kimi-k2.5")
        XCTAssertEqual(HermesSession.opencodeModel(for: .deepseek), "opencode/deepseek-v4-flash-free")
        XCTAssertEqual(HermesSession.opencodeModel(for: .groq), "groq/llama-3.1-8b-instant")
        // No native provider to spend the key on → nil.
        XCTAssertNil(HermesSession.opencodeModel(for: .stepfun))
        XCTAssertNil(HermesSession.opencodeModel(for: .alibaba))
        XCTAssertNil(HermesSession.opencodeModel(for: .puter))
    }

    // MARK: - OPENCODE_AUTH_CONTENT builder

    func testAuthContentMapsKeysToOpencodeIDs() throws {
        let content = try XCTUnwrap(
            HermesSession.opencodeAuthContent(entries: [(.gemini, "gk1"), (.groq, "gq1")]))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])

        XCTAssertEqual((json["google"] as? [String: Any])?["type"] as? String, "api")
        XCTAssertEqual((json["google"] as? [String: Any])?["key"] as? String, "gk1")
        XCTAssertEqual((json["groq"] as? [String: Any])?["key"] as? String, "gq1")
        // Unmapped providers are dropped, not emitted under a wrong id.
        XCTAssertNil(json["puter"])
    }

    func testAuthContentDropsKeysWithNoNativeProvider() {
        // DeepSeek/stepfun/alibaba keys can't authenticate anything in the fork,
        // so the content builder returns nil (nothing to inject).
        XCTAssertNil(HermesSession.opencodeAuthContent(
            entries: [(.deepseek, "ds1"), (.stepfun, "sf1"), (.alibaba, "al1")]))
    }

    func testAuthContentEmptyWithoutKeys() {
        XCTAssertNil(HermesSession.opencodeAuthContent(entries: []))
        XCTAssertNil(HermesSession.opencodeAuthContent(entries: [(.puter, "x")]))
    }

    // MARK: - OPENCODE_CONFIG_CONTENT builder

    func testConfigContentTaskPosture() throws {
        let content = HermesSession.opencodeConfigContent(posture: .task, model: "deepseek/deepseek-chat")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek/deepseek-chat")

        let permission = try XCTUnwrap(json["permission"] as? [String: Any])
        XCTAssertEqual(permission["read"] as? String, "allow")
        XCTAssertEqual(permission["edit"] as? String, "allow")
        // Destructive bash patterns are deny-listed in task posture.
        let bash = try XCTUnwrap(permission["bash"] as? [String: String])
        XCTAssertEqual(bash["rm -rf /"], "deny")
        XCTAssertEqual(bash["git push --force*"], "deny")
        XCTAssertEqual(bash["sudo *"], "deny")
        XCTAssertNil(bash["ls"])
    }

    func testConfigContentReadonlyPosture() throws {
        let content = HermesSession.opencodeConfigContent(posture: .readonly, model: "google/gemini-flash-latest")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let permission = try XCTUnwrap(json["permission"] as? [String: Any])
        XCTAssertEqual(permission["bash"] as? String, "deny")
        XCTAssertEqual(permission["edit"] as? String, "deny")
        XCTAssertEqual(permission["task"] as? String, "deny")
        XCTAssertEqual(permission["read"] as? String, "allow")
    }

    // MARK: - Journal path

    func testJournalPathLandsInVaultProjects() {
        let path = HermesSession.opencodeJournalPath()
        XCTAssertTrue(path.hasSuffix("PKM/My Life/Projects/Alfred Coding Agent Log.md"))
        XCTAssertTrue(path.hasPrefix(NSHomeDirectory()))
    }
}
