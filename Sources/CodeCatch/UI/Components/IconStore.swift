import AppKit
import CodeCatchCore

/// Cached service logos through Google, else DuckDuckGo. No direct connections to service websites.
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()

    struct Icon {
        let image: NSImage, fullBleed: Bool

        /// A logo drawn as its own tile fills ours, cropped to that tile; anything else is fitted onto a white tile.
        init(_ image: NSImage) {
            let tile = image.tile
            self.image = tile ?? image
            fullBleed = tile != nil
        }
    }

    @Published private var icons: [String: Icon] = [:]
    private var requested: Set<String> = []

    private let defaults: UserDefaults
    private let folder: URL
    private let fetch: (URL) async throws -> (Data, URLResponse)

    init(defaults: UserDefaults = .standard,
         folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodeCatch/Icons", isDirectory: true),
         fetch: @escaping (URL) async throws -> (Data, URLResponse) = IconStore.download) {
        self.defaults = defaults
        self.folder = folder
        self.fetch = fetch
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 12
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: IconProxyRedirects(), delegateQueue: nil)
    }()

    /// The cached icon, starting a fetch the first time a domain is asked for.
    func icon(for domain: String?) -> Icon? {
        guard let domain, defaults.bool(forKey: Prefs.serviceIcons), ServiceIdentity.isHostname(domain) else { return nil }
        if let hit = icons[domain] { return hit }
        if requested.insert(domain).inserted { Task { await load(domain) } }
        return nil
    }

    func load(_ domain: String) async {
        defer { if !defaults.bool(forKey: Prefs.serviceIcons) { requested.remove(domain) } }
        guard defaults.bool(forKey: Prefs.serviceIcons), ServiceIdentity.isHostname(domain) else { return }
        let touch = folder.appendingPathComponent("\(domain).touch.png"), plain = folder.appendingPathComponent("\(domain).png")
        let miss = folder.appendingPathComponent("\(domain).miss")
        for url in [touch, plain] {
            if let image = NSImage(contentsOf: url) { icons[domain] = Icon(image); return }
        }
        if let date = (try? miss.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           date.timeIntervalSinceNow > -7 * 86400 { return }

        // Google first; DuckDuckGo only when Google has no sharp logo. The larger one wins.
        var best: NSImage?, definite = true
        for url in Self.proxies(for: domain) {
            guard defaults.bool(forKey: Prefs.serviceIcons), !Task.isCancelled else { return }
            guard let reply = try? await fetch(url), let http = reply.1 as? HTTPURLResponse,
                  Self.isIconProxyURL(http.url), [200, 404].contains(http.statusCode) else { definite = false; continue }
            // A 404 carries the proxy's stand-in globe; a real favicon may be as small as 16 px.
            guard http.statusCode == 200, let image = Self.usable(reply.0) else { continue }
            if image.pixels > best?.pixels ?? 0 { best = image }
            if image.pixels >= 32 { break }
        }
        guard defaults.bool(forKey: Prefs.serviceIcons), !Task.isCancelled else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let best, let png = best.pngData else {
            if definite { FileManager.default.createFile(atPath: miss.path, contents: nil) }
            return
        }
        try? png.write(to: plain)
        icons[domain] = Icon(best)
    }

    private static func proxies(for domain: String) -> [URL] {
        var google = URLComponents(string: "https://www.google.com/s2/favicons")!
        google.queryItems = [.init(name: "domain", value: domain), .init(name: "sz", value: "128")]
        return [google.url!, URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico")!]
    }

    private static func usable(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data),
              (1...2048).contains(image.size.width), (1...2048).contains(image.size.height), image.pixels >= 16,
              image.representations.allSatisfy({ $0.pixelsWide <= 2048 && $0.pixelsHigh <= 2048 }) else { return nil }
        return image
    }

    /// Only the favicon proxies and their image hosts may receive logo requests.
    nonisolated static func isIconProxyURL(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return (host == "www.google.com" && url.path == "/s2/favicons")
            || (["t0.gstatic.com", "t1.gstatic.com", "t2.gstatic.com", "t3.gstatic.com"].contains(host) && url.path == "/faviconV2")
            || (host == "icons.duckduckgo.com" && url.path.hasPrefix("/ip3/") && url.path.hasSuffix(".ico")
                && ServiceIdentity.isHostname(String(url.path.dropFirst(5).dropLast(4))))
    }

    /// Bound the download before decoding; prefixing a completed download still keeps it all in memory.
    private nonisolated static func download(_ url: URL) async throws -> (Data, URLResponse) {
        let limit = 1_048_576
        let (bytes, response) = try await session.bytes(from: url)
        guard response.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return (data, response)
    }
}

/// A proxy response cannot redirect the client to a service website.
private final class IconProxyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        IconStore.isIconProxyURL(request.url) ? request : nil
    }
}

private extension NSImage {
    /// The logo's own tile: its opaque part, when that is a square filled almost edge to edge,
    /// as with a rounded-square app icon inside a transparent margin. Glyphs and circles are not.
    var tile: NSImage? {
        guard let image = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = image.width, h = image.height
        var alpha = [UInt8](repeating: 0, count: w * h)
        let drawn = alpha.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue).map { $0.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)) } != nil
        }
        guard drawn else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1, opaque = 0
        for y in 0..<h { for x in 0..<w where alpha[y * w + x] > 128 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); opaque += 1
        } }
        let side = (w: maxX - minX + 1, h: maxY - minY + 1)
        // A rounded square fills ~95% of its box, a circle ~79%.
        guard maxX >= 0, side.w >= 2, abs(Double(side.w) / Double(side.h) - 1) < 0.04, Double(opaque) / Double(side.w * side.h) > 0.9,
              let cropped = image.cropping(to: CGRect(x: minX, y: minY, width: side.w, height: side.h)) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: side.w, height: side.h))
    }

    var pixels: Int { representations.map(\.pixelsWide).max() ?? 0 }

    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
