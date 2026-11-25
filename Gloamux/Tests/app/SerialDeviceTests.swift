import XCTest
@testable import App

final class SerialDeviceTests: XCTestCase {
    func testOneUSBAdapterIsSuggestedAlongsideSystemAndBluetoothPorts() {
        let devices = [SerialDevice(path: "/dev/cu.debug-console", isUSB: false),
                       SerialDevice(path: "/dev/cu.Bluetooth-Incoming-Port", isUSB: false),
                       SerialDevice(path: "/dev/cu.SLAB_USBtoUART", isUSB: true)]
        XCTAssertEqual(SerialDevice.suggestedPath(in: devices, current: ""), "/dev/cu.SLAB_USBtoUART")
        XCTAssertEqual(SerialDevice.suggestedPath(in: devices, current: "  "), "/dev/cu.SLAB_USBtoUART")
        XCTAssertNil(SerialDevice.suggestedPath(in: devices, current: "/dev/cu.manual"))
    }

    func testAmbiguousAndDisconnectedDevicesAreNotSuggested() {
        let first = SerialDevice(path: "/dev/cu.usbserial-first", isUSB: true)
        let second = SerialDevice(path: "/dev/cu.usbmodem-second", isUSB: true)
        XCTAssertNil(SerialDevice.suggestedPath(in: [first, second], current: ""))
        XCTAssertEqual(SerialDevice.suggestedPath(in: [second], current: ""), second.path)
        XCTAssertNil(SerialDevice.suggestedPath(in: [], current: ""))
        XCTAssertNil(SerialDevice.suggestedPath(in: [.init(path: "/dev/cu.debug-console", isUSB: false)], current: ""))
    }

    func testRegistryDiscoveryKeepsTheSamePortsAsTheCLI() {
        let devices = SerialDevice.connected()
        XCTAssertEqual(devices.map(\.path), SerialPort.devices())
        XCTAssertTrue(devices.allSatisfy { SerialPort.isDevicePath($0.path) })
        XCTAssertEqual(Set(devices.map(\.path)).count, devices.count)
    }
}
