import Combine
import CryptoKit
import Foundation

/// Loads only the language selected by macOS. All view keys remain usable
/// English text while a pack is downloading or if it is unavailable.
@MainActor
final class AppLanguagePack: ObservableObject {
    struct Source {
        let url: URL
        let sha256: String
    }

    static let shared = AppLanguagePack()
    private static let maximumBytes = 64 * 1024

    private let preferredLanguages: [String]
    private let cacheDirectory: URL
    private let session: URLSession
    private let sourceOverride: Source?
    @Published private var bundle = Bundle.main
    private var started = false

    init(preferredLanguages: [String] = Locale.preferredLanguages,
         cacheDirectory: URL? = nil, session: URLSession? = nil, source: Source? = nil) {
        self.preferredLanguages = preferredLanguages
        self.cacheDirectory = cacheDirectory ?? URL.cachesDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "OpenDisplay", isDirectory: true)
            .appendingPathComponent("LanguagePacks", isDirectory: true)
        self.sourceOverride = source
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            self.session = URLSession(configuration: configuration)
        }
    }

    static func supportedLanguage(for preferredLanguages: [String]) -> String? {
        guard let preferred = preferredLanguages.first else { return nil }
        let language = Locale.Language(identifier: preferred)
        guard language.languageCode?.identifier == "zh", language.script?.identifier == "Hans" else { return nil }
        return "zh-Hans"
    }

    func text(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: bundle)
    }

    func load() async {
        guard !started, let locale = Self.supportedLanguage(for: preferredLanguages) else { return }
        started = true
        let source = sourceOverride ?? Self.source(for: locale)
        let languageDirectory = cacheDirectory
            .appendingPathComponent(source.sha256, isDirectory: true)
            .appendingPathComponent("\(locale).lproj", isDirectory: true)
        let stringsFile = languageDirectory.appendingPathComponent("Localizable.strings")

        if cachedPack(at: stringsFile, matches: source), let cachedBundle = Bundle(url: languageDirectory) {
            bundle = cachedBundle
            return
        }

        do {
            let data = try await download(from: source.url)
            guard Self.valid(data, matches: source) else { return }
            try FileManager.default.createDirectory(at: languageDirectory, withIntermediateDirectories: true)
            try data.write(to: stringsFile, options: .atomic)
            if let downloadedBundle = Bundle(url: languageDirectory) {
                bundle = downloadedBundle
            }
        } catch {
            // Localization is optional. Leave the English interface available,
            // without caching a failed request; the next launch may try again.
        }
    }

    private static func source(for locale: String) -> Source {
        // Published versions of these files are immutable. A subsequent pack
        // can use another versioned path without breaking older SHA-256 pins.
        let url = URL(string: "https://raw.githubusercontent.com/peetzweg/opendisplay/main/LanguagePacks/\(locale)/1/Localizable.strings")!
        let sha256 = "9d3726698ccd8588b6e15af17e06d0f48fe9eaee73abe285249da12c85501bbf"
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["OPENDISPLAY_LANGUAGE_PACK_TEST_URL"],
           let supplied = URLComponents(string: value), supplied.scheme == "http",
           supplied.host == "127.0.0.1", supplied.port != nil,
           supplied.user == nil, supplied.password == nil, let testURL = supplied.url {
            return Source(url: testURL, sha256: sha256)
        }
        #endif
        return Source(url: url, sha256: sha256)
    }

    private func cachedPack(at file: URL, matches source: Source) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumBytes) else { return false }
        return Self.valid(data, matches: source)
    }

    private func download(from url: URL) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url, delegate: LanguagePackRequestDelegate())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength < Int64(Self.maximumBytes) else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumBytes - 1 else {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return data
    }

    private static func valid(_ data: Data, matches source: Source) -> Bool {
        guard !data.isEmpty && data.count < maximumBytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == source.sha256,
              let strings = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] else {
            return false
        }
        return !strings.isEmpty
    }
}

private final class LanguagePackRequestDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
