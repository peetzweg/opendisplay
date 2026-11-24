import XCTest

/// Interface shapes read from IOKit (`ioreg -c IOUSBHostInterface -l`).
final class AndroidUSBFunctionTests: XCTestCase {
    private func function(_ interfaceClass: Int, _ subclass: Int, _ proto: Int,
                          _ name: String? = nil) -> AndroidUSBFunction? {
        AndroidUSBFunction(interfaceClass: interfaceClass, subclass: subclass, protocol: proto, name: name)
    }

    /// Pixel 10a in each USB mode.
    func testAndroidFunctionsCount() {
        XCTAssertEqual(function(0xFF, 0x42, 0x01, "ADB Interface"), .adb)
        XCTAssertEqual(function(0x06, 0x01, 0x01, "MTP"), .mtp)
        // f_mtp in older kernels.
        XCTAssertEqual(function(0xFF, 0xFF, 0x00, "MTP"), .mtp)
    }

    /// #419: the dock's AX88179A in CDC-NCM mode, its card reader and PD
    /// controller, and the AX88179A in vendor mode.
    func testDockDevicesAreNotAsked() {
        XCTAssertNil(function(0x02, 0x0D, 0x00))
        XCTAssertNil(function(0x0A, 0x00, 0x01))
        XCTAssertNil(function(0x08, 0x06, 0x50))
        XCTAssertNil(function(0x11, 0x00, 0x00))
        XCTAssertNil(function(0xFF, 0xFF, 0x00))
    }

    /// PTP is what a camera looks like; MIDI and the accessory interface
    /// itself are not everyday modes worth a question.
    func testLookalikesAreNotAsked() {
        XCTAssertNil(function(0x06, 0x01, 0x01))
        XCTAssertNil(function(0x06, 0x01, 0x01, "PTP"))
        XCTAssertNil(function(0x01, 0x01, 0x00, "MIDI function"))
        XCTAssertNil(function(0xFF, 0xFF, 0x00, "Android Accessory Interface"))
    }

    func testEveryCandidateCanMatch() {
        for candidate in AndroidUSBFunction.candidates {
            XCTAssertNotNil(function(candidate.interfaceClass, candidate.subclass, candidate.protocol, "MTP"))
        }
    }
}
