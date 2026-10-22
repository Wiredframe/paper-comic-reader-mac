//
//  TestSupport.swift
//  PaperComicTests
//
//  The tests run outside the app, unsandboxed, so Storage would otherwise resolve to the user's
//  real ~/Library/Application Support. Every test class calls `prepare()` first, which points
//  Storage at a throwaway folder before anything reads it.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

enum TestStorage {

	static let root: URL = FileManager.default.temporaryDirectory
		.appendingPathComponent("PaperComicTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

	static func prepare() {
		if Storage.rootOverride == nil {
			Storage.rootOverride = root
		}
		precondition(Storage.appSupport.path.hasPrefix(root.path),
					 "Storage was touched before the tests could redirect it")
	}

	/// A solid red JPEG of the given size.
	static func jpeg(width: Int, height: Int) -> Data {
		let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
								space: CGColorSpace(name: CGColorSpace.sRGB)!,
								bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
		context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		let data = NSMutableData()
		let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
		CGImageDestinationAddImage(destination, context.makeImage()!, nil)
		CGImageDestinationFinalize(destination)
		return data as Data
	}

	/// Writes a CBZ with `entries` (name to bytes) into a temporary file and returns its URL.
	static func makeCBZ(_ entries: [(String, Data)], name: String = UUID().uuidString) throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).cbz")
		try? FileManager.default.removeItem(at: url)
		let archive = try Archive(url: url, accessMode: .create)
		for (path, data) in entries {
			try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
				data.subdata(in: Int(position)..<Int(position) + size)
			}
		}
		return url
	}
}
