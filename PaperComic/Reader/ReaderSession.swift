//
//  ReaderSession.swift
//  Paper Comic Reader
//
//  One comic open in a window: fetching its bytes if they aren't local, opening the archive off
//  the main thread, where the reader is, and what gets written back to the library. The view
//  (ReaderView, PageCanvas) only shows what this says.
//
//  Progress follows the iOS app's rules: the resume page is written when the reader leaves the
//  comic, not on every turn; the comic counts as read once its last page has been on screen; and
//  a comic opened on a page of its own (a bookmark) only moves the resume page once the reader
//  has turned from there (see ReadingProgressGate).
//

import AppKit
import SwiftData

@MainActor
@Observable
final class ReaderSession: Identifiable {

	let book: ComicBook
	/// A page to open on instead of the resume page, for a bookmark.
	let initialPage: Int?
	var id: UUID { book.id }

	enum Phase: Equatable {
		case loading
		case downloading
		case ready
		case failed(String)
	}
	private(set) var phase: Phase = .loading
	private(set) var store: PageImageStore?

	/// The first page on screen. With two pages side by side the other one is `visiblePages`.
	private(set) var currentPage = 0
	/// Bumped when the paper setting changes, so the canvas fetches its images again.
	private(set) var paperGeneration = 0

	private let model: AppModel
	private let gate = ReadingProgressGate()
	private var didCountOpen = false
	private var isClosed = false
	/// Pages being bookmarked right now, so a quick second press doesn't add the same one twice.
	private var bookmarking: Set<Int> = []

	init(book: ComicBook, initialPage: Int? = nil, model: AppModel) {
		self.book = book
		self.initialPage = initialPage
		self.model = model
	}

	var settings: ReaderSettings { model.reader }
	var pageCount: Int { store?.pageCount ?? book.pageCount }

	var paging: ReaderPaging {
		ReaderPaging(pageCount: pageCount, double: settings.doublePage)
	}

	/// The pages on screen, in reading order.
	var visiblePages: [Int] {
		guard pageCount > 0 else { return [] }
		return paging.pages(inSlot: paging.slot(forPage: currentPage))
	}

	var downloadProgress: Double? {
		model.downloads.ticket(for: book.id)?.progress
	}

	// MARK: Opening

	func open() async {
		guard store == nil else { return }
		if !Storage.fm.fileExists(atPath: book.archiveURL.path) {
			guard book.isFolderBacked else {
				phase = .failed(String(localized: "This comic’s file is missing. Import it again to read it."))
				return
			}
			phase = .downloading
			do {
				try await model.downloads.join(book, in: model.context)
			} catch LibrarySource.SourceError.cancelled {
				phase = .failed(String(localized: "The download was stopped."))
				return
			} catch {
				model.downloads.clearFailure(for: book.id)
				phase = .failed(Self.describe(error as? LibrarySource.SourceError))
				return
			}
			guard !isClosed else { return }
		}
		phase = .loading
		let opened = await PageImageStore.open(bookID: book.id, url: book.archiveURL,
											   paperEnabled: model.paper.isEnabled,
											   paperParams: model.paper.params)
		guard !isClosed else { return }
		guard opened.pageCount > 0 else {
			phase = .failed(String(localized: "This comic can’t be opened. The file may be damaged."))
			return
		}
		store = opened
		model.register(self)
		// The file may not be page for page what the library recorded (replaced, re-scanned).
		if book.pageCount != opened.pageCount { book.pageCount = opened.pageCount }
		let start = min(max(initialPage ?? book.lastReadPage, 0), opened.pageCount - 1)
		currentPage = paging.pages(inSlot: paging.slot(forPage: start)).first ?? start
		gate.opened(at: currentPage)
		opened.setActivePage(currentPage)
		phase = .ready
		if !didCountOpen {
			didCountOpen = true
			book.openCount += 1
		}
		book.dateOpened = .now
		markReadIfAtEnd()
		try? model.context.save()
	}

	private static func describe(_ error: LibrarySource.SourceError?) -> String {
		switch error {
		case .notConfigured:
			return String(localized: "This comic comes from a library folder that isn’t set up. Choose it in Settings.")
		case .fileMissing:
			return String(localized: "This comic isn’t in the library folder any more. It may have been moved or renamed.")
		default:
			return String(localized: "The library folder can’t be reached. The volume may be offline, or the folder may have moved.")
		}
	}

	// MARK: Moving

	func go(to page: Int) {
		guard pageCount > 0 else { return }
		let clamped = min(max(page, 0), pageCount - 1)
		let first = paging.pages(inSlot: paging.slot(forPage: clamped)).first ?? clamped
		guard first != currentPage else { return }
		currentPage = first
		gate.reached(first)
		store?.setActivePage(first)
		markReadIfAtEnd()
	}

	func next() {
		let slot = paging.slot(forPage: currentPage)
		guard slot + 1 < paging.slotCount else { return }
		go(to: paging.pages(inSlot: slot + 1)[0])
	}

	func previous() {
		let slot = paging.slot(forPage: currentPage)
		guard slot > 0 else { return }
		go(to: paging.pages(inSlot: slot - 1)[0])
	}

	func first() { go(to: 0) }
	func last() { go(to: pageCount - 1) }

	var canGoNext: Bool { paging.slot(forPage: currentPage) + 1 < paging.slotCount }
	var canGoPrevious: Bool { paging.slot(forPage: currentPage) > 0 }

	/// Reflows after the double-page setting changed, keeping the page the reader is on.
	func layoutChanged() {
		guard pageCount > 0 else { return }
		currentPage = paging.pages(inSlot: paging.slot(forPage: currentPage)).first ?? currentPage
	}

	// MARK: Progress

	/// Read once the last page has been on screen. Never un-marked automatically.
	private func markReadIfAtEnd() {
		guard pageCount > 0, !book.isRead, visiblePages.contains(pageCount - 1),
			  gate.countsAsProgress(peek: initialPage != nil) else { return }
		book.isRead = true
	}

	/// Writes the resume page. Called when the reader leaves the comic and when the app quits.
	func persistProgress() {
		guard phase == .ready, gate.countsAsProgress(peek: initialPage != nil) else { return }
		if book.lastReadPage != currentPage { book.lastReadPage = currentPage }
		try? model.context.save()
	}

	func close() {
		guard !isClosed else { return }
		persistProgress()
		isClosed = true
		store = nil
		model.unregister(self)
	}

	// MARK: Paper

	func paperChanged() {
		store?.setPaper(enabled: model.paper.isEnabled, params: model.paper.params)
		paperGeneration += 1
	}

	// MARK: Bookmarks

	var isCurrentPageBookmarked: Bool {
		book.bookmarks.contains { visiblePages.contains($0.pageIndex) }
	}

	/// Bookmarks the page on screen (the left one of two), or removes the bookmark there.
	func toggleBookmark() {
		if let existing = book.bookmarks.first(where: { visiblePages.contains($0.pageIndex) }) {
			try? Storage.fm.removeItem(at: existing.thumbURL)
			model.context.delete(existing)
			try? model.context.save()
			return
		}
		let page = currentPage
		guard let store, !bookmarking.contains(page) else { return }
		bookmarking.insert(page)
		Task {
			defer { bookmarking.remove(page) }
			guard let image = await store.thumbnail(at: page, maxPixel: ImageDownsampler.libraryCardPixel) else { return }
			let name = "\(UUID().uuidString).jpg"
			let url = Storage.bookmarkThumbURL(name)
			let written = await Task.detached(priority: .userInitiated) {
				ImageDownsampler.writeJPEG(image, to: url)
			}.value
			guard written, !book.isDeleted else { return }
			let aspect: Double? = image.height > 0 ? Double(image.width) / Double(image.height) : nil
			let mark = Bookmark(pageIndex: page, thumbName: name, pageAspect: aspect, book: book)
			model.context.insert(mark)
			try? model.context.save()
		}
	}
}

/// The 1 or 2 pages a reader position shows. Cover alone, then fixed pairs (1·2, 3·4, …), so a
/// page never changes sides when the layout is toggled. Ported from the iOS reader.
struct ReaderPaging {
	let pageCount: Int
	let double: Bool

	var slotCount: Int {
		guard pageCount > 0 else { return 0 }
		return double ? 1 + pageCount / 2 : pageCount
	}

	/// The 1 or 2 page indices shown in a slot (the second may be absent at the end).
	func pages(inSlot slot: Int) -> [Int] {
		guard double else { return [slot] }
		if slot == 0 { return [0] }
		let left = 2 * slot - 1
		let right = 2 * slot
		return right < pageCount ? [left, right] : [left]
	}

	/// The slot that contains a given page.
	func slot(forPage page: Int) -> Int {
		guard double else { return page }
		return page == 0 ? 0 : (page + 1) / 2
	}
}

/// Whether the reader has moved since the comic was opened, so a look at a bookmark doesn't
/// overwrite the resume page. Ported from the iOS reader.
@MainActor
final class ReadingProgressGate {
	private var openedPage: Int?
	private(set) var movedSinceOpen = false

	func opened(at page: Int) { openedPage = page }

	func reached(_ page: Int) {
		if let openedPage, page != openedPage { movedSinceOpen = true }
	}

	func countsAsProgress(peek: Bool) -> Bool { !peek || movedSinceOpen }
}
