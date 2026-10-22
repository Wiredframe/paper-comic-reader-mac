//
//  ImageDownsampler.swift
//  Comic Reader
//
//  Efficient image decoding via ImageIO: thumbnails are produced without ever
//  materialising the full-size bitmap, which keeps memory low when building
//  covers and page-grid thumbnails from large comic pages.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageDownsampler {

    /// Longest side (device pixels) for library-card images — cover thumbnails and
    /// bookmark page shots. Both render at the same full-width size in their grids
    /// (down to a single column), so they share this target; it's large enough to stay
    /// crisp at one column on the biggest displays. Stored images are decoded down further
    /// per cell at display time (see `DiskImage.maxPixel`, and `PeekDeck`, which decodes to
    /// the on-screen size rather than to this ceiling — covers stay sharp without the
    /// full-size decode pinning memory).
    static let libraryCardPixel: CGFloat = 1200

    /// Decodes `data` and returns an image whose longest side is at most
    /// `maxPixel` device pixels, decoded straight to that size.
    static func downsample(_ data: Data, maxPixel: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    /// Same as `downsample(_:maxPixel:)`, but reads straight from a file `url` so ImageIO
    /// streams only the bytes the thumbnail needs — the full-size image never materialises in
    /// memory the way `Data(contentsOf:)` + decode would. Preferred for on-disk covers and page
    /// thumbnails (see `DiskImage`), which is exactly where a large library scrolls a lot of them.
    static func downsample(url: URL, maxPixel: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Aspect (width / height) of the image at `url`, read from its **header only** — no
    /// bitmap is decoded, so this is cheap enough to run across a whole library. Backfills
    /// `ComicBook.coverAspect` for covers imported before it was captured. Stored covers are
    /// written already orientation-normalised (see `kCGImageSourceCreateThumbnailWithTransform`
    /// above), so the raw pixel dimensions need no transform.
    static func pixelAspect(ofImageAt url: URL) -> Double? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double,
              height > 0 else { return nil }
        return width / height
    }

    @discardableResult
    static func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat = 0.85) -> Bool {
        // Mac port: ImageIO instead of UIImage.jpegData, written beside the target and moved
        // into place so a reader never sees half a file.
        let temp = url.appendingPathExtension("tmp")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        _ = try? FileManager.default.removeItem(at: url)
        return (try? FileManager.default.moveItem(at: temp, to: url)) != nil
    }
}
