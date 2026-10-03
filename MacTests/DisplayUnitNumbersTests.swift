import XCTest

final class DisplayUnitNumbersTests: XCTestCase {
    func testDistinctUnitNumbersDoNotConflict() {
        XCTAssertFalse(DisplayUnitNumbers.hasDuplicates([3, 4]))
    }

    func testRepeatedUnitNumberIsAConflict() {
        XCTAssertTrue(DisplayUnitNumbers.hasDuplicates([4, 4]))
    }
}
