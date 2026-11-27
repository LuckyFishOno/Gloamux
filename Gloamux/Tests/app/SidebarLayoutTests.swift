import SwiftUI
import XCTest
@testable import App

@MainActor final class SidebarLayoutTests: XCTestCase {
    func testWidthsStayWithinLimits() {
        XCTAssertEqual(SidebarWidth.left.clamp(50), 200)
        XCTAssertEqual(SidebarWidth.left.clamp(300), 300)
        XCTAssertEqual(SidebarWidth.right.clamp(100), 240)
        XCTAssertEqual(SidebarWidth.right.clamp(1_400), 1_400, "every right panel, the browser too, can be dragged wide")
        XCTAssertEqual(SidebarWidth.left.direction, 1)
        XCTAssertEqual(SidebarWidth.right.direction, -1)
    }

    func testWidePanelsLeaveRoomForTheCenterWhenTheWindowNarrows() {
        let widths = WorkspaceSidebarWidths(left: 520, right: 560)
        XCTAssertEqual(widths.fitting(in: 1_200, reservingRight: 220), widths)
        XCTAssertEqual(widths.fitting(in: 698, reservingRight: 220),
                       WorkspaceSidebarWidths(left: 478, right: 220))
        XCTAssertEqual(SidebarWidth.left.clamp(500, upTo: 400), 400)
        XCTAssertEqual(SidebarWidth.right.clamp(530, upTo: 350), 350)
    }

    /// File transfer and the session log keep room for their two columns: a wide right panel gives way instead of
    /// pushing the columns under the panels on either side.
    func testTheCenterKeepsRoomForItsColumnsInEveryMode() {
        let files = DesktopView.centerMinimum(layout: .native, mode: .files)
        let log = DesktopView.centerMinimum(layout: .native, mode: .log)
        XCTAssertEqual(DesktopView.centerMinimum(layout: .native, mode: .terminal), 340)
        XCTAssertGreaterThanOrEqual(files, FileTransferView.minimumWidth + 10)
        XCTAssertGreaterThanOrEqual(log, ConnectionHistoryView.sideBySideWidth + 10)
        let preferred = WorkspaceSidebarWidths(left: 254, right: 640)
        for minimum in [340.0, files, log] {
            let (widths, _) = WorkspaceSidebarLayout<EmptyView, EmptyView, EmptyView>.fit(
                preferred, in: 1_268, centerMinimum: minimum, leading: true, trailing: true)
            XCTAssertEqual(widths.left, 254)
            // The right panel keeps its width when it fits and otherwise gives way, down to its own minimum.
            XCTAssertEqual(widths.right, min(640, 1_268 - 254 - 2 - minimum))
            XCTAssertGreaterThanOrEqual(1_268 - widths.left - widths.right - 2, minimum, "the center keeps \(minimum) points")
        }
        // At the window's least width, the session tree keeps its minimum and the right panel gives way.
        let (narrow, _) = WorkspaceSidebarLayout<EmptyView, EmptyView, EmptyView>.fit(
            preferred, in: 1_040, centerMinimum: files, leading: true, trailing: true)
        XCTAssertEqual(narrow.left, SidebarWidth.left.range.lowerBound)
        XCTAssertGreaterThanOrEqual(1_040 - narrow.left - narrow.right - 2, files)
    }

    /// The transfer arrows stay exactly in the middle, and the two file panes are always the same width.
    func testTheTransferArrowsStayCentered() {
        for width in [724.0, 801.0, 1_000.0, 1_517.0] {
            let bounds = CGRect(x: 7, y: 0, width: width, height: 400)
            let frames = CenteredColumns.frames(in: bounds, middle: FileTransferView.arrowsWidth)
            XCTAssertEqual(frames[0].width, frames[2].width, accuracy: 0.001)
            XCTAssertEqual(frames[1].midX, bounds.midX, accuracy: 0.001)
            XCTAssertEqual(frames[0].minX, bounds.minX)
            XCTAssertEqual(frames[2].maxX, bounds.maxX, accuracy: 0.001)
        }
        XCTAssertEqual(FileTransferView.minimumWidth, FileTransferView.paneMinWidth * 2 + FileTransferView.arrowsWidth)
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
