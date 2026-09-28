import XCTest
import CoreGraphics

final class HardwareInputTests: XCTestCase {
    private final class Events {
        private let lock = NSLock()
        private var stored: [CGEvent] = []
        var values: [CGEvent] { lock.lock(); defer { lock.unlock() }; return stored }
        func append(_ value: CGEvent) { lock.lock(); defer { lock.unlock() }; stored.append(value) }
    }

    private func injector(display: CGDirectDisplayID = 1,
                          trusted: @escaping () -> Bool = { true }) -> (HardwareInputInjector, Events) {
        let events = Events()
        let driver = HardwareInputInjector(displayID: display, repeats: false,
                                            isTrusted: trusted, sink: { events.append($0) })
        return (driver, events)
    }

    func testPhysicalLettersDigitsAndNavigationMapping() {
        XCTAssertEqual(HardwareKeyMap.keyCode(4), 0)   // A
        XCTAssertEqual(HardwareKeyMap.keyCode(6), 8)   // C
        XCTAssertEqual(HardwareKeyMap.keyCode(25), 9)  // V
        XCTAssertEqual(HardwareKeyMap.keyCode(30), 18) // 1
        XCTAssertEqual(HardwareKeyMap.keyCode(39), 29) // 0
        XCTAssertEqual(HardwareKeyMap.keyCode(40), 36) // Return
        XCTAssertEqual(HardwareKeyMap.keyCode(42), 51) // Backspace
        XCTAssertEqual(HardwareKeyMap.keyCode(43), 48) // Tab
        XCTAssertEqual(HardwareKeyMap.keyCode(79), 124)
        XCTAssertEqual(HardwareKeyMap.keyCode(82), 126)
        XCTAssertEqual(HardwareKeyMap.keyCode(76), 117)
    }

    func testLeftRightModifierAndISOJISMapping() {
        XCTAssertEqual(HardwareKeyMap.keyCode(227), 55)
        XCTAssertEqual(HardwareKeyMap.keyCode(231), 54)
        XCTAssertEqual(HardwareKeyMap.modifier(227), .maskCommand)
        XCTAssertEqual(HardwareKeyMap.modifier(231), .maskCommand)
        XCTAssertEqual(HardwareKeyMap.keyCode(100), 10)
        XCTAssertEqual(HardwareKeyMap.keyCode(135), 94)
        XCTAssertEqual(HardwareKeyMap.keyCode(144), 104)
        XCTAssertNil(HardwareKeyMap.keyCode(-1))
        XCTAssertNil(HardwareKeyMap.keyCode(65535))
        XCTAssertNil(HardwareKeyMap.keyCode(112)) // no macOS virtual F21 key
        XCTAssertFalse(HardwareInput.supportedKey(112))
    }

    func testMalformedJSONAndOutOfRangeInputDoNotReachPlatformAPIs() {
        XCTAssertNil(HardwareInput.decode(HardwareInput.Key.self,
                         from: Data(#"{"code":true,"down":true,"mod":0}"#.utf8)))
        XCTAssertNil(HardwareInput.decode(HardwareInput.Key.self,
                         from: Data(#"{"code":4,"down":true,"mod":-1}"#.utf8)))
        XCTAssertFalse(HardwareInput.Key(code: 65535, down: true, mod: 0).isValid)
        XCTAssertFalse(HardwareInput.Key(code: 4, down: true, mod: .max).isValid)
        XCTAssertFalse(HardwareInput.Pointer(phase: .moved, x: .nan, y: 0,
                                              button: 1, clicks: 1, mod: 0).isValid)
        XCTAssertFalse(HardwareInput.Pointer(phase: .began, x: 1.01, y: 0,
                                              button: 1, clicks: 1, mod: 0).isValid)
        XCTAssertFalse(HardwareInput.Scroll(dx: .infinity, dy: 0, mod: 0).isValid)
        XCTAssertFalse(HardwareInput.Scroll(dx: 10001, dy: 0, mod: 0).isValid)
        let (driver, events) = injector()
        driver.key(.init(code: 65535, down: true, mod: 0))
        driver.pointer(.init(phase: .began, x: .nan, y: 0, button: 1, clicks: 1, mod: 0))
        driver.scroll(.init(dx: 10001, dy: 0, mod: 0))
        XCTAssertTrue(events.values.isEmpty)
    }

    func testOptionalNewInputDoesNotRaiseLegacyProtocolFloor() {
        XCTAssertEqual(WireProtocol.version, 6)
        XCTAssertEqual(WireProtocol.preciseScrollWireVersion, 6)
        XCTAssertEqual(WireProtocol.relativePointerWireVersion, 5)
        XCTAssertEqual(WireProtocol.hardwareInputWireVersion, 4)
        XCTAssertEqual(WireProtocol.pencilWireVersion, 3)
        XCTAssertEqual(WireProtocol.minSupportedPeer, 1)
    }

    func testKeyDownUpAndDuplicateDownHaveOneOwner() {
        let (driver, events) = injector()
        driver.key(.init(code: 4, down: true, mod: 0))
        driver.key(.init(code: 4, down: true, mod: 0))
        driver.key(.init(code: 4, down: false, mod: 0))
        driver.key(.init(code: 4, down: false, mod: 0))
        XCTAssertEqual(events.values.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.values.first?.getIntegerValueField(.keyboardEventKeycode), 0)
        XCTAssertEqual(events.values.first?.getIntegerValueField(.keyboardEventAutorepeat), 0)
    }

    func testCommandShortcutFlagsAndModifierReleases() {
        let (driver, events) = injector()
        let command = UInt(CGEventFlags.maskCommand.rawValue)
        driver.key(.init(code: 227, down: true, mod: command))
        driver.key(.init(code: 6, down: true, mod: command))
        driver.key(.init(code: 6, down: false, mod: command))
        driver.key(.init(code: 227, down: false, mod: 0))
        XCTAssertEqual(events.values.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertTrue(events.values[1].flags.contains(.maskCommand))
        XCTAssertFalse(events.values.last!.flags.contains(.maskCommand))
    }

    func testRightShiftReleaseKeepsLeftShiftPressed() {
        let (driver, events) = injector()
        let shift = UInt(CGEventFlags.maskShift.rawValue)
        driver.key(.init(code: 225, down: true, mod: shift))
        driver.key(.init(code: 229, down: true, mod: shift))
        driver.key(.init(code: 229, down: false, mod: 0))
        XCTAssertTrue(events.values.last!.flags.contains(.maskShift))
        driver.key(.init(code: 225, down: false, mod: shift))
        XCTAssertFalse(events.values.last!.flags.contains(.maskShift))
    }

    func testResetReleasesOnlyOwnedKeysAndButtonsWithoutSynthesizingClicks() {
        let (driver, events) = injector()
        driver.key(.init(code: 227, down: true, mod: 1 << 20))
        driver.key(.init(code: 4, down: true, mod: 1 << 20))
        driver.pointer(.init(phase: .began, x: 0.5, y: 0.5, button: 1, clicks: 1, mod: 1 << 20))
        driver.releaseAll()
        XCTAssertEqual(events.values.suffix(3).map(\.type), [.keyUp, .flagsChanged, .leftMouseUp])
        XCTAssertEqual(events.values.last?.getIntegerValueField(.mouseEventClickState), 0)
        XCTAssertEqual(events.values.last?.flags.rawValue, 0)
        let count = events.values.count
        driver.releaseAll()
        driver.key(.init(code: 4, down: false, mod: 0))
        XCTAssertEqual(events.values.count, count)
    }

    func testPrimaryAndSecondaryPointerDragUseDifferentMouseEvents() {
        for (button, down, drag, up) in [
            (1, CGEventType.leftMouseDown, CGEventType.leftMouseDragged, CGEventType.leftMouseUp),
            (2, CGEventType.rightMouseDown, CGEventType.rightMouseDragged, CGEventType.rightMouseUp)
        ] {
            let (driver, events) = injector()
            driver.pointer(.init(phase: .began, x: 0.2, y: 0.2, button: button, clicks: 2, mod: 0))
            driver.pointer(.init(phase: .moved, x: 0.4, y: 0.4, button: button, clicks: 1, mod: 0))
            driver.pointer(.init(phase: .ended, x: 0.4, y: 0.4, button: button, clicks: 1, mod: 0))
            XCTAssertEqual(events.values.map(\.type), [down, drag, up])
            XCTAssertEqual(events.values.last?.getIntegerValueField(.mouseEventClickState), 2)
        }
    }

    func testPointerCancelIsNotAClickAndSpuriousUpIsIgnored() {
        let (driver, events) = injector()
        driver.pointer(.init(phase: .ended, x: 0, y: 0, button: 1, clicks: 1, mod: 0))
        XCTAssertTrue(events.values.isEmpty)
        driver.pointer(.init(phase: .began, x: 0, y: 0, button: 1, clicks: 1, mod: 0))
        driver.pointer(.init(phase: .cancelled, x: 0, y: 0, button: 1, clicks: 1, mod: 0))
        XCTAssertEqual(events.values.last?.type, .leftMouseUp)
        XCTAssertEqual(events.values.last?.getIntegerValueField(.mouseEventClickState), 0)
    }

    func testTurningOffCaptureReleasesStateAndRejectsFurtherHardwareInput() {
        let (driver, events) = injector()
        driver.key(.init(code: 4, down: true, mod: 0))
        driver.setDisplayID(0)
        XCTAssertEqual(events.values.map(\.type), [.keyDown, .keyUp])
        driver.key(.init(code: 5, down: true, mod: 0))
        driver.pointer(.init(phase: .began, x: 0, y: 0, button: 1, clicks: 1, mod: 0))
        driver.scroll(.init(dx: 0, dy: 20, mod: 0))
        XCTAssertEqual(events.values.count, 2)
    }

    func testRevokedPermissionClearsStateWithoutPostingInput() {
        var trusted = true
        let (driver, events) = injector(trusted: { trusted })
        driver.key(.init(code: 4, down: true, mod: 0))
        trusted = false
        driver.key(.init(code: 5, down: true, mod: 0))
        trusted = true
        driver.key(.init(code: 4, down: false, mod: 0))
        XCTAssertEqual(events.values.count, 1)
        driver.key(.init(code: 4, down: true, mod: 0))
        XCTAssertEqual(events.values.count, 2)
    }

    func testUnsupportedKeyUpDoesNotChangeOwnedModifierState() {
        let (driver, events) = injector()
        driver.key(.init(code: 227, down: true, mod: 1 << 20))
        driver.key(.init(code: 5, down: false, mod: 0))
        driver.releaseAll()
        XCTAssertEqual(events.values.map(\.type), [.flagsChanged, .flagsChanged])
        XCTAssertTrue(events.values.first!.flags.contains(.maskCommand))
        XCTAssertFalse(events.values.last!.flags.contains(.maskCommand))
    }

    func testHeldKeyRepeatsAndStopsImmediatelyAfterRelease() {
        let events = Events()
        let repeated = expectation(description: "held key repeats")
        let driver = HardwareInputInjector(displayID: 1, repeatTiming: { (0.1, 0.02) },
                                            isTrusted: { true }) { event in
            events.append(event)
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 1,
               events.values.filter({ $0.getIntegerValueField(.keyboardEventAutorepeat) == 1 }).count == 1 {
                repeated.fulfill()
            }
        }
        driver.key(.init(code: 82, down: true, mod: 0))
        wait(for: [repeated], timeout: 2)
        driver.key(.init(code: 82, down: false, mod: 0))
        let count = events.values.count
        let quiet = expectation(description: "cancelled repeat stays quiet")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { quiet.fulfill() }
        wait(for: [quiet], timeout: 1)
        XCTAssertEqual(events.values.count, count)
        XCTAssertEqual(events.values.last?.type, .keyUp)
    }

    func testOwnedCommandAppliesToClicksWhenPointerSnapshotOmitsIt() {
        let (driver, events) = injector()
        driver.key(.init(code: 227, down: true, mod: 1 << 20))
        driver.pointer(.init(phase: .began, x: 0.5, y: 0.5, button: 1, clicks: 1, mod: 0))
        XCTAssertEqual(events.values.last?.type, .leftMouseDown)
        XCTAssertTrue(events.values.last!.flags.contains(.maskCommand))
    }

    func testCapsLockUsesFlagsEventsAndKeepsItsToggleOnKeyUp() {
        let (driver, events) = injector()
        driver.key(.init(code: 57, down: true, mod: 1 << 16))
        driver.key(.init(code: 57, down: false, mod: 1 << 16))
        XCTAssertEqual(events.values.map(\.type), [.flagsChanged, .flagsChanged])
        XCTAssertTrue(events.values.last!.flags.contains(.maskAlphaShift))
    }

    func testZeroSystemIntervalRepeatsBackspaceUntilReleased() {
        let events = Events()
        let repeated = expectation(description: "zero interval still repeats backspace")
        let driver = HardwareInputInjector(displayID: 1, repeatTiming: { (0.1, 0) },
                                            isTrusted: { true }) { event in
            events.append(event)
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 1,
               events.values.filter({ $0.getIntegerValueField(.keyboardEventAutorepeat) == 1 }).count == 1 {
                repeated.fulfill()
            }
        }
        driver.key(.init(code: 42, down: true, mod: 0))
        wait(for: [repeated], timeout: 2)
        XCTAssertEqual(events.values.last?.getIntegerValueField(.keyboardEventKeycode), 51)
        driver.key(.init(code: 42, down: false, mod: 0))
        let count = events.values.count
        let quiet = expectation(description: "backspace repeat stops")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { quiet.fulfill() }
        wait(for: [quiet], timeout: 1)
        XCTAssertEqual(events.values.count, count)
    }
}
