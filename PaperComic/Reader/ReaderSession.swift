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
final class ReaderSession {

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

	/// The page the reader is at: the one they turned or jumped to. With two pages side by side
	/// it may be either of them. Kept apart from the pair on screen so that switching between one
	/// and two pages, or a pairing that changes as wide pages are found, never drifts it.
	private(set) var anchorPage = 0
	/// How pages pair up. Rebuilt when the layout setting changes or wide pages are found.
	private(set) var paging = ReaderPaging(pageCount: 0, double: false)
	/// Pages wider than tall: a scanned double page, shown on its own even in two-page mode.
	private var widePages: Set<Int> = []
	/// Bumped when the paper setting changes, so the canvas fetches its images again.
	private(set) var paperGeneration = 0

	/// The canvas showing this comic, for the zoom commands.
	let canvas = CanvasBridge()

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

	/// The pages on screen, in reading order.
	var visiblePages: [Int] {
		guard paging.pageCount > 0 else { return [] }
		return paging.pages(inSlot: paging.slot(forPage: anchorPage))
	}

	/// The first page on screen.
	var currentPage: Int { visiblePages.first ?? anchorPage }

	private func rebuildPaging() {
		paging = ReaderPaging(pageCount: pageCount, double: settings.doublePage, wide: widePages)
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
		let paperEnabled = model.paper.isEnabled, paperParams = model.paper.params
		let opened = await PageImageStore.open(bookID: book.id, url: book.archiveURL,
											   paperEnabled: paperEnabled,
											   paperParams: paperParams)
		guard !isClosed else { return }
		guard opened.pageCount > 0 else {
			phase = .failed(String(localized: "This comic can’t be opened. The file may be damaged."))
			return
		}
		store = opened
		model.register(self)
		// The paper setting may have changed while the archive opened.
		if model.paper.isEnabled != paperEnabled || model.paper.params != paperParams {
			opened.setPaper(enabled: model.paper.isEnabled, params: model.paper.params)
		}
		// The file may not be page for page what the library recorded (replaced, re-scanned).
		if book.pageCount != opened.pageCount { book.pageCount = opened.pageCount }
		anchorPage = min(max(initialPage ?? book.lastReadPage, 0), opened.pageCount - 1)
		// The first spread's shapes before anything is shown: otherwise its pages are laid out
		// as a guess and jump (and the window with them) once their images are decoded.
		await opened.readAspects(of: Array(anchorPage - 2...anchorPage + 3))
		guard !isClosed else { return }
		widePages = Set(opened.knownAspects().filter { $0.value > 1.05 }.keys)
		rebuildPaging()
		gate.opened(at: anchorPage)
		opened.setActivePage(anchorPage)
		phase = .ready
		// Every page's shape, read from the image headers, nearest first: a wide one gets a slot
		// of its own. Cheap on a local file, and done long before the reader gets there.
		opened.scanAspects(from: anchorPage) { [weak self] batch in
			guard let self else { return }
			// A page ahead gets its real shape now, not when it is decoded on the way there.
			self.canvas.view?.aspectsArrived(batch)
			let wide = Set(batch.filter { $0.value > 1.05 }.keys)
			guard !wide.isSubset(of: self.widePages) else { return }
			self.widePages.formUnion(wide)
			self.rebuildPaging()
		}
		if !didCountOpen {
			didCountOpen = true
			book.openCount += 1
		}
		book.dateOpened = .now
		markReadIfAtEnd()
		try? model.context.save()
	}

	/// Tries again after a failed download, for a volume that has come back.
	func retry() {
		guard case .failed = phase else { return }
		phase = .loading
		Task { await open() }
	}

	/// The comic's file moved: the reader picked it by hand. Copied in so it opens now; when the
	/// pick lies inside the library folder it also becomes the comic's new place there.
	func relink(to url: URL) {
		let dest = book.archiveURL
		phase = .loading
		Task {
			do {
				let relinked = try await Task.detached(priority: .userInitiated) {
					try Importer.relink(from: url, into: dest)
				}.value
				if let path = relinked.relativePath { book.sourceRelativePath = path }
				book.pageCount = relinked.pageCount
				book.lastReadPage = min(book.lastReadPage, max(relinked.pageCount - 1, 0))
				try? Storage.fm.removeItem(at: Storage.pageThumbs(for: book.id))
				book.hasLocalArchive = true
				try? model.context.save()
				await open()
			} catch {
				phase = .failed(String(localized: "That file couldn’t be opened as a comic."))
			}
		}
	}

	static func describe(_ error: LibrarySource.SourceError?) -> String {
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
		guard clamped != anchorPage else { return }
		anchorPage = clamped
		gate.reached(clamped)
		store?.setActivePage(clamped)
		markReadIfAtEnd()
		scheduleProgressSave()
	}

	func next() {
		let slot = paging.slot(forPage: anchorPage)
		guard slot + 1 < paging.slotCount else { return }
		go(to: paging.pages(inSlot: slot + 1)[0])
	}

	func previous() {
		let slot = paging.slot(forPage: anchorPage)
		guard slot > 0 else { return }
		go(to: paging.pages(inSlot: slot - 1)[0])
	}

	func first() { go(to: 0) }
	func last() { go(to: pageCount - 1) }

	var canGoNext: Bool { paging.slot(forPage: anchorPage) + 1 < paging.slotCount }
	var canGoPrevious: Bool { paging.slot(forPage: anchorPage) > 0 }

	/// Reflows after the double-page setting changed. The anchor stays, so the reader keeps
	/// their page however often the layout is switched.
	func layoutChanged() {
		rebuildPaging()
	}

	// MARK: Progress

	/// Read once the last page has been on screen. Never un-marked automatically.
	private func markReadIfAtEnd() {
		guard pageCount > 0, !book.isRead, visiblePages.contains(pageCount - 1),
			  gate.countsAsProgress(peek: initialPage != nil) else { return }
		book.isRead = true
	}

	/// Writes the resume page: a moment after the reader stops turning, when the reader leaves
	/// the comic, and when the app quits. Not on every turn, because each save republishes the
	/// library's query, but often enough that a crash costs a page or two, not a whole session.
	func persistProgress() {
		saveWork?.cancel()
		saveWork = nil
		guard phase == .ready, !book.isDeleted, book.modelContext != nil,
			  gate.countsAsProgress(peek: initialPage != nil) else { return }
		if book.lastReadPage != anchorPage { book.lastReadPage = anchorPage }
		try? model.context.save()
	}

	private var saveWork: DispatchWorkItem?

	private func scheduleProgressSave() {
		saveWork?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.persistProgress() }
		saveWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
	}

	func close() {
		guard !isClosed else { return }
		persistProgress()
		isClosed = true
		store = nil
		model.unregister(self)
	}

	// MARK: Paper

	/// Re-renders with the new paper setting. Coalesced, so dragging a slider in Settings asks
	/// for one render once it rests rather than one per notch.
	func paperChanged() {
		paperWork?.cancel()
		let work = DispatchWorkItem { [weak self] in
			guard let self, let store = self.store else { return }
			store.setPaper(enabled: self.model.paper.isEnabled, params: self.model.paper.params)
			self.paperGeneration += 1
		}
		paperWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
	}

	private var paperWork: DispatchWorkItem?

	// MARK: Bookmarks

	var isCurrentPageBookmarked: Bool {
		book.bookmarks.contains { visiblePages.contains($0.pageIndex) }
	}

	func isBookmarked(_ page: Int) -> Bool {
		book.bookmarks.contains { $0.pageIndex == page }
	}

	/// The menu command and keyboard shortcut: the page the reader is at, or, when a bookmark is
	/// already on screen, that one goes.
	func toggleBookmark() {
		if let existing = book.bookmarks.first(where: { visiblePages.contains($0.pageIndex) }) {
			toggleBookmark(page: existing.pageIndex)
		} else {
			toggleBookmark(page: visiblePages.contains(anchorPage) ? anchorPage : currentPage)
		}
	}

	/// Bookmarks one page, or removes its bookmark. Either page of a spread can be marked.
	func toggleBookmark(page: Int) {
		if let existing = book.bookmarks.first(where: { $0.pageIndex == page }) {
			try? Storage.fm.removeItem(at: existing.thumbURL)
			model.context.delete(existing)
			try? model.context.save()
			return
		}
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

/// The 1 or 2 pages each reader position shows. Cover alone, then pairs (1·2, 3·4, …), as a
/// printed comic opens; the pairing is fixed, so a page never changes sides when the layout is
/// toggled. As in the iOS reader, with one Mac addition: a wide page (a double page scanned as
/// one image) stands alone, and the pairs after it start over from the next page.
struct ReaderPaging {
	let pageCount: Int
	private let slots: [[Int]]
	private let slotOfPage: [Int]

	init(pageCount: Int, double: Bool, wide: Set<Int> = []) {
		self.pageCount = max(pageCount, 0)
		var slots: [[Int]] = []
		var page = 0
		while page < self.pageCount {
			let pairs = double && page > 0 && page + 1 < self.pageCount
				&& !wide.contains(page) && !wide.contains(page + 1)
			if pairs {
				slots.append([page, page + 1])
				page += 2
			} else {
				slots.append([page])
				page += 1
			}
		}
		var slotOfPage = Array(repeating: 0, count: self.pageCount)
		for (index, pages) in slots.enumerated() {
			for page in pages { slotOfPage[page] = index }
		}
		self.slots = slots
		self.slotOfPage = slotOfPage
	}

	var slotCount: Int { slots.count }

	/// The 1 or 2 page indices shown in a slot.
	func pages(inSlot slot: Int) -> [Int] {
		slots.indices.contains(slot) ? slots[slot] : []
	}

	/// The slot that contains a given page.
	func slot(forPage page: Int) -> Int {
		slotOfPage.indices.contains(page) ? slotOfPage[page] : 0
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
