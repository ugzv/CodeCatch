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

private func png(side: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: side * 4, bitsPerPixel: 32)!
    bitmap.bitmapData!.initialize(repeating: 255, count: side * side * 4)
    return bitmap.representation(using: .png, properties: [:])!
}

private let iconPNG = png(side: 32)

/// A 64 px logo of one black shape on transparency, the way favicons come.
private func logo(_ shape: (CGRect) -> NSBezierPath) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.black.setFill()
    shape(CGRect(x: 0, y: 0, width: 64, height: 64)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

enum LogoShape: CaseIterable, Sendable { case square, roundedSquareInMargin, circle, glyph }

private func iconResponse(_ url: URL, status: Int) throws -> HTTPURLResponse {
    try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                headerFields: ["Content-Type": "image/png"]))
}

struct IconProxyURLCase: Sendable {
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

        #expect(requests == 2)
        #expect(fixture.files.contains { $0.pathExtension == "miss" } == (status == 404))
    }

    /// Small sites only have a 16 px favicon (zabec.net); smaller is unusable and must not be refetched every launch.
    @Test(arguments: [(16, true), (8, false)])
    func smallFaviconsLoadAndUnusableOnesAreRememberedAsMisses(side: Int, loads: Bool) async throws {
        let fixture = try IconPrivacyFixture(enabled: true)
        defer { fixture.cleanUp() }
        let store = IconStore(defaults: fixture.defaults, folder: fixture.folder, fetch: { url in
            (png(side: side), try iconResponse(url, status: 200))
        })

        await store.load("example.com")

        #expect((store.icon(for: "example.com") != nil) == loads)
        #expect(fixture.files.contains { $0.pathExtension == "miss" } == !loads)
    }

    /// Google lacks or blurs some logos; DuckDuckGo fills in only then, and the sharper one wins.
    @Test(arguments: [(404, 0, 32, 32), (200, 16, 48, 48), (200, 16, 16, 16), (200, 64, 16, 64)])
    func duckDuckGoIsAskedOnlyWhenGoogleHasNoSharpLogo(googleStatus: Int, googleSide: Int, duckSide: Int, shown: Int) async throws {
        let fixture = try IconPrivacyFixture(enabled: true)
        defer { fixture.cleanUp() }
        var hosts: [String] = []
        let store = IconStore(defaults: fixture.defaults, folder: fixture.folder, fetch: { url in
            hosts.append(url.host ?? "")
            return url.host == "www.google.com"
                ? (googleSide > 0 ? png(side: googleSide) : Data(), try iconResponse(url, status: googleStatus))
                : (png(side: duckSide), try iconResponse(url, status: 200))
        })

        await store.load("example.com")

        #expect(hosts == (googleSide >= 32 ? ["www.google.com"] : ["www.google.com", "icons.duckduckgo.com"]))
        let icon = try #require(store.icon(for: "example.com"))
        #expect(icon.image.size.width == CGFloat(shown))
    }

    /// App-icon logos with rounded corners and a margin (Dynadot) fill the tile; glyphs and circles stay fitted on white.
    @Test(arguments: LogoShape.allCases)
    func tileShapedLogosFillTheIcon(shape: LogoShape) async throws {
        let fixture = try IconPrivacyFixture(enabled: true)
        defer { fixture.cleanUp() }
        let data = logo { box in
            switch shape {
            case .square: NSBezierPath(rect: box)
            case .roundedSquareInMargin: NSBezierPath(roundedRect: box.insetBy(dx: 6, dy: 6), xRadius: 12, yRadius: 12)
            case .circle: NSBezierPath(ovalIn: box)
            case .glyph: NSBezierPath(rect: CGRect(x: 22, y: 4, width: 20, height: 56))
            }
        }
        let store = IconStore(defaults: fixture.defaults, folder: fixture.folder, fetch: { url in (data, try iconResponse(url, status: 200)) })

        await store.load("example.com")

        let icon = try #require(store.icon(for: "example.com"))
        #expect(icon.fullBleed == [.square, .roundedSquareInMargin].contains(shape))
        if shape == .roundedSquareInMargin { #expect(icon.image.size.width == 52) }
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
        IconProxyURLCase("https://www.google.com/s2/favicons?domain=example.com&sz=128", allowed: true),
        IconProxyURLCase("https://WWW.GOOGLE.COM/s2/favicons", allowed: true),
        IconProxyURLCase("https://www.google.com:443/s2/favicons", allowed: true),
        IconProxyURLCase("https://t0.gstatic.com/faviconV2", allowed: true),
        IconProxyURLCase("https://t1.gstatic.com/faviconV2", allowed: true),
        IconProxyURLCase("https://t2.gstatic.com/faviconV2", allowed: true),
        IconProxyURLCase("https://t3.gstatic.com/faviconV2", allowed: true),
        IconProxyURLCase("http://www.google.com/s2/favicons"),
        IconProxyURLCase("https://www.google.com:8443/s2/favicons"),
        IconProxyURLCase("https://user@www.google.com/s2/favicons"),
        IconProxyURLCase("https://user:password@www.google.com/s2/favicons"),
        IconProxyURLCase("https://www.google.com/faviconV2"),
        IconProxyURLCase("https://www.google.com/s2/favicons/extra"),
        IconProxyURLCase("https://google.com/s2/favicons"),
        IconProxyURLCase("https://www.google.com.evil.test/s2/favicons"),
        IconProxyURLCase("https://t0.gstatic.com/s2/favicons"),
        IconProxyURLCase("https://t0.gstatic.com/faviconV2/extra"),
        IconProxyURLCase("https://t4.gstatic.com/faviconV2"),
        IconProxyURLCase("https://gstatic.com/faviconV2"),
        IconProxyURLCase("https://example.com/favicon.ico"),
        IconProxyURLCase("https://icons.duckduckgo.com/ip3/example.com.ico", allowed: true),
        IconProxyURLCase("https://icons.duckduckgo.com/ip3/a/b.ico"),
        IconProxyURLCase("https://icons.duckduckgo.com/ip2/example.com.ico"),
        IconProxyURLCase("https://duckduckgo.com/ip3/example.com.ico"),
        IconProxyURLCase("https://icons.duckduckgo.com.evil.test/ip3/example.com.ico"),
        IconProxyURLCase(nil)
    ])
    nonisolated func iconURLsCannotEscapeTheAllowedProxyHostsAndPaths(testCase: IconProxyURLCase) {
        #expect(IconStore.isIconProxyURL(testCase.candidate.flatMap(URL.init(string:))) == testCase.allowed)
    }
}
