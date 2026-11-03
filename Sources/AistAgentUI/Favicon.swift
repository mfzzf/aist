import AistAI
import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// Site icons, fetched once per host and kept for the session: the site's own /favicon.ico, else
/// DuckDuckGo's icon service. Failures are remembered too, so a host is never retried.
actor FaviconCache {
    static let shared = FaviconCache()
    private var images: [String: PlatformImage?] = [:]
    private var inflight: [String: Task<PlatformImage?, Never>] = [:]

    func image(for host: String) async -> PlatformImage? {
        if let cached = images[host] { return cached }
        if let task = inflight[host] { return await task.value }
        let task = Task<PlatformImage?, Never> {
            for url in [URL(string: "https://\(host)/favicon.ico"), URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")] {
                guard let url else { continue }
                var req = URLRequest(url: url)
                req.timeoutInterval = 8
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 64,
                      let img = PlatformImage(data: data) else { continue }
                return img
            }
            return nil
        }
        inflight[host] = task
        let img = await task.value
        images[host] = img
        inflight[host] = nil
        return img
    }
}

struct Favicon: View {
    let host: String
    var size: CGFloat = 16
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                #if os(macOS)
                Image(nsImage: image).resizable().interpolation(.high)
                #else
                Image(uiImage: image).resizable().interpolation(.high)
                #endif
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(.secondary).padding(size * 0.08)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .task(id: host) { image = await FaviconCache.shared.image(for: host) }
    }
}

/// Loaded icons for synchronous use (inline in text). Views observing it redraw as icons arrive.
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()
    @Published private(set) var images: [String: PlatformImage] = [:]
    private var requested = Set<String>()

    /// The icon if loaded; otherwise starts loading it and returns nil.
    func image(for host: String) -> PlatformImage? {
        if let img = images[host] { return img }
        if requested.insert(host).inserted {
            Task {
                if let img = await FaviconCache.shared.image(for: host) {
                    images[host] = Self.sized(img, 14)
                }
            }
        }
        return nil
    }

    private static func sized(_ img: PlatformImage, _ side: CGFloat) -> PlatformImage {
        #if os(macOS)
        let out = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            img.draw(in: rect)
            return true
        }
        return out
        #else
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 3).addClip()
            img.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        #endif
    }
}
