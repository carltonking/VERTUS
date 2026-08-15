import XCTest
@testable import Alfred

/// Covers the deterministic, model-free parts of the essay skill: citation
/// formatting in all three styles, the writing-style analyzer, and the outline
/// generator. Everything here is pure and static, so no Hermes process or
/// network is touched.
final class EssaySkillTests: XCTestCase {

    // MARK: - Citation: in-text

    func testMLAInText() {
        let c = Citation(kind: .book, authors: ["Wright, Frank Lloyd"], title: "The Natural House", year: "1954")
        XCTAssertEqual(CitationManager.inText(c, style: .mla, page: 42), "(Wright 42)")
        XCTAssertEqual(CitationManager.inText(c, style: .mla), "(Wright)")
    }

    func testAPAInText() {
        let c = Citation(kind: .book, authors: ["Wright, Frank Lloyd"], title: "The Natural House", year: "1954")
        XCTAssertEqual(CitationManager.inText(c, style: .apa, page: 42), "(Wright, 1954, p. 42)")
        XCTAssertEqual(CitationManager.inText(c, style: .apa), "(Wright, 1954)")
    }

    func testChicagoInText() {
        let c = Citation(kind: .book, authors: ["Wright, Frank Lloyd"], title: "The Natural House", year: "1954")
        XCTAssertEqual(CitationManager.inText(c, style: .chicago, page: 42), "(Wright 1954, 42)")
        XCTAssertEqual(CitationManager.inText(c, style: .chicago), "(Wright 1954)")
    }

    func testAuthorlessInTextFallsBackToShortTitle() {
        let c = Citation(kind: .website, title: "The Decline of the American Mall")
        XCTAssertTrue(CitationManager.inText(c, style: .mla).contains("The Decline"))
    }

    // MARK: - Citation: reference list

    func testReferenceListIncludesHeaderAndEntry() {
        let c = Citation(kind: .book, authors: ["Wright, Frank Lloyd"], title: "The Natural House", year: "1954")
        let list = CitationManager.referenceList([c], style: .mla)
        XCTAssertTrue(list.hasPrefix("Works Cited"))
        XCTAssertTrue(list.contains("Wright, Frank Lloyd"))
        XCTAssertTrue(list.contains("*The Natural House*"))
    }

    func testAPAWebsiteEntryCarriesURL() {
        let c = Citation(kind: .website, title: "The Decline of the American Mall", url: "https://example.com/malls")
        let entry = CitationManager.entry(c, style: .apa)
        XCTAssertTrue(entry.contains("https://example.com/malls"))
    }

    // MARK: - Citation: checks

    func testCheckFlagsMissingHeaderAndUncitedSource() {
        let c = Citation(kind: .book, authors: ["Wright, Frank Lloyd"], title: "The Natural House", year: "1954")
        let issues = CitationManager.check("Cities grow. Light matters.", citations: [c], style: .mla)
        XCTAssertTrue(issues.contains { $0.contains("Works Cited") })
        XCTAssertTrue(issues.contains { $0.contains("The Natural House") })
    }

    func testCheckPassesConsistentDraft() {
        let c = Citation(kind: .book, authors: ["Wright, Frank Lloyd"], title: "The Natural House", year: "1954")
        let essay = "Wright argued cities should grow organically.\n\nWorks Cited\nWright, Frank Lloyd. *The Natural House* 1954"
        XCTAssertTrue(CitationManager.check(essay, citations: [c], style: .mla).isEmpty)
    }

    func testCheckReferenceListClean() {
        let essay = "Wright argued cities should grow organically.\n\nWorks Cited\nWright, Frank Lloyd. *The Natural House* 1954"
        XCTAssertTrue(CitationManager.checkReferenceList(essay, style: .mla).isEmpty)
    }

    func testCheckReferenceListUncitedEntry() {
        let essay = "Cities grow.\n\nWorks Cited\nWright, Frank Lloyd. *The Natural House* 1954"
        XCTAssertFalse(CitationManager.checkReferenceList(essay, style: .mla).isEmpty)
    }

    func testCheckReferenceListMissingHeader() {
        let issues = CitationManager.checkReferenceList("Just an essay body.", style: .apa)
        XCTAssertTrue(issues.contains { $0.contains("References") })
    }

    // MARK: - Citation: name helpers

    func testLastNameParsesBothForms() {
        XCTAssertEqual(CitationManager.lastName(of: "Wright, Frank Lloyd"), "Wright")
        XCTAssertEqual(CitationManager.lastName(of: "Frank Lloyd Wright"), "Wright")
    }

    func testNormalNameFlipsCommaForm() {
        XCTAssertEqual(CitationManager.normalName("Wright, Frank Lloyd"), "Frank Lloyd Wright")
    }

    // MARK: - Writing style: analysis

    func testAnalyzeCountsASample() {
        let profile = WritingStyleAnalyzer.analyze("Cities grow. They change over time.")
        XCTAssertEqual(profile.sampleCount, 1)
        XCTAssertFalse(profile.isEmpty)
        XCTAssertFalse(profile.argumentStructure.isEmpty)
    }

    func testToneCriticalWinsOverAnalytical() {
        let profile = WritingStyleAnalyzer.analyze(
            "The plan is sound. However, critics argue it fails. Despite this, it works.")
        XCTAssertEqual(profile.tone, "critical")
    }

    func testTonePersonal() {
        let profile = WritingStyleAnalyzer.analyze(
            "I believe that I can explain my view. I think we should reconsider our approach.")
        XCTAssertEqual(profile.tone, "personal")
    }

    func testToneAnalytical() {
        let profile = WritingStyleAnalyzer.analyze(
            "The data reveals a pattern. This suggests a deeper cause. It implies change.")
        XCTAssertEqual(profile.tone, "analytical")
    }

    func testArgumentStructureDetectsThesisAndConclusion() {
        let structure = WritingStyleAnalyzer.argumentStructure(
            in: "This essay will argue that cities matter. Evidence shows growth. Ultimately, cities endure.")
        XCTAssertTrue(structure.contains("Thesis"))
        XCTAssertTrue(structure.contains("Conclusion"))
    }

    func testTransitionsAreDetected() {
        let transitions = WritingStyleAnalyzer.transitions(
            in: "However, this works. Furthermore, it scales. Therefore, we ship.")
        XCTAssertTrue(transitions.contains("However"))
        XCTAssertTrue(transitions.contains("Furthermore"))
    }

    // MARK: - Writing style: blending

    func testBlendAdoptsFirstSampleWholesale() {
        let profile = WritingStyleAnalyzer.analyze("Cities grow. They change over time.")
        XCTAssertEqual(WritingStyleAnalyzer.blend(.empty, profile), profile)
    }

    func testBlendSmoothsAverages() {
        let old = EssayStyleProfile(
            averageParagraphWords: 100,
            sentenceVariety: SentenceVariety(simpleFraction: 0.2, compoundFraction: 0.3, complexFraction: 0.5),
            quoteRatio: 0.5, commonTransitions: ["However"],
            argumentStructure: "A", tone: "academic", citationStyle: "mla", sampleCount: 2)
        let new = EssayStyleProfile(
            averageParagraphWords: 200,
            sentenceVariety: SentenceVariety(simpleFraction: 0.4, compoundFraction: 0.4, complexFraction: 0.2),
            quoteRatio: 0.1, commonTransitions: ["Therefore"],
            argumentStructure: "B", tone: "personal", citationStyle: "apa", sampleCount: 1)
        let blended = WritingStyleAnalyzer.blend(old, new)
        XCTAssertEqual(blended.averageParagraphWords, 130, accuracy: 0.001) // 0.7*100 + 0.3*200
        XCTAssertEqual(blended.sampleCount, 3)
        XCTAssertEqual(blended.argumentStructure, "B")
        XCTAssertEqual(blended.tone, "personal")
    }

    // MARK: - Outline + type detection

    func testEssayTypeDetection() {
        XCTAssertEqual(EssayType.detect(from: "argue for rent control"), .argument)
        XCTAssertEqual(EssayType.detect(from: "the history of the Bauhaus movement"), .history)
        XCTAssertEqual(EssayType.detect(from: "a research paper with sources"), .research)
        XCTAssertEqual(EssayType.detect(from: "analyze this poem"), .analysis)
    }

    func testSectionsPerType() {
        XCTAssertEqual(EssayOutlineGenerator.sections(for: .argument).count, 5)
        XCTAssertTrue(EssayOutlineGenerator.sections(for: .history).contains("Historical context"))
        XCTAssertTrue(EssayOutlineGenerator.sections(for: .research).contains("Review of sources"))
    }

    func testGenerationPromptBindsEverything() {
        let sources = [EssaySource(title: "Example Source", url: "https://example.com")]
        let prompt = EssayOutlineGenerator.generationPrompt(
            topic: "Gentrification", length: "1000 words", type: .analysis,
            tone: .academic, style: .empty, citationStyle: .mla, sources: sources)
        XCTAssertTrue(prompt.contains("Gentrification"))
        XCTAssertTrue(prompt.contains("MLA"))
        XCTAssertTrue(prompt.contains("Example Source"))
        XCTAssertTrue(prompt.contains("Introduction and thesis"))
    }

    func testGenerationPromptInjectsLearnedVoice() {
        let style = EssayStyleProfile(
            averageParagraphWords: 120,
            sentenceVariety: SentenceVariety(simpleFraction: 0.2, compoundFraction: 0.4, complexFraction: 0.4),
            quoteRatio: 0.3, commonTransitions: ["However"],
            argumentStructure: "Thesis → Evidence → Conclusion", tone: "analytical",
            citationStyle: "mla", sampleCount: 3)
        let prompt = EssayOutlineGenerator.generationPrompt(
            topic: "Cities", length: "500 words", type: .argument,
            tone: .matchMyStyle, style: style, citationStyle: .mla, sources: [])
        XCTAssertTrue(prompt.contains("Match the user's essay voice"))
        XCTAssertTrue(prompt.contains("Thesis → Evidence → Conclusion"))
    }
}
