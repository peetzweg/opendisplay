import XCTest

final class PhoneInfoTests: XCTestCase {
    private func hello(_ json: String) throws -> PhoneInfo {
        try JSONDecoder().decode(PhoneInfo.self, from: Data(json.utf8))
    }

    private let legacy = #""pixelsWide":5120,"pixelsHigh":2880,"scale":2"#

    func testAbsentPanelGivesLegacyFacts() throws {
        let info = try hello("{\(legacy)}")
        XCTAssertNil(info.panel)
        XCTAssertFalse(info.hasInvalidPanel)
        XCTAssertEqual(info.facts, PanelFacts(pixelsWide: 5120, pixelsHigh: 2880, scale: 2,
                                              pointsWide: nil, pointsHigh: nil))
    }

    func testLegacyScaleIsNeverRead() throws {
        // iPhones send 3, Android a fraction; the legacy reading is always 2x.
        let info = try hello(#"{"pixelsWide":2556,"pixelsHigh":1179,"scale":3}"#)
        XCTAssertEqual(info.facts.scale, 2)
    }

    func testFullPanelIsUsed() throws {
        let info = try hello("{\(legacy),\"panel\":{\"pixelsWide\":5120,\"pixelsHigh\":2880,"
            + "\"scale\":2,\"pointsWide\":2560,\"pointsHigh\":1440}}")
        XCTAssertEqual(info.facts, PanelFacts(pixelsWide: 5120, pixelsHigh: 2880, scale: 2,
                                              pointsWide: 2560, pointsHigh: 1440))
    }

    func testPanelWithoutPointsIsUsed() throws {
        let info = try hello(#"{"pixelsWide":2556,"pixelsHigh":1179,"scale":3,"panel":{"pixelsWide":2556,"pixelsHigh":1179,"scale":3}}"#)
        XCTAssertEqual(info.facts, PanelFacts(pixelsWide: 2556, pixelsHigh: 1179, scale: 3,
                                              pointsWide: nil, pointsHigh: nil))
    }

    func testPanelWinsOverALyingLegacyTrio() throws {
        // A 2013 iMac: the legacy trio announces points x 2 for older senders (#344).
        let info = try hello("{\(legacy),\"panel\":{\"pixelsWide\":2560,\"pixelsHigh\":1440,"
            + "\"scale\":1,\"pointsWide\":2560,\"pointsHigh\":1440}}")
        XCTAssertEqual(info.facts.pixels, PixelSize(width: 2560, height: 1440))
        XCTAssertEqual(info.facts.scale, 1)
    }

    func testInvalidPanelsFallBackToLegacyWithoutFailingTheHello() throws {
        let invalid = [
            #"{"pixelsWide":1,"pixelsHigh":1440,"scale":1}"#,
            #"{"pixelsWide":2560,"pixelsHigh":1440,"scale":0}"#,
            #"{"pixelsWide":2560,"pixelsHigh":1440,"scale":"2"}"#,
            #"{"pixelsWide":2560,"pixelsHigh":1440,"scale":1,"pointsWide":2560}"#,
            #"{"pixelsWide":2560.5,"pixelsHigh":1440,"scale":1}"#,
            #"{"pixelsHigh":1440,"scale":1}"#,
            #"5"#,
        ]
        for panel in invalid {
            let info = try hello("{\(legacy),\"panel\":\(panel)}")
            XCTAssertTrue(info.hasInvalidPanel, panel)
            XCTAssertEqual(info.facts, info.legacyFacts, panel)
        }
    }

    func testPanelMillimetersAreRead() throws {
        let info = try hello("{\(legacy),\"panel\":{\"pixelsWide\":5120,\"pixelsHigh\":2880,"
            + "\"scale\":2,\"millimetersWide\":596.7,\"millimetersHigh\":335.6}}")
        XCTAssertEqual(info.reportedMillimeters, CGSize(width: 596.7, height: 335.6))
        XCTAssertFalse(info.hasInvalidPanel)
    }

    func testMalformedMillimetersDropOnlyThemselves() throws {
        let malformed = [
            #""millimetersWide":596.7"#,
            #""millimetersWide":0,"millimetersHigh":335.6"#,
            #""millimetersWide":-1,"millimetersHigh":335.6"#,
            #""millimetersWide":"596","millimetersHigh":335.6"#,
        ]
        for mm in malformed {
            let info = try hello("{\(legacy),\"panel\":{\"pixelsWide\":5120,\"pixelsHigh\":2880,"
                + "\"scale\":2,\(mm)}}")
            XCTAssertNil(info.reportedMillimeters, mm)
            XCTAssertFalse(info.hasInvalidPanel, mm)
            XCTAssertEqual(info.facts.pixels, PixelSize(width: 5120, height: 2880), mm)
        }
    }

    func testMillimetersOfAnInvalidPanelAreIgnored() throws {
        let info = try hello("{\(legacy),\"panel\":{\"pixelsWide\":1,\"pixelsHigh\":2880,"
            + "\"scale\":2,\"millimetersWide\":596.7,\"millimetersHigh\":335.6}}")
        XCTAssertNil(info.reportedMillimeters)
    }
}
