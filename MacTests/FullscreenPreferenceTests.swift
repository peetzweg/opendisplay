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

/// These are hostless tests: standard defaults belong to the test process,
/// not the installed receiver app. Restore both keys even if an assertion fails.
final class NotchAreaPreferenceTests: XCTestCase {
    private var savedNotchChoice: Any?
    private var savedFullscreenChoice: Any?

    override func setUp() {
        super.setUp()
        savedNotchChoice = UserDefaults.standard.object(forKey: NotchAreaPreference.key)
        savedFullscreenChoice = UserDefaults.standard.object(forKey: FullscreenPreference.key)
        UserDefaults.standard.removeObject(forKey: NotchAreaPreference.key)
        UserDefaults.standard.removeObject(forKey: FullscreenPreference.key)
    }

    override func tearDown() {
        for (key, value) in [(NotchAreaPreference.key, savedNotchChoice),
                             (FullscreenPreference.key, savedFullscreenChoice)] {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testNotchAreaIsOptInWithoutChangingTheNativeFullscreenDefault() {
        XCTAssertFalse(NotchAreaPreference.enabled)
        XCTAssertTrue(FullscreenPreference().wantsFullscreen)
    }

    func testEnablingAndDisablingNotchAreaPersistsTheChoice() {
        NotchAreaPreference.enabled = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: NotchAreaPreference.key))
        XCTAssertTrue(NotchAreaPreference.enabled)

        NotchAreaPreference.enabled = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: NotchAreaPreference.key) as? Bool, false)
        XCTAssertFalse(NotchAreaPreference.enabled)
    }

    func testNotchAreaDoesNotOverwriteTheNativeFullscreenChoice() {
        FullscreenPreference().wantsFullscreen = false
        NotchAreaPreference.enabled = true
        XCTAssertFalse(FullscreenPreference().wantsFullscreen)

        NotchAreaPreference.enabled = false
        XCTAssertFalse(FullscreenPreference().wantsFullscreen)
    }
}
