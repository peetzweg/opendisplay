import XCTest

final class FullscreenPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "FullscreenPreferenceTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsToFullscreen() {
        XCTAssertTrue(FullscreenPreference(defaults: defaults).wantsFullscreen)
    }

    func testWindowedChoiceSurvivesRelaunch() {
        FullscreenPreference(defaults: defaults).wantsFullscreen = false

        XCTAssertFalse(FullscreenPreference(defaults: defaults).wantsFullscreen)
    }

    func testFullscreenChoiceSurvivesRelaunch() {
        FullscreenPreference(defaults: defaults).wantsFullscreen = false
        FullscreenPreference(defaults: defaults).wantsFullscreen = true

        XCTAssertTrue(FullscreenPreference(defaults: defaults).wantsFullscreen)
    }
}
