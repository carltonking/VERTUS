import XCTest
@testable import Alfred

@MainActor
final class FileOperationTests: XCTestCase {

    // MARK: - Detection

    func testDetectsOrganize() {
        XCTAssertEqual(FileOperationCapability.detect(in: "organize my downloads by file type"), .organize)
        XCTAssertEqual(FileOperationCapability.detect(in: "sort the files in this folder"), .organize)
    }

    func testDetectsMove() {
        XCTAssertEqual(FileOperationCapability.detect(in: "move these files to a folder"), .move)
    }

    func testDetectsDelete() {
        XCTAssertEqual(FileOperationCapability.detect(in: "delete this file"), .delete)
        XCTAssertEqual(FileOperationCapability.detect(in: "trash these files"), .delete)
    }

    func testDetectsRenameWithNewName() {
        XCTAssertEqual(FileOperationCapability.detect(in: "rename report.pdf to summary"), .rename("summary"))
    }

    func testDetectsGather() {
        XCTAssertEqual(
            FileOperationCapability.detect(in: "take all photos on my desktop and put them into a folder named screenshots"),
            .gather)
        XCTAssertEqual(
            FileOperationCapability.detect(in: "move all pdfs from downloads into a folder called invoices"),
            .gather)
    }

    func testIgnoresNonFileQueries() {
        XCTAssertNil(FileOperationCapability.detect(in: "what is the weather today"))
        XCTAssertNil(FileOperationCapability.detect(in: "organize my thoughts"))   // no file context
        XCTAssertNil(FileOperationCapability.detect(in: "summarize this article"))
    }

    // MARK: - NL parsing

    func testLocationParsing() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(FileOperationCapability.location(in: "photos on my desktop"), home.appendingPathComponent("Desktop"))
        XCTAssertEqual(FileOperationCapability.location(in: "files in my downloads"), home.appendingPathComponent("Downloads"))
        XCTAssertEqual(FileOperationCapability.location(in: "the documents folder"), home.appendingPathComponent("Documents"))
        XCTAssertEqual(FileOperationCapability.location(in: "in my pictures"), home.appendingPathComponent("Pictures"))
        XCTAssertEqual(FileOperationCapability.location(in: "the music folder"), home.appendingPathComponent("Music"))
        XCTAssertNil(FileOperationCapability.location(in: "somewhere unnamed"))
    }

    func testFilterParsing() {
        XCTAssertEqual(FileOperationCapability.filter(in: "all photos"), .images)
        XCTAssertEqual(FileOperationCapability.filter(in: "the screenshots"), .images)
        XCTAssertEqual(FileOperationCapability.filter(in: "every pdf"), .pdfs)
        XCTAssertEqual(FileOperationCapability.filter(in: "my videos"), .videos)
        XCTAssertEqual(FileOperationCapability.filter(in: "all files"), .all)
    }

    func testDestinationNameParsing() {
        XCTAssertEqual(FileOperationCapability.destinationName(in: "into a folder named screenshots"), "screenshots")
        XCTAssertEqual(FileOperationCapability.destinationName(in: "into a folder called My Stuff folder"), "My Stuff")
        XCTAssertNil(FileOperationCapability.destinationName(in: "no destination here"))
    }

    func testNamedFileParsing() {
        XCTAssertEqual(FileOperationCapability.namedFile(in: "delete report.pdf from desktop"), "report.pdf")
        XCTAssertNil(FileOperationCapability.namedFile(in: "delete the file"))
    }

    // MARK: - Category mapping

    func testCategoryMapping() {
        XCTAssertEqual(FileOperationCapability.category(for: "jpg"), "Images")
        XCTAssertEqual(FileOperationCapability.category(for: "PNG"), "Images")
        XCTAssertEqual(FileOperationCapability.category(for: "pdf"), "Documents")
        XCTAssertEqual(FileOperationCapability.category(for: "mp3"), "Audio")
        XCTAssertEqual(FileOperationCapability.category(for: "mov"), "Video")
        XCTAssertEqual(FileOperationCapability.category(for: "zip"), "Archives")
        XCTAssertEqual(FileOperationCapability.category(for: "swift"), "Code")
        XCTAssertEqual(FileOperationCapability.category(for: "xyz"), "Other")
        XCTAssertEqual(FileOperationCapability.category(for: ""), "Other")
    }

    // MARK: - Rename name safety (path-traversal guard)

    func testRenameNameSafety() {
        XCTAssertTrue(FileOperationCapability.isSafeRenameName("summary.pdf"))
        XCTAssertTrue(FileOperationCapability.isSafeRenameName("My Report 2026"))
        XCTAssertFalse(FileOperationCapability.isSafeRenameName("../../etc/passwd"))
        XCTAssertFalse(FileOperationCapability.isSafeRenameName("folder/name"))
        XCTAssertFalse(FileOperationCapability.isSafeRenameName(".."))
        XCTAssertFalse(FileOperationCapability.isSafeRenameName("."))
        XCTAssertFalse(FileOperationCapability.isSafeRenameName(""))
    }

    // MARK: - Unique destination

    func testUniqueDestinationAppendsNumber() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("alfred-fileop-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let original = dir.appendingPathComponent("report.pdf")
        // No collision → same url.
        XCTAssertEqual(FileOperationCapability.uniqueDestination(original, fm: fm), original)

        // Create it → next call appends " 2".
        try Data("x".utf8).write(to: original)
        let next = FileOperationCapability.uniqueDestination(original, fm: fm)
        XCTAssertEqual(next.lastPathComponent, "report 2.pdf")
    }
}
