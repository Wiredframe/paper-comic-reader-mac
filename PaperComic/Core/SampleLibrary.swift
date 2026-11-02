//
//  SampleLibrary.swift
//  Paper Comic Reader
//
//  First-launch sample content, as in the iOS app: an empty library gets six bundled demo
//  comics exactly once, so a fresh install (and App Review) opens on a populated shelf rather
//  than an empty state. A few get an open date, a resume page and a bookmark, so Recents,
//  progress and Bookmarks have something to show. They are ordinary entries: deleting them is
//  final, the seed never runs again.
//
//  The comics are drawn by scripts/screens/gendemo.swift and are entirely original.
//

import Foundation
import SwiftData

enum SampleLibrary {

	/// Set once the seed has run (even if it found nothing), so deleted samples never return.
	private static let seededKey = "didSeedSampleLibraryV1"

	private struct Sample {
		let resource: String        // .cbz base name in Resources/SampleComics
		let lastReadPage: Int       // 0-based resume page
		let openedHoursAgo: Double? // nil = never opened, so not in Recents
		let openCount: Int
		let isFavorite: Bool
		let bookmarks: [Int]
	}

	private static let samples: [Sample] = [
		Sample(resource: "Crimson Alley 3", lastReadPage: 7,  openedHoursAgo: 2,   openCount: 3, isFavorite: false, bookmarks: [5]),
		Sample(resource: "Deep Blue 2",     lastReadPage: 12, openedHoursAgo: 26,  openCount: 5, isFavorite: true,  bookmarks: [9]),
		Sample(resource: "Kite Season 2",   lastReadPage: 3,  openedHoursAgo: 50,  openCount: 1, isFavorite: false, bookmarks: []),
		Sample(resource: "Night Ferry 4",   lastReadPage: 9,  openedHoursAgo: 140, openCount: 4, isFavorite: true,  bookmarks: [4]),
		Sample(resource: "Solar Flare 1",   lastReadPage: 0,  openedHoursAgo: nil, openCount: 0, isFavorite: false, bookmarks: []),
		Sample(resource: "Jade Circuit 1",  lastReadPage: 0,  openedHoursAgo: nil, openCount: 0, isFavorite: false, bookmarks: []),
	]

	@MainActor
	static func seedIfNeeded(into context: ModelContext, defaults: UserDefaults = .standard) {
		guard !defaults.bool(forKey: seededKey) else { return }
		defaults.set(true, forKey: seededKey)
		// Only ever an empty library: never next to the user's own comics, nor after a migration
		// or a restore brought some in.
		let existing = (try? context.fetchCount(FetchDescriptor<ComicBook>())) ?? 0
		guard existing == 0 else { return }

		for sample in samples {
			guard let url = Bundle.main.url(forResource: sample.resource, withExtension: "cbz",
											 subdirectory: "SampleComics"),
				  let book = try? Importer.importComic(from: url, into: context) else { continue }
			book.lastReadPage = min(max(0, sample.lastReadPage), max(0, book.pageCount - 1))
			book.openCount = sample.openCount
			book.isFavorite = sample.isFavorite
			book.dateOpened = sample.openedHoursAgo.map { Date(timeIntervalSinceNow: -$0 * 3600) }
			for page in sample.bookmarks where page < book.pageCount {
				addBookmark(to: book, pageIndex: page, in: context)
			}
		}
		try? context.save()
	}

	/// The thumbnail and record the reader's own bookmark command would make.
	@MainActor
	private static func addBookmark(to book: ComicBook, pageIndex: Int, in context: ModelContext) {
		guard let data = (try? ComicArchive(url: book.archiveURL))?.pageData(at: pageIndex),
			  let image = ImageDownsampler.downsample(data, maxPixel: ImageDownsampler.libraryCardPixel)
		else { return }
		let name = "\(UUID().uuidString).jpg"
		guard ImageDownsampler.writeJPEG(image, to: Storage.bookmarkThumbURL(name)) else { return }
		let aspect: Double? = image.height > 0 ? Double(image.width) / Double(image.height) : nil
		context.insert(Bookmark(pageIndex: pageIndex, thumbName: name, pageAspect: aspect, book: book))
	}
}
