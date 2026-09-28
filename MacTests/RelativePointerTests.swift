import XCTest
import CoreGraphics

final class RelativePointerTests: XCTestCase {
    func testRelativePointerCrossesScreensAndClampsToDesktop() {
        let screens = [CGRect(x: -1000, y: 0, width: 1000, height: 800), CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        XCTAssertEqual(HardwareInputInjector.desktopPoint(CGPoint(x: -10, y: 20), screens: screens), CGPoint(x: -10, y: 20))
        XCTAssertEqual(HardwareInputInjector.desktopPoint(CGPoint(x: 10, y: 20), screens: screens), CGPoint(x: 10, y: 20))
        XCTAssertEqual(HardwareInputInjector.desktopPoint(CGPoint(x: 9000, y: 200), screens: screens), CGPoint(x: 1919, y: 200))
        var posted: [CGEvent] = []
        let driver = HardwareInputInjector(displayID: 1, repeats: false, cursorPosition: { CGPoint(x: -5, y: 20) }, desktopBounds: { screens }, isTrusted: { true }, sink: { posted.append($0) })
        driver.relativePointer(.init(phase: .moved, dx: 15, dy: 0, button: 1, clicks: 1, mod: 0))
        driver.relativePointer(.init(phase: .began, dx: 0, dy: 0, button: 2, clicks: 1, mod: 0))
        driver.relativePointer(.init(phase: .moved, dx: 20, dy: 0, button: 2, clicks: 1, mod: 0))
        driver.releaseAll()
        XCTAssertEqual(posted.map(\.type), [.mouseMoved, .rightMouseDown, .rightMouseDragged, .rightMouseUp])
        XCTAssertEqual(posted[0].location, CGPoint(x: 10, y: 20))
        XCTAssertEqual(posted[0].getIntegerValueField(.mouseEventClickState), 0)
        XCTAssertEqual(posted[0].getIntegerValueField(.mouseEventDeltaX), 15)
        XCTAssertEqual(posted[0].getIntegerValueField(.mouseEventDeltaY), 0)
        XCTAssertEqual(posted[0].getIntegerValueField(.eventSourceStateID), Int64(CGEventSourceStateID.hidSystemState.rawValue))
        XCTAssertEqual(posted[1].location, CGPoint(x: -5, y: 20))
    }

    func testPointerAndKeyboardUseTheirOwnInjectionLocations() {
        XCTAssertEqual(HardwareInputInjector.eventTap(for: .mouseMoved), .cgSessionEventTap)
        XCTAssertEqual(HardwareInputInjector.eventTap(for: .leftMouseDragged), .cgSessionEventTap)
        XCTAssertEqual(HardwareInputInjector.eventTap(for: .scrollWheel), .cghidEventTap)
        XCTAssertEqual(HardwareInputInjector.eventTap(for: .keyDown), .cghidEventTap)
        XCTAssertEqual(HardwareInputInjector.eventTap(for: .flagsChanged), .cghidEventTap)
    }

    func testMotionAtScreenEdgeKeepsRawDeltaForSystemEdgeActions() {
        var posted: [CGEvent] = []
        let driver = HardwareInputInjector(displayID: 1, repeats: false, cursorPosition: { CGPoint(x: 1919, y: 1079) }, desktopBounds: { [CGRect(x: 0, y: 0, width: 1920, height: 1080)] }, isTrusted: { true }, sink: { posted.append($0) })
        driver.relativePointer(.init(phase: .moved, dx: 0, dy: 12, button: 1, clicks: 1, mod: 0))
        XCTAssertEqual(posted[0].location, CGPoint(x: 1919, y: 1079))
        XCTAssertEqual(posted[0].getIntegerValueField(.mouseEventDeltaY), 12)
        XCTAssertEqual(posted[0].getIntegerValueField(.mouseEventClickState), 0)
    }

    func testInvalidRelativeInputIsRejectedAndStoppedCaptureCannotMove() {
        var count = 0
        let driver = HardwareInputInjector(displayID: 1, repeats: false, isTrusted: { true }, sink: { _ in count += 1 })
        driver.relativePointer(.init(phase: .moved, dx: .infinity, dy: 0, button: 1, clicks: 1, mod: 0))
        driver.relativePointer(.init(phase: .moved, dx: 10001, dy: 0, button: 1, clicks: 1, mod: 0))
        driver.relativePointer(.init(phase: .moved, dx: 0, dy: 0, button: 1, clicks: 1, mod: 0))
        driver.setDisplayID(0)
        driver.relativePointer(.init(phase: .moved, dx: 1, dy: 0, button: 1, clicks: 1, mod: 0))
        XCTAssertEqual(count, 0)
    }
}
