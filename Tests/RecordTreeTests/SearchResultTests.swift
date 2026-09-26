import XCTest
@testable import RecordTree

final class SearchResultTests: XCTestCase {

    func testIsImage_true_whenAttachmentNonEmpty() {
        let r = SearchResult(
            chunkID: "chunk_1", treeID: "tree_1", treeTitle: "测试",
            content: "图片描述", sourceApp: "Safari",
            attachment: "images/2026-09-15/abc.png",
            treeKind: "clipboard",
            chunkUpdatedAtMs: 1000, treeUpdatedAtMs: 2000
        )
        XCTAssertTrue(r.isImage)
    }

    func testIsImage_false_whenAttachmentEmpty() {
        let r = SearchResult(
            chunkID: "chunk_1", treeID: "tree_1", treeTitle: "测试",
            content: "纯文本", sourceApp: "Safari",
            attachment: "",
            treeKind: "clipboard",
            chunkUpdatedAtMs: 1000, treeUpdatedAtMs: 2000
        )
        XCTAssertFalse(r.isImage)
    }

    func testSearchResult_allFieldsPreserved() {
        let r = SearchResult(
            chunkID: "c123", treeID: "t456", treeTitle: "标题",
            content: "内容", sourceApp: "Xcode",
            attachment: "images/2026-09-15/x.png",
            treeKind: "note",
            chunkUpdatedAtMs: 111, treeUpdatedAtMs: 222
        )
        XCTAssertEqual(r.chunkID, "c123")
        XCTAssertEqual(r.treeID, "t456")
        XCTAssertEqual(r.treeTitle, "标题")
        XCTAssertEqual(r.content, "内容")
        XCTAssertEqual(r.sourceApp, "Xcode")
        XCTAssertEqual(r.attachment, "images/2026-09-15/x.png")
        XCTAssertEqual(r.treeKind, "note")
        XCTAssertEqual(r.chunkUpdatedAtMs, 111)
        XCTAssertEqual(r.treeUpdatedAtMs, 222)
        XCTAssertTrue(r.isImage)
    }

    func testSearchResult_treeKind_note() {
        let r = makeResult(kind: "note", attachment: "")
        XCTAssertEqual(r.treeKind, "note")
        XCTAssertFalse(r.isImage)
    }

    func testSearchResult_treeKind_clipboard() {
        let r = makeResult(kind: "clipboard", attachment: "")
        XCTAssertEqual(r.treeKind, "clipboard")
        XCTAssertFalse(r.isImage)
    }

    func testSearchResult_clipboardWithImage() {
        let r = makeResult(kind: "clipboard", attachment: "images/2026-09-15/img.png")
        XCTAssertEqual(r.treeKind, "clipboard")
        XCTAssertTrue(r.isImage)
    }

    func testSearchResult_noteWithoutImage() {
        let r = makeResult(kind: "note", attachment: "")
        XCTAssertEqual(r.treeKind, "note")
        XCTAssertFalse(r.isImage)
    }

    // MARK: - Helper

    private func makeResult(kind: String, attachment: String) -> SearchResult {
        SearchResult(
            chunkID: "c1", treeID: "t1", treeTitle: "T",
            content: "C", sourceApp: "App",
            attachment: attachment, treeKind: kind,
            chunkUpdatedAtMs: 1, treeUpdatedAtMs: 2
        )
    }
}
