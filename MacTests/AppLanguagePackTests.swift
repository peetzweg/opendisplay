import CryptoKit
import Foundation
import XCTest

final class AppLanguagePackTests: XCTestCase {
    private static let fixture = Data("""
    "Devices" = "设备";
    "Connect %@" = "连接 %@";
    "Found %lld" = "找到 %lld 台";
    """.utf8)

    @MainActor
    func testPrimaryLanguageChoosesSimplifiedChineseOnly() {
        for preferred in ["zh", "zh-Hans", "zh-CN", "zh-SG", "zh-Hans-HK"] {
            XCTAssertEqual(AppLanguagePack.supportedLanguage(for: [preferred]), "zh-Hans", preferred)
        }
        for preferred in ["en-US", "ja", "zh-Hant", "zh-HK", "zh-MO", "zh-TW"] {
            XCTAssertNil(AppLanguagePack.supportedLanguage(for: [preferred, "zh-Hans"]), preferred)
        }
        XCTAssertNil(AppLanguagePack.supportedLanguage(for: []))
    }

    @MainActor
    func testDownloadCachesVerifiedPackAndPreservesInterpolation() async throws {
        try await withHarness(response: .success(Self.fixture)) { cache, session, source in
            let language = AppLanguagePack(preferredLanguages: ["zh-CN"], cacheDirectory: cache,
                                           session: session, source: source)
            XCTAssertEqual(language.text("Devices"), "Devices")
            await language.load()
            await language.load()
            XCTAssertEqual(language.text("Devices"), "设备")
            XCTAssertEqual(language.text("Connect \("iPad")"), "连接 iPad")
            XCTAssertEqual(language.text("Found \(3)"), "找到 3 台")
            XCTAssertEqual(language.text("Untranslated text"), "Untranslated text")
            XCTAssertEqual(PackURLProtocol.requests(to: source.url), 1)

            PackURLProtocol.setResponse(.failure(URLError(.notConnectedToInternet)), for: source.url)
            let offline = AppLanguagePack(preferredLanguages: ["zh-Hans"], cacheDirectory: cache,
                                          session: session, source: source)
            await offline.load()
            XCTAssertEqual(offline.text("Devices"), "设备")
            XCTAssertEqual(PackURLProtocol.requests(to: source.url), 1)
        }
    }

    @MainActor
    func testInvalidPackAndFailedDownloadLeaveEnglishWithoutCache() async throws {
        let responses: [Result<Data, URLError>] = [
            .success(Data("\"Devices\" = \"Bad checksum\";".utf8)),
            .success(Data(repeating: 0, count: 64 * 1024)),
            .failure(URLError(.notConnectedToInternet)),
        ]
        for response in responses {
            try await withHarness(response: response) { cache, session, source in
                let language = AppLanguagePack(preferredLanguages: ["zh-Hans"], cacheDirectory: cache,
                                               session: session, source: source)
                await language.load()
                XCTAssertEqual(language.text("Devices"), "Devices")
                XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
                XCTAssertEqual(PackURLProtocol.requests(to: source.url), 1)
            }
        }
    }

    @MainActor
    func testUnsupportedLanguageDoesNotDownload() async throws {
        try await withHarness(response: .success(Self.fixture)) { cache, session, source in
            let language = AppLanguagePack(preferredLanguages: ["en-US", "zh-Hans"], cacheDirectory: cache,
                                           session: session, source: source)
            await language.load()
            XCTAssertEqual(language.text("Devices"), "Devices")
            XCTAssertEqual(PackURLProtocol.requests(to: source.url), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        }
    }

    @MainActor
    private func withHarness(response: Result<Data, URLError>,
                             run: (URL, URLSession, AppLanguagePack.Source) async throws -> Void) async throws {
        let suffix = UUID().uuidString
        let url = URL(string: "https://localization-test.invalid/\(suffix)")!
        let sha256 = SHA256.hash(data: Self.fixture).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suffix, isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        PackURLProtocol.setResponse(response, for: url)
        defer {
            session.invalidateAndCancel()
            PackURLProtocol.remove(url)
            try? FileManager.default.removeItem(at: directory)
        }
        try await run(directory, session, AppLanguagePack.Source(url: url, sha256: sha256))
    }
}

private final class PackURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responses: [URL: Result<Data, URLError>] = [:]
    private static var counts: [URL: Int] = [:]

    static func setResponse(_ response: Result<Data, URLError>, for url: URL) {
        lock.withLock { responses[url] = response }
    }

    static func requests(to url: URL) -> Int {
        lock.withLock { counts[url, default: 0] }
    }

    static func remove(_ url: URL) {
        lock.withLock {
            responses.removeValue(forKey: url)
            counts.removeValue(forKey: url)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let result = Self.lock.withLock {
            Self.counts[url, default: 0] += 1
            return Self.responses[url] ?? .failure(URLError(.notConnectedToInternet))
        }
        switch result {
        case .success(let data):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
