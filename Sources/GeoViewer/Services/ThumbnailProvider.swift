import AppKit
import ImageIO

/// NSImage 不是 Sendable，这里用一个不可变盒子显式声明跨并发域传递的安全性。
struct ImageBox: @unchecked Sendable {
    let image: NSImage
}

/// 生成并缓存缩略图。读取走 ImageIO 内嵌缩略图，速度远快于整图解码。
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private var cache: [String: ImageBox] = [:]
    private var insertionOrder: [String] = []
    private let cacheLimit = 500

    func thumbnail(for url: URL, maxPixel: Int) -> ImageBox? {
        let key = "\(url.path)#\(maxPixel)"
        if let cached = cache[key] { return cached }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let box = ImageBox(image: image)

        cache[key] = box
        insertionOrder.append(key)
        if insertionOrder.count > cacheLimit {
            let evicted = insertionOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return box
    }

    func clearCache() {
        cache.removeAll()
        insertionOrder.removeAll()
    }
}
