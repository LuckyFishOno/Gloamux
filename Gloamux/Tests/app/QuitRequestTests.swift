import AppKit
import XCTest
@testable import App

final class QuitRequestTests: XCTestCase {
    private let quit = (AEEventClass(kCoreEventClass), AEEventID(kAEQuitApplication))

    func testAQuitFromTheIntentsServiceLeavesAnOpenWorkspaceRunning() {
        XCTAssertTrue(QuitRequest.refuses(eventClass: quit.0, eventID: quit.1, senderName: "linkd", workspaceIsOpen: true))
    }

    func testOtherQuitsStillQuit() {
        for sender in ["Dock", "loginwindow", "osascript", "Shortcuts", "linkd-helper", nil] {
            XCTAssertFalse(QuitRequest.refuses(eventClass: quit.0, eventID: quit.1, senderName: sender, workspaceIsOpen: true),
                           "\(sender ?? "unknown sender")")
        }
    }

    func testTheIntentsServiceCanQuitAnAppWithNoWorkspaceOpen() {
        XCTAssertFalse(QuitRequest.refuses(eventClass: quit.0, eventID: quit.1, senderName: "linkd", workspaceIsOpen: false))
    }

    func testOnlyTheQuitEventIsConsidered() {
        XCTAssertFalse(QuitRequest.refuses(eventClass: quit.0, eventID: AEEventID(kAEReopenApplication),
                                           senderName: "linkd", workspaceIsOpen: true))
    }

    @MainActor func testWithNoAppleEventBeingHandledNothingIsRefused() {
        XCTAssertFalse(QuitRequest.refusesCurrentEvent(workspaceIsOpen: true))
    }

    func testTheSenderNameComesFromItsProcess() {
        XCTAssertEqual(QuitRequest.processName(1), "launchd")
        XCTAssertNil(QuitRequest.processName(-1))
    }
}
