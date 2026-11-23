import SwiftUI
import UIKit

/// In-memory image cache preventing flicker when scrolling long songlists or switching tabs.
final class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 250
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

/// Lightweight native cached image view using `URLSession` + `ImageMemoryCache`.
struct CachedAsyncImage: View {
    let urlString: String?
    var cornerRadius: CGFloat = 8
    var placeholderIcon: String = "music.note"

    @State private var loadedImage: UIImage?
    @State private var failedURL: String?

    var body: some View {
        Color.clear
            .overlay {
                if let img = loadedImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.secondary.opacity(0.14)
                        Image(systemName: placeholderIcon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.65))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: urlString) {
                await loadIfNeeded()
            }
    }

    private func loadIfNeeded() async {
        guard let urlString, !urlString.isEmpty else {
            loadedImage = nil
            return
        }
        if let cached = ImageMemoryCache.shared.image(for: urlString) {
            loadedImage = cached
            return
        }
        if failedURL == urlString { return }

        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(HTTPClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        if let (data, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let image = UIImage(data: data) {
            ImageMemoryCache.shared.setImage(image, for: urlString)
            if !Task.isCancelled {
                loadedImage = image
            }
        } else {
            failedURL = urlString
        }
    }
}
