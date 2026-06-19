import XCTest
@testable import Alfred

@MainActor
final class FileWriteCapabilityTests: XCTestCase {
    func testDetectRequest_notRequested() {
        let cap = FileWriteCapability()
        let result = cap.detectRequest(in: "what is the weather?")
        if case .notRequested = result {
            XCTAssertTrue(true)
        } else {
            XCTFail("expected .notRequested")
        }
    }

    func testDetectRequest_textFile() {
        let cap = FileWriteCapability()
        let result = cap.detectRequest(in: "create a swift file with hello world")
        if case .requested(let req) = result {
            XCTAssertEqual(req.fileExtension, "swift")
            XCTAssertEqual(req.format, .text)
        } else {
            XCTFail("expected .requested")
        }
    }

    func testDetectRequest_pdf() {
        let cap = FileWriteCapability()
        let result = cap.detectRequest(in: "create a pdf file about my report")
        if case .requested(let req) = result {
            XCTAssertEqual(req.fileExtension, "pdf")
            XCTAssertEqual(req.format, .pdf)
        } else {
            XCTFail("expected .requested")
        }
    }

    func testDetectRequest_docx() {
        let cap = FileWriteCapability()
        let result = cap.detectRequest(in: "write a word document please")
        if case .requested(let req) = result {
            XCTAssertEqual(req.fileExtension, "docx")
            XCTAssertEqual(req.format, .docx)
        } else {
            XCTFail("expected .requested")
        }
    }

    func testDetectRequest_pptx() {
        let cap = FileWriteCapability()
        let result = cap.detectRequest(in: "make a slide deck about Q3 results")
        if case .requested(let req) = result {
            XCTAssertEqual(req.fileExtension, "pptx")
            XCTAssertEqual(req.format, .pptx)
        } else {
            XCTFail("expected .requested")
        }
    }

    func testDetectRequest_unsupportedExtension() {
        let cap = FileWriteCapability()
        let result = cap.detectRequest(in: "save this as a .png file")
        if case .unsupported(let msg) = result {
            XCTAssertTrue(msg.contains("png"))
        } else {
            XCTFail("expected .unsupported")
        }
    }

    func testSanitizeFilename_replacesSpacesWithHyphens() {
        let cap = FileWriteCapability()
        let result = cap.detectRequest(in: "create a note about my project.txt")
        if case .requested(let req) = result {
            XCTAssertFalse(req.suggestedFilename.contains(" "))
        } else {
            XCTFail("expected .requested")
        }
    }

    func testSanitizeFilename_removesSpecialChars() {
        let cap = FileWriteCapability()
        let result = cap.detectRequest(in: "save file as hello@world#test.txt")
        if case .requested(let req) = result {
            XCTAssertTrue(req.suggestedFilename.hasPrefix("hello"))
            XCTAssertTrue(req.suggestedFilename.hasSuffix(".txt"))
        } else {
            XCTFail("expected .requested")
        }
    }

    func testSanitizeFilename_truncatesLongNames() {
        let cap = FileWriteCapability()
        let longName = String(repeating: "a", count: 200) + ".txt"
        let result = cap.detectRequest(in: "write \(longName)")
        if case .requested(let req) = result {
            XCTAssertTrue(req.suggestedFilename.count <= 84)
        } else {
            XCTFail("expected .requested")
        }
    }

    func testEnsureExtension_appendsWhenMissing() {
        let cap = FileWriteCapability()
        let result = cap.detectRequest(in: "write a markdown file called report")
        if case .requested(let req) = result {
            XCTAssertTrue(req.suggestedFilename.hasSuffix(".md"))
        } else {
            XCTFail("expected .requested")
        }
    }

    func testEnsureExtension_keepsExisting() {
        let cap = FileWriteCapability()
        let result = cap.detectRequest(in: "create a python file called script.py")
        if case .requested(let req) = result {
            XCTAssertTrue(req.suggestedFilename.hasSuffix(".py"))
        } else {
            XCTFail("expected .requested")
        }
    }
}
