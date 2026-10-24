import XCTest

final class LogSnapshotTailTests: XCTestCase {
    private func log(lines: Int) -> Data {
        Data((0 ..< lines).map { "[00:00:0\($0 % 10)] line \($0)\n" }.joined().utf8)
    }

    func testAShortLogIsKeptWhole() {
        let data = log(lines: 3)
        XCTAssertEqual(LogSnapshot.tail(of: data, maxBytes: 4096), data)
    }

    func testTheNewestEntriesSurviveNotTheOldest() {
        let data = log(lines: 200)
        let kept = LogSnapshot.tail(of: data, maxBytes: 200)
        let text = String(decoding: kept, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("line 199\n"), text)
        XCTAssertFalse(text.contains("line 0\n"), text)
        XCTAssertLessThanOrEqual(kept.count, 200)
    }

    // A byte-offset cut lands mid-line. Half an entry reads as a corrupt file
    // and sends the reader after the wrong problem, so it is dropped.
    func testTheSnapshotStartsOnAWholeEntry() {
        let data = Data("[00:00:01] first\n[00:00:02] second\n".utf8)
        let kept = LogSnapshot.tail(of: data, maxBytes: 20)
        XCTAssertEqual(String(decoding: kept, as: UTF8.self), "[00:00:02] second\n")
    }

    // Nothing guarantees the log has newlines in it at all (a peer could log one
    // enormous line). Keeping raw bytes beats returning nothing.
    func testASingleUnbrokenLineIsTruncatedRatherThanDropped() {
        let data = Data(String(repeating: "x", count: 100).utf8)
        XCTAssertEqual(LogSnapshot.tail(of: data, maxBytes: 10).count, 10)
    }

    func testAnEmptyLogAndAZeroCapAreBothHandled() {
        XCTAssertEqual(LogSnapshot.tail(of: Data(), maxBytes: 4096), Data())
        XCTAssertEqual(LogSnapshot.tail(of: log(lines: 5), maxBytes: 0), Data())
    }
}

final class LogSnapshotComposeTests: XCTestCase {
    private let context = LogSnapshot.Context(
        appVersion: "1.16.1",
        appBuild: "342",
        model: "iPhone15,3",
        systemVersion: "18.5",
        deviceName: "Phil's iPhone"
    )

    func testTheHeaderNamesTheBuildAndTheDevice() {
        let out = LogSnapshot.compose(context: context,
                                      generatedAt: Date(timeIntervalSince1970: 0),
                                      log: Data("[00:00:01] hello sent\n".utf8))
        XCTAssertTrue(out.contains("1.16.1 (342)"), out)
        XCTAssertTrue(out.contains("iPhone15,3, iOS 18.5"), out)
        XCTAssertTrue(out.contains("Phil's iPhone"), out)
        XCTAssertTrue(out.hasSuffix("[00:00:01] hello sent\n"), out)
    }

    // The absence of entries is itself a finding: it says logging never ran,
    // which is a different bug from the one being reported.
    func testAnEmptyLogStillProducesAReportableSnapshot() {
        let out = LogSnapshot.compose(context: context,
                                      generatedAt: Date(timeIntervalSince1970: 0),
                                      log: Data())
        XCTAssertTrue(out.contains("(no entries yet)"), out)
        XCTAssertTrue(out.contains("iPhone15,3"), out)
    }

    func testTruncationIsAnnouncedOnlyWhenItHappened() {
        let short = LogSnapshot.compose(context: context,
                                        generatedAt: Date(timeIntervalSince1970: 0),
                                        log: Data("[00:00:01] a\n".utf8))
        XCTAssertFalse(short.contains("older entries dropped"), short)

        let long = Data((0 ..< 500).map { "[00:00:00] line \($0)\n" }.joined().utf8)
        let cut = LogSnapshot.compose(context: context,
                                      generatedAt: Date(timeIntervalSince1970: 0),
                                      log: long,
                                      maxBytes: 1024)
        XCTAssertTrue(cut.contains("older entries dropped"), cut)
        XCTAssertTrue(cut.hasSuffix("line 499\n"), String(cut.suffix(80)))
    }
}

final class LogSnapshotFileNameTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 0)

    func testDeviceNamesSurviveEveryFilesystemTheyPassThrough() {
        let name = LogSnapshot.fileName(deviceName: "Phil's iPad Pro 🎉", date: date)
        XCTAssertTrue(name.hasPrefix("OpenDisplay-Phil-s-iPad-Pro-"), name)
        XCTAssertTrue(name.hasSuffix(".txt"), name)
        XCTAssertFalse(name.contains("--"), name)
    }

    func testAnUnusableNameFallsBackToATimestampAlone() {
        let name = LogSnapshot.fileName(deviceName: "///", date: date)
        XCTAssertTrue(name.hasPrefix("OpenDisplay-"), name)
        XCTAssertFalse(name.contains("OpenDisplay--"), name)
        XCTAssertTrue(name.hasSuffix(".txt"), name)
    }
}
