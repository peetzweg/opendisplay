import XCTest
import CoreGraphics

final class HardwareKeyboardMappingTests: XCTestCase {
    private let command: UInt = 1 << 20
    private let option: UInt = 1 << 19
    private let shift: UInt = 1 << 17

    func testStandardModeLeavesEverySupportedKeyAndModifierCombinationUnchanged() {
        for code in 0...255 where HardwareInput.supportedKey(code) {
            for flags: UInt in stride(from: 0, through: HardwareInput.modifierMask, by: 1 << 16) {
                for down in [true, false] {
                    let key = HardwareInput.Key(code: code, down: down, mod: flags)
                    XCTAssertEqual(HardwareKeyboardMapping.standard.key(key), key)
                }
            }
        }
    }

    func testSwapIsReversibleAndPreservesLeftRightKeysAndOtherModifiers() {
        for code in 0...255 where HardwareInput.supportedKey(code) {
            for flags: UInt in stride(from: 0, through: HardwareInput.modifierMask, by: 1 << 16) {
                for down in [true, false] {
                    let key = HardwareInput.Key(code: code, down: down, mod: flags)
                    let mapped = HardwareKeyboardMapping.commandOption.key(key)
                    XCTAssertTrue(mapped.isValid)
                    XCTAssertEqual(HardwareKeyboardMapping.commandOption.key(mapped), key)
                }
            }
        }
        XCTAssertEqual(HardwareKeyboardMapping.commandOption.key(.init(code: 230, down: true, mod: option)).code, 231)
        XCTAssertEqual(HardwareKeyboardMapping.commandOption.modifiers(command | option | shift), command | option | shift)
    }

    func testOptionTabKeepsMacCommandHeldAcrossMultipleTabsAndReleasesIt() {
        var events: [CGEvent] = []
        let driver = HardwareInputInjector(displayID: 1, repeats: false,
            isTrusted: { true }, sink: { events.append($0) })
        let sequence: [HardwareInput.Key] = [
            .init(code: 226, down: true, mod: option),
            .init(code: 43, down: true, mod: option),
            .init(code: 43, down: false, mod: option),
            .init(code: 43, down: true, mod: option | shift),
            .init(code: 43, down: false, mod: option | shift),
            .init(code: 226, down: false, mod: 0)
        ]
        sequence.map(HardwareKeyboardMapping.commandOption.key).forEach(driver.key)
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .keyDown, .keyUp, .flagsChanged])
        XCTAssertTrue(events.dropLast().allSatisfy { $0.flags.contains(.maskCommand) })
        XCTAssertTrue(events.allSatisfy { !$0.flags.contains(.maskAlternate) })
        XCTAssertTrue(events[3].flags.contains(.maskShift))
        XCTAssertEqual(events.last?.flags.rawValue, 0)
    }

    func testMappedSpaceEditingAndNavigationPreservePhysicalKeys() {
        for code in [44, 4, 6, 25, 27, 29, 22, 9, 11, 20, 26, 53, 79, 80, 81, 82] {
            let key = HardwareKeyboardMapping.commandOption.key(.init(code: code, down: true, mod: option | shift))
            XCTAssertEqual(key.code, code)
            XCTAssertEqual(key.mod, command | shift)
        }
    }

    func testModeChangeResetReleasesOldMappedKeysBeforeStandardInput() {
        var events: [CGEvent] = []
        let driver = HardwareInputInjector(displayID: 1, repeats: false,
            isTrusted: { true }, sink: { events.append($0) })
        driver.key(HardwareKeyboardMapping.commandOption.key(.init(code: 226, down: true, mod: option)))
        driver.key(HardwareKeyboardMapping.commandOption.key(.init(code: 43, down: true, mod: option)))
        driver.releaseAll()
        XCTAssertEqual(events.suffix(2).map(\.type), [.keyUp, .flagsChanged])
        XCTAssertEqual(events.last?.flags.rawValue, 0)
        driver.key(HardwareKeyboardMapping.standard.key(.init(code: 6, down: true, mod: command)))
        XCTAssertTrue(events.last!.flags.contains(.maskCommand))
        XCTAssertFalse(events.last!.flags.contains(.maskAlternate))
    }
}
