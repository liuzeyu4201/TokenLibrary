import XCTest
@testable import LibraryCore
@testable import LibraryUI

final class CatalogInspectorPresentationTests: XCTestCase {
    func testManualLocalAndRemoteReadingRecordsRemainDistinctAtTheSamePage() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let localID = "16bea008-9dff-4d7d-abee-816704c17391"
        let remoteID = "27cfb119-aeff-4e8e-bcff-927815d28402"
        let positions = ["manual", localID, remoteID].map {
            CatalogReadingPosition(deviceID: $0, pageIndex: 0, totalPages: 3, updatedAt: date)
        }
        let rows = positions.map { CatalogReadingPositionPresentation(position: $0, currentDeviceID: localID.uppercased()) }

        XCTAssertEqual(rows.map(\.title), ["手动记录", "本机自动记录", "其他设备 · 27cfb119"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "Equal page numbers must not merge different reading records.")
        XCTAssertTrue(rows.allSatisfy { $0.summary == "第 1 / 3 页" && $0.updatedAt == date })
        XCTAssertEqual(rows.map(\.id), positions.map(\.deviceID))
    }

    func testUnknownHostDoesNotMislabelRecordAsThisOrAnotherDevice() {
        let position = CatalogReadingPosition(deviceID: "device-with-no-host-context", pageIndex: 7)
        let row = CatalogReadingPositionPresentation(position: position, currentDeviceID: nil)
        XCTAssertEqual(row.title, "设备记录 · device-w")
        XCTAssertEqual(row.summary, "第 8 页")
        let manual = CatalogReadingPosition(deviceID: "manual", pageIndex: 1)
        XCTAssertEqual(CatalogReadingPositionPresentation(position: manual, currentDeviceID: "manual").title, "手动记录")
    }
}
