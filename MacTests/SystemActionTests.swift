import XCTest

final class SystemActionTests: XCTestCase {
    /// The names are wire protocol (PROTOCOL.md 6.1): renaming one breaks receivers.
    func testWireNamesAreStable() {
        XCTAssertEqual(SystemAction.allCases.map(\.rawValue),
                       ["missionControl", "appExpose", "showDesktop", "apps",
                        "spotlight", "spaceLeft", "spaceRight"])
    }

    func testDockActionsDoNotDependOnShortcuts() {
        XCTAssertEqual(SystemAction.missionControl.route(appsLauncher: true), .dock("com.apple.expose.awake"))
        XCTAssertEqual(SystemAction.appExpose.route(appsLauncher: true), .dock("com.apple.expose.front.awake"))
        XCTAssertEqual(SystemAction.showDesktop.route(appsLauncher: true), .dock("com.apple.showdesktop.awake"))
    }

    /// macOS 26 replaced Launchpad with the Apps app.
    func testAppsFollowsTheOSVersion() {
        XCTAssertEqual(SystemAction.apps.route(appsLauncher: true), .app("/System/Applications/Apps.app"))
        XCTAssertEqual(SystemAction.apps.route(appsLauncher: false), .app("/System/Applications/Launchpad.app"))
    }

    func testShortcutActionsUseTheSymbolicHotKeys() {
        XCTAssertEqual(SystemAction.spotlight.route(appsLauncher: true), .hotKey(64))
        XCTAssertEqual(SystemAction.spaceLeft.route(appsLauncher: true), .hotKey(79))
        XCTAssertEqual(SystemAction.spaceRight.route(appsLauncher: true), .hotKey(81))
    }

    func testOnlySpacesNeedThePointerOnTheDevice() {
        XCTAssertEqual(SystemAction.allCases.filter(\.needsPointerOnDisplay), [.spaceLeft, .spaceRight])
    }
}
