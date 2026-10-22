//
//  CoverImage.swift
//  Paper Comic Reader
//
//  A cover (or bookmark shot) loaded off the main thread, decoded straight to the size it is
//  drawn at, and let go of when its cell scrolls away. Together with the bounded cache below
//  that keeps a large grid from pinning every cover it has ever shown.
//

import SwiftUI

struct CoverImage: View {

	let url: URL?
	/// Longest side to decode to, in pixels. Rounded up to 128-pixel steps, so dragging the size
	/// slider reuses decoded covers instead of decoding every visible one at each notch.
	let maxPixel: CGFloat

	@State private var image: CGImage?
	/// What the view currently wants. A decode that finishes after the view moved on is dropped.
	@State private var wanted: URL?

	var body: some View {
		Group {
			if let image {
				Image(decorative: image, scale: 1)
					.resizable()
					.aspectRatio(contentMode: .fill)
			} else {
				Color.clear
			}
		}
		.onAppear { load(url) }
		// The details pane reuses one view and only swaps the url, so the reload is driven from
		// here, with the URL the closure is handed rather than the one on `self`.
		.onChange(of: url) { _, newURL in load(newURL) }
		.onDisappear {
			wanted = nil
			image = nil
		}
	}

	private func load(_ target: URL?) {
		wanted = target
		guard let target else {
			image = nil
			return
		}
		let pixel = (maxPixel / 128).rounded(.up) * 128
		let key = "\(target.path)#\(Int(pixel))"
		if let cached = CoverCache.image(forKey: key) {
			image = cached
			return
		}
		image = nil
		Task.detached(priority: .userInitiated) {
			guard let decoded = ImageDownsampler.downsample(url: target, maxPixel: pixel) else { return }
			CoverCache.set(decoded, forKey: key)
			await MainActor.run {
				guard wanted == target else { return }
				image = decoded
			}
		}
	}
}

/// Decoded covers, bounded by their size in memory. NSCache also lets go under memory pressure,
/// and a cover decodes again from disk cheaply.
enum CoverCache {

	private static let cache: NSCache<NSString, CGImageBox> = {
		let cache = NSCache<NSString, CGImageBox>()
		let gigabytes = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
		cache.totalCostLimit = (gigabytes >= 8 ? 160 : 80) * 1024 * 1024
		return cache
	}()

	static func image(forKey key: String) -> CGImage? {
		cache.object(forKey: key as NSString)?.image
	}

	static func set(_ image: CGImage, forKey key: String) {
		cache.setObject(CGImageBox(image), forKey: key as NSString, cost: image.width * image.height * 4)
	}
}
