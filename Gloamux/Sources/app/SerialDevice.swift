import Foundation
import IOKit
import IOKit.serial

/// A call-out port and its transport. USB ancestry identifies console adapters without relying on driver names.
struct SerialDevice: Equatable {
    let path: String
    let isUSB: Bool

    static func connected() -> [SerialDevice] {
        var usbPaths = Set<String>()
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                if let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                   hasUSBAncestor(service) {
                    usbPaths.insert(path)
                }
                IOObjectRelease(service)
            }
        }
        // Keep ports whose drivers do not publish registry metadata available for manual selection too.
        return SerialPort.devices().map { SerialDevice(path: $0, isUSB: usbPaths.contains($0)) }
    }

    /// Fill a new, blank form only when there is one USB adapter. Built-in and Bluetooth ports stay in the menu.
    static func suggestedPath(in devices: [SerialDevice], current: String) -> String? {
        guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let usb = devices.filter(\.isUSB)
        return usb.count == 1 ? usb[0].path : nil
    }

    private static func hasUSBAncestor(_ service: io_registry_entry_t) -> Bool {
        var entry: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &entry) == KERN_SUCCESS else { return false }
        while entry != 0 {
            let isUSB = IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 || IOObjectConformsTo(entry, "IOUSBDevice") != 0
            var parent: io_registry_entry_t = 0
            let result = isUSB ? KERN_FAILURE : IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            if isUSB { return true }
            guard result == KERN_SUCCESS else { return false }
            entry = parent
        }
        return false
    }
}
