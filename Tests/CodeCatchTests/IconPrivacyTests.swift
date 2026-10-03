import AppKit
import Foundation
import Testing
@testable import CodeCatch
@testable import CodeCatchCore

@MainActor private final class IconPrivacyFixture {
    let suite = "IconPrivacyTests.\(UUID())"
    let defaults: UserDefaults
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("IconPrivacyTests.\(UUID())")
    var folder: URL { root.appendingPathComponent("icons") }

    init(enabled: Bool? = nil) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        if let enabled { defaults.set(enabled, forKey: Prefs.serviceIcons) }
        Prefs.register(in: defaults)
    }

    var files: [URL] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private let iconPNG: Data = {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 128, bitsPerPixel: 32)!
    bitmap.bitmapData!.initialize(repeating: 255, count: 32 * 128)
    return bitmap.representation(using: .png, properties: [:])!
}()

private func iconResponse(_ url: URL, status: Int) throws -> HTTPURLResponse {
    try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                headerFields: ["Content-Type": "image/png"]))
}

struct GoogleIconURLCase: Sendable {
    let candidate: String?
    let allowed: Bool

    init(_ candidate: String?, allowed: Bool = false) {
        self.candidate = candidate
        self.allowed = allowed
    }
}

@MainActor @Suite struct IconPrivacyTests {
    @Test func explicitOptOutPreventsNetworkAndCacheDirectoryCreation() async throws {
        let fixture = try IconPrivacyFixture(enabled: false)
        defer { fixture.cleanUp() }
        var requests: [URL] = []
        let store = IconStore(defaults: fixture.defaults, folder: fixture.folder, fetch: { url in
            requests.append(url)
            return (iconPNG, try iconResponse(url, status: 200))
        })

        #expect(!fixture.defaults.bool(forKey: Prefs.serviceIcons))
        await store.load("example.com")

        #expect(store.icon(for: "example.com") == nil)
        #expect(requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test(arguments: [false, true])
    func registeringDefaultsPreservesExplicitIconConsent(enabled: Bool) throws {
        let fixture = try IconPrivacyFixture(enabled: enabled)
        defer { fixture.cleanUp() }
        #expect(fixture.defaults.bool(forKey: Prefs.serviceIcons) == enabled)
    }

    @Test func defaultLookupUsesOneGoogleProxyRequestAndCachesTheIcon() async throws {
        let fixture = try IconPrivacyFixture()
        defer { fixture.cleanUp() }
        var requests: [URL] = []
        let store = IconStore(defaults: fixture.defaults, folder: fixture.folder, fetch: { url in
            requests.append(url)
            return (iconPNG, try iconResponse(url, status: 200))
        })

        #expect(fixture.defaults.bool(forKey: Prefs.serviceIcons))
        await store.load("example.com")

        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let components = try #require(URLComponents(url: request, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "www.google.com")
        #expect(components.path == "/s2/favicons")
        #expect(components.queryItems?.count == 2)
        #expect(components.queryItems?.contains(URLQueryItem(name: "domain", value: "example.com")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "sz", value: "128")) == true)
        #expect(store.icon(for: "example.com") != nil)
        #expect(fixture.files.contains { $0.pathExtension.lowercased() == "png" })
    }

    @Test(arguments: [200, 404])
    func optOutDuringFetchPreventsFollowUpRequestsAndResponseStorage(status: Int) async throws {
        let fixture = try IconPrivacyFixture(enabled: true)
        defer { fixture.cleanUp() }
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish()
            release.continuation.finish()
        }
        var requests: [URL] = []
        let store = IconStore(defaults: fixture.defaults, folder: fixture.folder, fetch: { url in
            requests.append(url)
            if requests.count == 1 {
                started.continuation.yield(())
                for await _ in release.stream { break }
            }
            return (status == 200 ? iconPNG : Data(), try iconResponse(url, status: status))
        })

        let load = Task { await store.load("example.com") }
        for await _ in started.stream { break }
        fixture.defaults.set(false, forKey: Prefs.serviceIcons)
        release.continuation.yield(())
        await load.value

        #expect(requests.count == 1)
        #expect(store.icon(for: "example.com") == nil)
        #expect(fixture.files.allSatisfy { $0.hasDirectoryPath })
    }

    @Test func transientNetworkFailureDoesNotPersistAMissingIconMarker() async throws {
        let fixture = try IconPrivacyFixture(enabled: true)
        defer { fixture.cleanUp() }
        let store = IconStore(defaults: fixture.defaults, folder: fixture.folder, fetch: { _ in
            throw URLError(.notConnectedToInternet)
        })

        await store.load("example.com")

        #expect(!fixture.files.contains { $0.pathExtension == "miss" })
    }

    @Test(arguments: [404, 429, 500])
    func onlyNotFoundResponsesPersistAMissingIconMarker(status: Int) async throws {
        let fixture = try IconPrivacyFixture(enabled: true)
        defer { fixture.cleanUp() }
        var requests = 0
        let store = IconStore(defaults: fixture.defaults, folder: fixture.folder, fetch: { url in
            requests += 1
            return (Data(), try iconResponse(url, status: status))
        })

        await store.load("example.com")

        #expect(requests == 1)
        #expect(fixture.files.contains { $0.pathExtension == "miss" } == (status == 404))
    }

    @Test func successfulResponseFromUnrelatedHostCannotBecomeAnIconOrPNGCache() async throws {
        let fixture = try IconPrivacyFixture(enabled: true)
        defer { fixture.cleanUp() }
        let unrelatedURL = try #require(URL(string: "https://unrelated.example/icon.png"))
        let store = IconStore(defaults: fixture.defaults, folder: fixture.folder, fetch: { _ in
            (iconPNG, try iconResponse(unrelatedURL, status: 200))
        })

        await store.load("example.com")

        #expect(store.icon(for: "example.com") == nil)
        #expect(!fixture.files.contains { $0.pathExtension.lowercased() == "png" })
    }

    @Test(arguments: [
        GoogleIconURLCase("https://www.google.com/s2/favicons?domain=example.com&sz=128", allowed: true),
        GoogleIconURLCase("https://WWW.GOOGLE.COM/s2/favicons", allowed: true),
        GoogleIconURLCase("https://www.google.com:443/s2/favicons", allowed: true),
        GoogleIconURLCase("https://t0.gstatic.com/faviconV2", allowed: true),
        GoogleIconURLCase("https://t1.gstatic.com/faviconV2", allowed: true),
        GoogleIconURLCase("https://t2.gstatic.com/faviconV2", allowed: true),
        GoogleIconURLCase("https://t3.gstatic.com/faviconV2", allowed: true),
        GoogleIconURLCase("http://www.google.com/s2/favicons"),
        GoogleIconURLCase("https://www.google.com:8443/s2/favicons"),
        GoogleIconURLCase("https://user@www.google.com/s2/favicons"),
        GoogleIconURLCase("https://user:password@www.google.com/s2/favicons"),
        GoogleIconURLCase("https://www.google.com/faviconV2"),
        GoogleIconURLCase("https://www.google.com/s2/favicons/extra"),
        GoogleIconURLCase("https://google.com/s2/favicons"),
        GoogleIconURLCase("https://www.google.com.evil.test/s2/favicons"),
        GoogleIconURLCase("https://t0.gstatic.com/s2/favicons"),
        GoogleIconURLCase("https://t0.gstatic.com/faviconV2/extra"),
        GoogleIconURLCase("https://t4.gstatic.com/faviconV2"),
        GoogleIconURLCase("https://gstatic.com/faviconV2"),
        GoogleIconURLCase("https://example.com/favicon.ico"),
        GoogleIconURLCase(nil)
    ])
    nonisolated func iconURLsCannotEscapeTheAllowedGoogleHostsAndPaths(testCase: GoogleIconURLCase) {
        #expect(IconStore.isGoogleIconURL(testCase.candidate.flatMap(URL.init(string:))) == testCase.allowed)
    }
}
