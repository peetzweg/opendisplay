import XCTest

final class InputLocalizationTests: XCTestCase {
    private func languageBundle(_ language: String) throws -> Bundle {
        let resources = Bundle(for: Self.self)
        let path = try XCTUnwrap(resources.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }
    func testEnglishAndChineseControlsAreAvailableInCompiledCatalog() throws {
        let english = try languageBundle("en")
        let chinese = try languageBundle("zh-Hans")
        XCTAssertEqual(chinese.localizedString(forKey: "Mac shortcut mode", value: nil, table: "InputStrings"), "Mac 快捷键模式")
        XCTAssertEqual(english.localizedString(forKey: "Pointer speed", value: nil, table: "InputStrings"), "Pointer speed")
        XCTAssertEqual(chinese.localizedString(forKey: "Pointer speed", value: nil, table: "InputStrings"), "指针速度")
        XCTAssertEqual(chinese.localizedString(forKey: "Reverse scroll direction", value: nil, table: "InputStrings"), "反转滚动方向")
    }
}
