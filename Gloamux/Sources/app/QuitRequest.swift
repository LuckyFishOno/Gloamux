import AppKit
import Darwin

/// Which Quit requests Gloamux turns down.
///
/// Siri and Shortcuts run the app's intents through the system's `linkd`, which opens the app first if it thinks the app
/// is not running and, after the intent and a 30-second idle period, sends a Quit Apple event to an app it opened.
/// Gloamux is ad hoc signed, so it cannot register its running process with `linkd` (there is no Team ID); `linkd` then
/// treats the window the person is using as one it opened, and quits it. A Quit from `linkd` while a workspace window
/// is open is refused. Command-Q, the Dock, logging out, and restarting quit as before.
public enum QuitRequest {
    /// Whether a Quit Apple event sent by `senderName` is refused while `workspaceIsOpen`.
    public static func refuses(eventClass: AEEventClass, eventID: AEEventID, senderName: String?, workspaceIsOpen: Bool) -> Bool {
        guard workspaceIsOpen, eventClass == AEEventClass(kCoreEventClass), eventID == AEEventID(kAEQuitApplication),
              let senderName else { return false }
        return senderName == "linkd"
    }

    /// Whether the Apple event being handled now is a Quit that `refuses` turns down. A Quit not sent as an Apple event,
    /// such as Command-Q, is never refused.
    @MainActor public static func refusesCurrentEvent(workspaceIsOpen: Bool) -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
        return refuses(eventClass: event.eventClass, eventID: event.eventID,
                       senderName: pid > 0 ? processName(pid) : nil, workspaceIsOpen: workspaceIsOpen)
    }

    /// The executable name of process `pid`, or nil when it cannot be read.
    static func processName(_ pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path)).lastPathComponent
    }
}
