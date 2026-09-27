import XCTest
import GRDB
@testable import LibraryCore

final class SearchCoverageTests:XCTestCase {
    func testCoverageDistinguishesDownloadIndexAndImageOnlyPDF() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=try DocumentStore(directory:directory,pdfPageTextExtractor:{ data in
            data == Data("scan".utf8) ? [""] : ["A searchable PDF page"]
        })
        func add(_ id:String,kind:DocKind,path:String?=nil,state:String="active") throws {
            try store.saveDocument(LibraryDocument(id:id,kind:kind,parentId:"root",name:id,markdown:kind == .md ? "note" : "",pdfPath:path,revision:0,localGeneration:0,state:state,purgeAt:nil,status:.savedLocal,annotationsJSON:"[]"),enqueue:false)
        }
        let scan=directory.appendingPathComponent("scan.pdf"),text=directory.appendingPathComponent("text.pdf")
        try Data("scan".utf8).write(to:scan);try Data("text".utf8).write(to:text)
        try add("note",kind:.md);try add("scan",kind:.pdf,path:scan.path);try add("text",kind:.pdf,path:text.path)
        try add("remote",kind:.pdf);try add("not-indexed",kind:.md);try add("trash",kind:.pdf,state:"trashed")
        try add("folder",kind:.folder)
        try store.db.write { db in try db.execute(sql:"DELETE FROM search_index_state WHERE object_id='not-indexed'") }
        let coverage=try store.searchCoverage()
        XCTAssertEqual(coverage.documents,5);XCTAssertEqual(coverage.searchableText,2)
        XCTAssertEqual(coverage.waitingDownload,1);XCTAssertEqual(coverage.waitingIndex,1);XCTAssertEqual(coverage.pdfWithoutText,1)
        XCTAssertTrue(coverage.summary.contains("2/5"))
        try FileManager.default.removeItem(at:text)
        XCTAssertEqual(try store.searchCoverage().waitingDownload,2)
    }
}
