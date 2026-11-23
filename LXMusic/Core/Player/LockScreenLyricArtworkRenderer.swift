import Foundation
import UIKit

/// High-performance CoreGraphics renderer that dynamically draws album artwork with scrolling lyrics
/// for lock-screen display in `MPNowPlayingInfoCenter`.
@MainActor
final class LockScreenLyricArtworkRenderer {
    static let shared = LockScreenLyricArtworkRenderer()

    private var renderedCache: [String: UIImage] = [:]
    private var cacheKeysOrder: [String] = []
    private let maxCacheCount = 30

    private init() {}

    /// Renders an 800x800 lock-screen artwork with current, previous, and next lyric lines over the album cover.
    func render(
        trackId: String,
        lineIndex: Int,
        baseArtwork: UIImage?,
        trackName: String,
        artistName: String,
        currentLyric: String,
        prevLyric: String?,
        nextLyric: String?,
        displayLines: Int = 3
    ) -> UIImage {
        let cacheKey = "\(trackId)_\(lineIndex)_\(displayLines)_\(currentLyric.hashValue)"
        if let cached = renderedCache[cacheKey] {
            return cached
        }

        let size = CGSize(width: 800, height: 800)
        let renderer = UIGraphicsImageRenderer(size: size)

        let image = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)

            // 1. Draw base album artwork (AspectFill) or fallback dark gradient
            if let base = baseArtwork {
                let fillRect = aspectFillRect(for: base.size, in: rect)
                base.draw(in: fillRect)
            } else {
                drawFallbackBackground(in: rect, ctx: ctx.cgContext)
            }

            // 2. Dark contrast overlay for high lyric readability
            let overlayColor = UIColor.black.withAlphaComponent(0.68)
            overlayColor.setFill()
            UIRectFill(rect)

            // Subtle top and bottom vignette gradient
            drawVignetteOverlay(in: rect, ctx: ctx.cgContext)

            // 3. Top Header: Track Name & Artist
            let headerStyle = NSMutableParagraphStyle()
            headerStyle.alignment = .center
            headerStyle.lineBreakMode = .byTruncatingTail

            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.75),
                .paragraphStyle: headerStyle
            ]
            let headerText = "\(trackName) · \(artistName)"
            let headerRect = CGRect(x: 40, y: 55, width: size.width - 80, height: 32)
            (headerText as NSString).draw(in: headerRect, withAttributes: headerAttrs)

            // 4. Center Lyric Lines
            let centerY = size.height * 0.48
            let sideLineOffset: CGFloat = 85

            // Previous Lyric Line (if 3-line mode)
            if displayLines >= 3, let prev = prevLyric, !prev.isEmpty {
                let prevStyle = NSMutableParagraphStyle()
                prevStyle.alignment = .center
                prevStyle.lineBreakMode = .byTruncatingTail

                let prevAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 24, weight: .regular),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.48),
                    .paragraphStyle: prevStyle
                ]
                let prevRect = CGRect(x: 40, y: centerY - sideLineOffset - 24, width: size.width - 80, height: 60)
                (prev as NSString).draw(in: prevRect, withAttributes: prevAttrs)
            }

            // Current Highlighted Lyric Line
            let currentStyle = NSMutableParagraphStyle()
            currentStyle.alignment = .center
            currentStyle.lineBreakMode = .byWordWrapping

            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.9)
            shadow.shadowOffset = CGSize(width: 0, height: 2)
            shadow.shadowBlurRadius = 8

            let currentAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: currentStyle,
                .shadow: shadow
            ]
            let currentRect = CGRect(x: 40, y: centerY - 35, width: size.width - 80, height: 80)
            (currentLyric as NSString).draw(in: currentRect, withAttributes: currentAttrs)

            // Next Lyric Line (if 3-line mode)
            if displayLines >= 3, let next = nextLyric, !next.isEmpty {
                let nextStyle = NSMutableParagraphStyle()
                nextStyle.alignment = .center
                nextStyle.lineBreakMode = .byTruncatingTail

                let nextAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 24, weight: .regular),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.48),
                    .paragraphStyle: nextStyle
                ]
                let nextRect = CGRect(x: 40, y: centerY + sideLineOffset - 8, width: size.width - 80, height: 60)
                (next as NSString).draw(in: nextRect, withAttributes: nextAttrs)
            }

            // 5. Bottom Brand Footnote
            let footerStyle = NSMutableParagraphStyle()
            footerStyle.alignment = .center
            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.3),
                .paragraphStyle: footerStyle
            ]
            let footerRect = CGRect(x: 40, y: size.height - 55, width: size.width - 80, height: 24)
            ("LX Music" as NSString).draw(in: footerRect, withAttributes: footerAttrs)
        }

        // Cache retention
        renderedCache[cacheKey] = image
        cacheKeysOrder.append(cacheKey)
        if cacheKeysOrder.count > maxCacheCount {
            let evicted = cacheKeysOrder.removeFirst()
            renderedCache.removeValue(forKey: evicted)
        }

        return image
    }

    func clearCache() {
        renderedCache.removeAll()
        cacheKeysOrder.removeAll()
    }

    // MARK: - Drawing Helpers

    private func aspectFillRect(for sourceSize: CGSize, in targetRect: CGRect) -> CGRect {
        guard sourceSize.width > 0 && sourceSize.height > 0 else { return targetRect }
        let scale = max(targetRect.width / sourceSize.width, targetRect.height / sourceSize.height)
        let w = sourceSize.width * scale
        let h = sourceSize.height * scale
        let x = targetRect.midX - w / 2
        let y = targetRect.midY - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func drawFallbackBackground(in rect: CGRect, ctx: CGContext) {
        let colors = [
            UIColor(red: 26/255, green: 29/255, blue: 36/255, alpha: 1).cgColor,
            UIColor(red: 11/255, green: 13/255, blue: 17/255, alpha: 1).cgColor
        ] as CFArray
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: rect.width, y: rect.height), options: [])
        }
    }

    private func drawVignetteOverlay(in rect: CGRect, ctx: CGContext) {
        let colors = [
            UIColor.black.withAlphaComponent(0.4).cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.5).cgColor
        ] as CFArray
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.5, 1.0]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: 0), end: CGPoint(x: rect.midX, y: rect.height), options: [])
        }
    }
}
