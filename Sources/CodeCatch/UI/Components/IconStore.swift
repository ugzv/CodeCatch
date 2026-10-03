import AppKit
import CodeCatchCore

/// Cached service logos through Google. No direct connections to service websites.
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()

    struct Icon { let image: NSImage; let fullBleed: Bool }

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
        return URLSession(configuration: config, delegate: GoogleIconRedirects(), delegateQueue: nil)
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
        let miss = folder.appendingPathComponent("\(domain).google.miss")
        for url in [touch, plain] {
            if let image = NSImage(contentsOf: url) { icons[domain] = Icon(image: image, fullBleed: image.isOpaqueSquare); return }
        }
        if let date = (try? miss.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           date.timeIntervalSinceNow > -7 * 86400 { return }

        guard !Task.isCancelled else { return }
        var url = URLComponents(string: "https://www.google.com/s2/favicons")!
        url.queryItems = [.init(name: "domain", value: domain), .init(name: "sz", value: "128")]
        do {
            let (data, response) = try await fetch(url.url!)
            guard defaults.bool(forKey: Prefs.serviceIcons), !Task.isCancelled,
                  let http = response as? HTTPURLResponse, Self.isGoogleIconURL(response.url) else { return }
            if http.statusCode == 404 {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: miss.path, contents: nil)
                return
            }
            guard http.statusCode == 200, let image = NSImage(data: data),
                  (1...2048).contains(image.size.width), (1...2048).contains(image.size.height),
                  (image.representations.map(\.pixelsWide).max() ?? 0) >= 32,
                  image.representations.allSatisfy({ $0.pixelsWide <= 2048 && $0.pixelsHigh <= 2048 }),
                  let png = image.pngData else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? png.write(to: plain)
            icons[domain] = Icon(image: image, fullBleed: image.isOpaqueSquare)
        } catch { return }
    }

    /// Only the favicon proxy and its image hosts may receive logo requests.
    nonisolated static func isGoogleIconURL(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return (host == "www.google.com" && url.path == "/s2/favicons")
            || (["t0.gstatic.com", "t1.gstatic.com", "t2.gstatic.com", "t3.gstatic.com"].contains(host) && url.path == "/faviconV2")
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
private final class GoogleIconRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        IconStore.isGoogleIconURL(request.url) ? request : nil
    }
}

private extension NSImage {
    /// Fills a tile edge to edge only if it is square with opaque corners;
    /// anything else is fitted onto a white tile rather than cropped.
    var isOpaqueSquare: Bool {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return false }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w >= 2, h >= 2, abs(Double(w) / Double(h) - 1) < 0.04 else { return false }
        return [(1, 1), (w - 2, 1), (1, h - 2), (w - 2, h - 2)].allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.95 }
    }

    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
