import XCTest
@testable import App

@MainActor final class SidebarLayoutTests: XCTestCase {
    func testWidthsStayWithinLimits() {
        XCTAssertEqual(SidebarWidth.left.clamp(50), 200)
        XCTAssertEqual(SidebarWidth.left.clamp(300), 300)
        XCTAssertEqual(SidebarWidth.files.clamp(9_000), 560)
        XCTAssertEqual(SidebarWidth.left.direction, 1)
        XCTAssertEqual(SidebarWidth.files.direction, -1)
    }

    func testWidePanelsLeaveRoomForTheCenterWhenTheWindowNarrows() {
        let widths = WorkspaceSidebarWidths(left: 520, right: 560)
        XCTAssertEqual(widths.fitting(in: 1_200, reservingRight: 220), widths)
        XCTAssertEqual(widths.fitting(in: 698, reservingRight: 220),
                       WorkspaceSidebarWidths(left: 478, right: 220))
        XCTAssertEqual(SidebarWidth.left.clamp(500, upTo: 400), 400)
        XCTAssertEqual(SidebarWidth.files.clamp(530, upTo: 350), 350)
    }

    func testFinishedTransfersStayTenSecondsThenLeave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-strip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tab = try WorkspaceModel(storage: dir).selected ?? SessionTab()
        func item(_ name: String) -> TransferItem {
            TransferItem(direction: .download, name: name, source: "/" + name, destinationFolder: "/tmp", isFolder: false, tab: tab, policy: .replace)
        }
        let now = Date()
        let waiting = item("a"), done = item("b"), old = item("c")
        done.state = .done; done.finished = now.addingTimeInterval(-9)
        old.state = .done; old.finished = now.addingTimeInterval(-11)
        XCTAssertEqual(TransferStatusStrip.visible([old, done, waiting], at: now).map(\.name), ["b", "a"])
    }

    func testStripKeepsNewestFiveAndPushesOldestOut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gloamux-strip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tab = try WorkspaceModel(storage: dir).selected ?? SessionTab()
        let items = (1...7).map {
            TransferItem(direction: .upload, name: "f\($0)", source: "/f\($0)", destinationFolder: "/tmp", isFolder: false, tab: tab, policy: .replace)
        }
        XCTAssertEqual(TransferStatusStrip.shown(items).map(\.name), ["f7", "f6", "f5", "f4", "f3"])
        XCTAssertEqual(TransferStatusStrip.shown(Array(items.prefix(2))).map(\.name), ["f2", "f1"])
    }
}
