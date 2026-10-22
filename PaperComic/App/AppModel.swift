//
//  AppModel.swift
//  Paper Comic Reader
//
//  What every window shares: the library store, downloads, the paper and reader settings, and
//  the long-running library jobs (folder scan, import, backup). Windows only hold where they
//  are (library or reader, see WindowState); everything that outlives a window lives here.
//

import AppKit
import SwiftData
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {

	let container: ModelContainer
	/// True when the store could not be opened and this launch runs on an in-memory library.
	let isTemporaryStore: Bool
	let downloads = DownloadManager()
	let paper: PaperSettings
	let reader = ReaderSettings()

	var context: ModelContext { container.mainContext }

	/// Progress of the running folder scan or import, nil when idle.
	struct Job: Equatable {
		var title: String
		var done: Int
		var total: Int
	}
	private(set) var job: Job?
	/// What the last scan or import could not read, shown once as a count.
	private(set) var skippedCount = 0

	/// One message for the user. Windows show it as an alert.
	struct Message: Identifiable {
		let id = UUID()
		let title: String
		let text: String
	}
	var message: Message?

	/// Comics asked to open from outside (Finder, Dock, Open…) before any window was there to
	/// take them. The first window that appears picks them up.
	var pendingOpen: [UUID] = []
	/// Opens a window (a tab, with tabbing preferred) showing a comic, or the library for nil.
	/// Set by the first window, because only a view can reach SwiftUI's openWindow.
	var openWindow: ((UUID?) -> Void)?
	/// The readers open in any window, so their progress can be written when the app quits.
	private var sessions: [UUID: ReaderSession] = [:]

	func register(_ session: ReaderSession) { sessions[session.id] = session }
	func unregister(_ session: ReaderSession) {
		if sessions[session.id] === session { sessions[session.id] = nil }
	}

	/// Writes everything that is otherwise only written when a reader closes.
	func prepareToQuit() {
		sessions.values.forEach { $0.persistProgress() }
		try? context.save()
		saveSnapshot()
	}

	init() {
		// Before PaperSettings exists: under @Observable its init writes the defaults it read,
		// which would leave nothing for Simple Comic's values to fill in.
		LegacyMigration.migratePaperSettings(defaults: .standard)
		paper = PaperSettings()
		let opened = LibraryStore.open()
		container = opened.container
		isTemporaryStore = opened.isTemporary
		Storage.clearPartialDownloads()
		BackupDevice.refreshName()
		if !isTemporaryStore {
			LegacyMigration.runIfNeeded(into: container.mainContext)
		}
		Task { await self.tidyUp() }
	}

	/// Launch housekeeping, after the first window is up.
	private func tidyUp() async {
		await Importer.reconcileDownloads(in: context)
		let books = (try? context.fetch(FetchDescriptor<ComicBook>())) ?? []
		await Importer.backfillMetadata(for: books.filter { !$0.metadataScanned && $0.hasLocalArchive }, into: context)
		saveSnapshot()
	}

	// MARK: Library folder

	/// Asks for the library folder and scans it. Choosing a different folder lets every comic
	/// that was removed from the old one back in, because its paths now mean other files.
	func chooseLibraryFolder() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.allowsMultipleSelection = false
		panel.prompt = String(localized: "Use as Library Folder")
		panel.message = String(localized: "Choose the folder that holds your comics. Covers and details are read in; each comic is downloaded when you open it.")
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do {
			let previous = LibrarySource.chosenPath
			try LibrarySource.setFolder(url)
			if let previous, previous != url.standardizedFileURL.path { LibrarySource.includeAll() }
			Task { await scanLibraryFolder() }
		} catch {
			show(String(localized: "The folder can’t be used"), error.localizedDescription)
		}
	}

	func scanLibraryFolder() async {
		guard job == nil, LibrarySource.isConfigured else { return }
		let books = (try? context.fetch(FetchDescriptor<ComicBook>())) ?? []
		let existing = Set(books.compactMap(\.sourceRelativePath))
		let title = LibrarySource.displayName ?? String(localized: "Library Folder")
		job = Job(title: title, done: 0, total: 0)
		skippedCount = 0
		do {
			let result = try await Importer.scanFolder(existing: existing,
														excluded: LibrarySource.excludedPaths,
														into: context) { done, total in
				self.job = Job(title: title, done: done, total: total)
			}
			skippedCount = result.skipped
		} catch {
			show(String(localized: "The library folder can’t be reached"),
				 String(localized: "The volume may be offline, or the folder may have moved. Choose it again in Settings."))
		}
		job = nil
		saveSnapshot()
	}

	// MARK: Importing files

	/// Lets the user pick comic files to copy into the library.
	func importComics() {
		let panel = NSOpenPanel()
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false
		panel.allowedContentTypes = ComicFileTypes.all
		panel.prompt = String(localized: "Import")
		guard panel.runModal() == .OK else { return }
		let urls = panel.urls
		Task { _ = await importFiles(urls) }
	}

	/// Imports files, recognising comics the library already has. Returns the library entry
	/// for every file, new or existing, in the order given.
	func importFiles(_ urls: [URL]) async -> [ComicBook] {
		guard !urls.isEmpty else { return [] }
		let books = (try? context.fetch(FetchDescriptor<ComicBook>())) ?? []
		let existing = books.map(Importer.ExistingArchive.init(book:))
		var result: [ComicBook] = []
		var skipped = 0
		let showsProgress = urls.count > 1
		if showsProgress { job = Job(title: String(localized: "Importing"), done: 0, total: urls.count) }
		for (index, url) in urls.enumerated() {
			if let id = await Task.detached(priority: .userInitiated, operation: {
				Importer.duplicate(of: url, among: existing)
			}).value, let book = books.first(where: { $0.id == id }) {
				result.append(book)
			} else if let returning = await Task.detached(operation: { Importer.removedFolderPath(of: url) }).value,
					  let prepared = try? await Task.detached(priority: .userInitiated, operation: {
						  try Importer.prepare(from: url)
					  }).value {
				result.append(Importer.commitReturning(prepared, relativePath: returning, into: context))
			} else if let prepared = try? await Task.detached(priority: .userInitiated, operation: {
				try Importer.prepare(from: url)
			}).value {
				if let id = Importer.undownloadedFolderEntry(matching: prepared, among: existing),
				   let book = books.first(where: { $0.id == id }) {
					Importer.adoptAsDownload(prepared, into: book, from: context)
					result.append(book)
				} else {
					result.append(Importer.commit(prepared, into: context))
				}
			} else {
				skipped += 1
			}
			if showsProgress { job?.done = index + 1 }
		}
		job = nil
		if skipped > 0 {
			show(String(localized: "Some files couldn’t be imported"),
				 String(localized: "\(skipped) of \(urls.count) files aren’t readable comics (CBZ)."))
		}
		saveSnapshot()
		return result
	}

	/// Files opened from the Finder, the Dock or the Open menu: brought into the library, then
	/// shown in a window.
	func openExternal(_ urls: [URL]) {
		let comics = urls.filter { ComicFileTypes.isComic($0) }
		guard !comics.isEmpty else { return }
		Task {
			let books = await importFiles(comics)
			guard !books.isEmpty else { return }
			if let openWindow {
				books.forEach { openWindow($0.id) }
			} else {
				pendingOpen.append(contentsOf: books.map(\.id))
			}
		}
	}

	// MARK: Removing

	func delete(_ book: ComicBook) {
		downloads.cancel(book.id)
		Importer.delete(book, from: context)
	}

	func evict(_ book: ComicBook) {
		downloads.cancel(book.id)
		Importer.evictDownload(book, from: context)
	}

	func toggleFavorite(_ book: ComicBook) {
		book.isFavorite.toggle()
		try? context.save()
	}

	func toggleRead(_ book: ComicBook) {
		book.isRead.toggle()
		if !book.isRead { book.lastReadPage = 0 }
		try? context.save()
	}

	func revealInFinder(_ book: ComicBook) {
		guard let relativePath = book.sourceRelativePath else {
			NSWorkspace.shared.activateFileViewerSelecting([book.archiveURL])
			return
		}
		Task.detached {
			guard let url = try? LibrarySource.withFolderAccess({ $0.appendingPathComponent(relativePath) }) else { return }
			await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
		}
	}

	// MARK: Backup

	/// Writes a backup the iOS app can import too. The document is captured here, on the main
	/// actor; packing it runs off it, because it copies every comic the library owns.
	func exportLibrary() {
		guard job == nil else { return }
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.zip]
		let day = Date.now.formatted(.iso8601.year().month().day())
		panel.nameFieldStringValue = "Paper Comic Library \(day).zip"
		panel.prompt = String(localized: "Export")
		guard panel.runModal() == .OK, let destination = panel.url else { return }
		let books = (try? context.fetch(FetchDescriptor<ComicBook>())) ?? []
		let backup = LibraryBackupStore.capture(from: books)
		job = Job(title: String(localized: "Exporting Library"), done: 0, total: 0)
		Task {
			let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
				Result {
					let packed = try LibraryBackupArchive.write(backup) { done, total in
						Task { @MainActor in self.job = Job(title: String(localized: "Exporting Library"), done: done, total: total) }
					}
					if FileManager.default.fileExists(atPath: destination.path) {
						try FileManager.default.removeItem(at: destination)
					}
					try FileManager.default.moveItem(at: packed, to: destination)
				}
			}.value
			job = nil
			if case .failure(let error) = result {
				show(String(localized: "The library couldn’t be exported"), Self.describe(error))
			}
		}
	}

	/// Merges a backup from this app or the iOS one into the library. Unpacked and copied off the
	/// main actor, applied on it.
	func importLibrary() {
		guard job == nil else { return }
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.zip]
		panel.prompt = String(localized: "Import")
		panel.message = String(localized: "Choose a library backup from Paper Comic on the Mac, iPhone or iPad. Reading progress, favorites and bookmarks are merged into this library.")
		guard panel.runModal() == .OK, let url = panel.url else { return }
		job = Job(title: String(localized: "Importing Library"), done: 0, total: 0)
		Task {
			let opened = await Task.detached(priority: .userInitiated) {
				Result { try LibraryBackupArchive.read(at: url) }
			}.value
			switch opened {
			case .failure(let error):
				job = nil
				show(String(localized: "The backup couldn’t be imported"), Self.describe(error))
			case .success(let unpacked):
				await Task.detached(priority: .userInitiated) {
					LibraryBackupStore.installFiles(from: unpacked)
				}.value
				let report = LibraryBackupStore.restore(unpacked, into: context)
				await Task.detached(priority: .utility) { unpacked.discard() }.value
				job = nil
				show(String(localized: "Library imported"), Self.describe(report, from: unpacked.backup))
				saveSnapshot()
			}
		}
	}

	/// The rolling safety copy of the library (see LibrarySnapshot). Written when the app goes
	/// to the background or quits.
	func saveSnapshot() {
		guard !isTemporaryStore else { return }
		LibrarySnapshot.save((try? context.fetch(FetchDescriptor<ComicBook>())) ?? [])
	}

	private static func describe(_ error: Error) -> String {
		(error as? LocalizedError)?.errorDescription
			?? LibraryBackupArchive.BackupError.unreadable.localizedDescription
	}

	/// Plain sentences rather than a row of counts, as in the iOS app.
	private static func describe(_ report: LibraryBackupStore.Report, from backup: LibraryBackup) -> String {
		let date = backup.createdAt.formatted(date: .abbreviated, time: .shortened)
		var sentences = [String(localized: "Backup from \(backup.deviceName), \(date).")]
		guard !report.isEmpty else {
			sentences.append(String(localized: "Everything in it was already here."))
			return sentences.joined(separator: " ")
		}
		var parts: [String] = []
		if report.comicsAdded > 0 { parts.append(String(localized: "added \(report.comicsAdded) comics")) }
		if report.comicsUpdated > 0 { parts.append(String(localized: "updated \(report.comicsUpdated) comics")) }
		if report.bookmarksAdded > 0 { parts.append(String(localized: "restored \(report.bookmarksAdded) bookmarks")) }
		sentences.append(String(localized: "Imported: \(parts.formatted(.list(type: .and)))."))
		if report.comicsWithoutArchive > 0 {
			let n = report.comicsWithoutArchive
			sentences.append(String(localized: "\(n) comics came back without their files and can’t be opened until you import them again."))
		}
		return sentences.joined(separator: " ")
	}

	// MARK: Messages

	func show(_ title: String, _ text: String) {
		message = Message(title: title, text: text)
	}
}

/// The comic files the app opens. CBZ only, like the iOS app: a plain ZIP of images.
enum ComicFileTypes {
	static let all: [UTType] = {
		var types: [UTType] = [.zip]
		if let cbz = UTType(filenameExtension: "cbz") { types.insert(cbz, at: 0) }
		return types
	}()

	static func isComic(_ url: URL) -> Bool {
		["cbz", "zip"].contains(url.pathExtension.lowercased())
	}
}
