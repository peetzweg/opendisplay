import XCTest

final class AdbParsingTests: XCTestCase {
    func testTrackDevicesSnapshot() {
        let payload = """
        67071JEA306549         device usb:17825792X product:stallion model:Pixel_10a device:stallion transport_id:7
        b0cadb1f               unauthorized usb:1-1 transport_id:8
        192.168.1.20:5555      device product:x model:Mi_Pad device:y transport_id:9

        """
        XCTAssertEqual(AdbParsing.devices(payload), [
            .init(serial: "67071JEA306549", state: "device", model: "Pixel 10a", usb: true),
            .init(serial: "b0cadb1f", state: "unauthorized", model: nil, usb: true),
            .init(serial: "192.168.1.20:5555", state: "device", model: "Mi Pad", usb: false),
        ])
    }

    func testEmptySnapshotMeansNoDevices() {
        XCTAssertEqual(AdbParsing.devices(""), [])
    }

    func testForwardedPortMatchesSerialAndRemote() {
        let listing = """
        other tcp:9000 tcp:9000
        67071JEA306549 tcp:8080 tcp:8080
        67071JEA306549 tcp:50385 tcp:9000

        """
        XCTAssertEqual(AdbParsing.forwardedPort(in: listing, serial: "67071JEA306549", remotePort: 9000), 50385)
        XCTAssertNil(AdbParsing.forwardedPort(in: listing, serial: "67071JEA306549", remotePort: 9001))
        XCTAssertNil(AdbParsing.forwardedPort(in: "", serial: "67071JEA306549", remotePort: 9000))
    }

    func testDeviceNameSkipsUnsetSetting() {
        XCTAssertEqual(AdbParsing.deviceName(fromShellOutput: "Pixel 10a\n"), "Pixel 10a")
        XCTAssertEqual(AdbParsing.deviceName(fromShellOutput: "null\nNexus 7\n"), "Nexus 7")
        XCTAssertNil(AdbParsing.deviceName(fromShellOutput: "\n"))
    }

    func testUDIDRoundTrip() {
        let udid = AdbParsing.udid(serial: "67071JEA306549")
        XCTAssertEqual(AdbParsing.serial(fromUDID: udid), "67071JEA306549")
        XCTAssertNil(AdbParsing.serial(fromUDID: "00008130-001A196A3AA0001C"))
    }
}
