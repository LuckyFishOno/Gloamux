import AppKit
import Combine
import Foundation
import QuartzCore

/// Local frame-timing check for the "!" explanation popovers, run with `--popover-probe OUTPUT.json`.
/// It opens and closes the first info button's popover a few times in this app's own window and records every frame
/// the display link delivers; a frame that arrives late means the main thread was busy while the popover animated.
@MainActor enum PopoverProbe {
    private static var recorder: FrameRecorder?

    /// `touch` stands in for a busy workspace: with `--popover-probe-load`, it runs every 100 ms while the probe measures,
    /// as a real workspace's sessions, transfers, and host checks change the model.
    /// `changes` publishes the workspace's changes, which the probe counts per open and close.
    /// With `--popover-probe-mouse`, the probe clicks the button and then an empty corner of the window with mouse events
    /// sent through the application, the way a person opens and dismisses the popover, instead of `performClick`.
    static func scheduleIfRequested(touch: @escaping @MainActor () -> Void = {},
                                    changes: @escaping @MainActor () -> AnyPublisher<Void, Never>? = { nil }) {
        let args = CommandLine.arguments
        guard recorder == nil, let index = args.firstIndex(of: "--popover-probe"), index + 1 < args.count else { return }
        let destination = URL(fileURLWithPath: args[index + 1])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            // With --show-preferences, the Settings window, where most of these buttons are.
            let preferences = args.contains("--show-preferences")
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && (preferences ? $0.title != "Gloamux" : $0.title == "Gloamux") }),
                  let root = window.contentView?.superview ?? window.contentView,
                  case let buttons = infoButtons(in: root), !buttons.isEmpty else {
                write(["error": "No info button in the window"], to: destination)
                NSApp.terminate(nil)
                return
            }
            // `--popover-probe-screen N` moves the window to another display first, such as an external monitor.
            if let index = args.firstIndex(of: "--popover-probe-screen"), index + 1 < args.count,
               let number = Int(args[index + 1]), NSScreen.screens.indices.contains(number) {
                let frame = NSScreen.screens[number].visibleFrame
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let recorder = FrameRecorder(view: root)
            self.recorder = recorder
            // Let the window settle as key before the first cycle.
            try? await Task.sleep(for: .seconds(1))
            let load = args.contains("--popover-probe-load") ? Task { @MainActor in
                while !Task.isCancelled { touch(); try? await Task.sleep(for: .milliseconds(100)) }
            } : nil
            var changeCount = 0
            let counting = changes()?.sink { changeCount += 1 }
            let mouse = args.contains("--popover-probe-mouse")
            let inactive = args.contains("--popover-probe-inactive")
            var cycles: [[String: Any]] = []
            // Alternates between the window's info buttons, so each one's first open is measured as well as reopening.
            for index in 0..<6 {
                let button = buttons[index % buttons.count]
                // `--popover-probe-inactive`: another of the app's windows is key when the button is clicked, as when
                // someone comes back to Settings from the main window, so the click also makes this window key.
                if inactive, let other = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.canBecomeKey }) {
                    other.makeKey()
                    try? await Task.sleep(for: .milliseconds(300))
                }
                recorder.start()
                changeCount = 0
                let clicked = CACurrentMediaTime()
                if mouse { click(window, at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)) }
                else { button.performClick(nil) }
                let clickMs = (CACurrentMediaTime() - clicked) * 1000
                try? await Task.sleep(for: .milliseconds(600))
                var open = recorder.stop()
                open["mainWindowKey"] = window.isKeyWindow
                open["clickMs"] = (clickMs * 10).rounded() / 10
                open["button"] = index % buttons.count
                open["modelChanges"] = changeCount
                open["popoverShown"] = popoverShown()
                recorder.start()
                changeCount = 0
                if mouse, let content = window.contentView { click(window, at: content.convert(NSPoint(x: content.bounds.maxX - 6, y: content.isFlipped ? content.bounds.maxY - 6 : 6), to: nil)) }
                else { button.performClick(nil) }
                try? await Task.sleep(for: .milliseconds(600))
                var close = recorder.stop()
                close["modelChanges"] = changeCount
                close["popoverShown"] = popoverShown()
                cycles.append(["open": open, "close": close])
            }
            load?.cancel()
            counting?.cancel()
            write(["cycles": cycles, "load": load != nil, "mouse": mouse, "screen": window.screen?.localizedName ?? "",
                   "backingScale": window.backingScaleFactor, "buttons": buttons.count, "refreshInterval": recorder.refreshInterval], to: destination)
            NSApp.terminate(nil)
        }
    }

    private static func popoverShown() -> Bool {
        NSApp.windows.contains { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") }
    }

    /// A left click at a point in the window's coordinates, queued like one from the mouse.
    private static func click(_ window: NSWindow, at point: NSPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        for (type, offset) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.03)] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now + offset,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func infoButtons(in view: NSView) -> [NSButton] {
        if NSStringFromClass(type(of: view)).hasSuffix("InfoButtonView"), let button = view as? NSButton { return [button] }
        return view.subviews.flatMap(infoButtons(in:))
    }

    private static func write(_ report: [String: Any], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

@MainActor private final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var recording = false
    private(set) var refreshInterval: CFTimeInterval = 1.0 / 60

    init(view: NSView) {
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        refreshInterval = link.duration > 0 ? link.duration : refreshInterval
        if recording { stamps.append(CACurrentMediaTime()) }
    }

    func start() { stamps = []; recording = true }

    /// Frame intervals over the window, in milliseconds, with the frames that took longer than one and a half refreshes.
    func stop() -> [String: Any] {
        recording = false
        let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        let budget = refreshInterval * 1000 * 1.5
        let late = gaps.filter { $0 > budget }
        return ["frames": stamps.count, "maxMs": (gaps.max() ?? 0).rounded(toPlaces: 1),
                "lateFrames": late.count, "lateMs": late.map { $0.rounded(toPlaces: 1) },
                "droppedFrames": late.reduce(0) { $0 + Int(($1 / (refreshInterval * 1000)).rounded()) - 1 }]
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
