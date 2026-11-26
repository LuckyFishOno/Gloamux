import XCTest
import SwiftUI
import AppKit
@testable import App

@MainActor final class AppPickerTests: XCTestCase {
    private final class Choice: ObservableObject { @Published var value = "a" }

    /// A click anywhere on the picker, its name included, opens the choices and keeps them open; choosing one sets it.
    func testClickOnTheNameOrTheArrowsOpensTheChoices() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("macOS 14 keeps the SwiftUI menu.") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let choice = Choice()
        struct Root: View {
            @ObservedObject var choice: Choice
            var body: some View {
                Form {
                    AppPicker(title: "Pick", selection: $choice.value, current: choice.value == "a" ? "Default (127.0.0.1)" : "Other") {
                        Text("Default (127.0.0.1)").tag("a")
                        Text("Other").tag("b")
                    } label: { Text("New tabs open") }
                }
                .formStyle(.grouped).frame(width: 400, height: 120)
            }
        }
        let view = NSHostingView(rootView: Root(choice: choice))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        var opened: [(x: CGFloat, open: TimeInterval)] = []
        var clickX: CGFloat = 0, began = Date()
        let begin = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                began = Date()
                guard let menu = note.object as? NSMenu else { return }
                // Still open a moment later, then choose Other on the last click.
                let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        if clickX == 300, let index = menu.items.firstIndex(where: { $0.title == "Other" }) { menu.performActionForItem(at: index) }
                        menu.cancelTracking()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        let end = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { opened.append((clickX, Date().timeIntervalSince(began))) }
        }
        defer { NotificationCenter.default.removeObserver(begin); NotificationCenter.default.removeObserver(end) }

        var number = 0
        func click(_ x: CGFloat) {
            clickX = x; number += 2
            let point = NSPoint(x: x, y: 80), time = ProcessInfo.processInfo.systemUptime
            for (type, offset) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.01)] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time + offset, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: number + (type == .leftMouseUp ? 1 : 0), clickCount: 1, pressure: 1)!, atStart: false)
            }
        }
        func stop() {
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                               subtype: 0, data1: 0, data2: 0)!, atStart: true)
        }
        // The text sits left of the arrows at the trailing edge.
        var spots: [CGFloat] = [260, 350, 300]
        func next() {
            guard let x = spots.first else { stop(); return }
            spots.removeFirst(); click(x)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { next() }
        }
        NSApp.finishLaunching()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() }
        NSApp.run()

        XCTAssertEqual(opened.map(\.x), [260, 350, 300], "Each click opens the choices once.")
        XCTAssertTrue(opened.allSatisfy { $0.open > 0.2 }, "The choices stay open after the click: \(opened)")
        XCTAssertEqual(choice.value, "b", "Choosing an item sets the value.")
    }
}
