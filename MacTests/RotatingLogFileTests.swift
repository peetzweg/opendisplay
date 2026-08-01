import Foundation
import XCTest

final class RotatingLogFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenDisplayLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecreatesCurrentLogAfterItIsMoved() throws {
        let writer = RotatingLogFile(directory: directory, baseName: "test", maxBytes: 1_024)
        writer.append(Data("before move\n".utf8))

        let movedURL = directory.appendingPathComponent("attached.log")
        try FileManager.default.moveItem(at: writer.fileURL, to: movedURL)
        writer.append(Data("after move\n".utf8))

        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.fileURL.path))
        XCTAssertEqual(try String(contentsOf: writer.fileURL, encoding: .utf8), "after move\n")
        XCTAssertEqual(try String(contentsOf: movedURL, encoding: .utf8), "before move\n")
    }

    func testRecreatesCurrentLogAfterItIsDeleted() throws {
        let writer = RotatingLogFile(directory: directory, baseName: "test", maxBytes: 1_024)
        writer.append(Data("before delete\n".utf8))

        try FileManager.default.removeItem(at: writer.fileURL)
        writer.append(Data("after delete\n".utf8))

        XCTAssertEqual(try String(contentsOf: writer.fileURL, encoding: .utf8), "after delete\n")
    }

    func testReopensCurrentLogAfterAnotherWriterReplacesIt() throws {
        let writer = RotatingLogFile(directory: directory, baseName: "test", maxBytes: 1_024)
        writer.append(Data("old file\n".utf8))

        try Data("replacement\n".utf8).write(to: writer.fileURL, options: .atomic)
        writer.append(Data("after replacement\n".utf8))

        XCTAssertEqual(try String(contentsOf: writer.fileURL, encoding: .utf8),
                       "replacement\nafter replacement\n")
    }

    func testRotationKeepsTheNewestTwoBoundedGenerations() throws {
        let writer = RotatingLogFile(directory: directory, baseName: "test", maxBytes: 32)
        for index in 0..<40 {
            writer.append(Data(String(format: "%03d\n", index).utf8))
        }

        XCTAssertEqual(try String(contentsOf: writer.rotatedURL, encoding: .utf8),
                       (24..<32).map { String(format: "%03d\n", $0) }.joined())
        XCTAssertEqual(try String(contentsOf: writer.fileURL, encoding: .utf8),
                       (32..<40).map { String(format: "%03d\n", $0) }.joined())
        XCTAssertLessThanOrEqual(try fileSize(at: writer.rotatedURL), writer.maxBytes)
        XCTAssertLessThanOrEqual(try fileSize(at: writer.fileURL), writer.maxBytes)
    }

    func testSingleOversizedEntryCannotExceedTheCap() throws {
        let writer = RotatingLogFile(directory: directory, baseName: "test", maxBytes: 8)

        writer.append(Data("0123456789abcdef".utf8))

        XCTAssertEqual(try Data(contentsOf: writer.fileURL), Data("89abcdef".utf8))
        XCTAssertEqual(try fileSize(at: writer.fileURL), 8)
    }

    func testFailedRotationReportsTheErrorAndKeepsTheLiveFileBounded() throws {
        var errors: [String] = []
        let writer = RotatingLogFile(
            directory: directory,
            baseName: "test",
            maxBytes: 8,
            reportError: { errors.append($0) }
        )
        writer.append(Data("12345678".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                    ofItemAtPath: directory.path)
        }

        writer.append(Data("abcdefgh".utf8))

        XCTAssertEqual(try Data(contentsOf: writer.fileURL), Data("abcdefgh".utf8))
        XCTAssertEqual(try fileSize(at: writer.fileURL), 8)
        XCTAssertTrue(errors.contains { $0.contains("could not rotate") })
    }

    func testSeparateWritersDoNotOverwriteEachOther() throws {
        let first = RotatingLogFile(directory: directory, baseName: "test", maxBytes: 64 * 1_024)
        let second = RotatingLogFile(directory: directory, baseName: "test", maxBytes: 64 * 1_024)
        let group = DispatchGroup()
        let firstQueue = DispatchQueue(label: "log-test.first")
        let secondQueue = DispatchQueue(label: "log-test.second")

        group.enter()
        firstQueue.async {
            for index in 0..<250 {
                first.append(Data(String(format: "A-%03d\n", index).utf8))
            }
            group.leave()
        }
        group.enter()
        secondQueue.async {
            for index in 0..<250 {
                second.append(Data(String(format: "B-%03d\n", index).utf8))
            }
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let lines = try String(contentsOf: first.fileURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let expected = (0..<250).map { String(format: "A-%03d", $0) }
            + (0..<250).map { String(format: "B-%03d", $0) }
        XCTAssertEqual(lines.count, expected.count)
        XCTAssertEqual(Set(lines), Set(expected))
    }

    func testReportsFilesystemFailures() throws {
        let blockedDirectory = directory.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: blockedDirectory)
        var errors: [String] = []
        let writer = RotatingLogFile(
            directory: blockedDirectory,
            baseName: "test",
            maxBytes: 32,
            reportError: { errors.append($0) }
        )

        writer.append(Data("message\n".utf8))

        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(errors.contains { $0.contains("could not") })
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
