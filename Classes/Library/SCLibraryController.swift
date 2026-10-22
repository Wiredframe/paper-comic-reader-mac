//
//  SCLibraryController.swift
//  Simple Comic
//
//  The library's actions, and the state the library window observes: adding and scanning
//  folders, fetching a comic's bytes when it is opened, handing it to the existing session
//  machinery, and writing the reading position back when the window closes.
//
//  Opening always goes through a copy inside the app container. That is the point of the
//  design: TSSTManagedGroup then bookmarks an ordinary file we own, so nothing in the
//  reader has to know about the sandbox, the library folder, or a volume that might go
//  away mid-session.
//

import AppKit

final class SCLibraryController: NSObject, ObservableObject {

	static let shared = SCLibraryController()

	let store = SCLibraryStore.shared

	/// Progress of a running folder scan, nil when idle.
	struct ScanProgress {
		var folderName: String
		var done: Int
		var total: Int
	}

	/// Progress of an on-demand fetch, nil when nothing is being fetched.
	struct DownloadProgress {
		var entryID: UUID
		var title: String
		var fraction: Double
	}

	@Published private(set) var scan: ScanProgress?
	private var scanningFolderID: UUID?
	private var scannedFolderRemoved = false
	@Published private(set) var download: DownloadProgress?
	/// Files a scan couldn't read — shown once, as a count, rather than one alert per file.
	@Published private(set) var skipped: [String] = []

	/// Read from the scan's worker threads and written from the main thread, so it carries its
	/// own lock rather than relying on a plain Bool being seen in time.
	private let cancelFlag = SCAtomicFlag()
	/// Set from the cancel button in the cover cell, read by the copying thread between chunks.
	private let downloadCancelFlag = SCAtomicFlag()
	/// Which library entry a live session belongs to, so the reading position can be written
	/// back when its window closes. Keyed by the session object, which is what `-endSession:`
	/// hands over.
	private var sessionEntries: [ObjectIdentifier: UUID] = [:]
	/// Folders asked to scan while another scan was running.
	private var pendingFolderIDs: [UUID] = []
	/// Callers waiting on the fetch that is already loading their comic.
	private var downloadWaiters: [(Result<URL, Error>) -> Void] = []

	private override init() {
		super.init()
	}

	// MARK: Folders

	/// Asks for a folder and scans it. The bookmark is made while the panel's grant is held.
	func addFolder(relativeTo window: NSWindow?) {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.allowsMultipleSelection = false
		panel.prompt = NSLocalizedString("Add to Library", comment: "open panel button, choosing a library folder")
		panel.message = NSLocalizedString("Choose a folder of comics. Covers and details are read into the library; the files stay where they are.",
										  comment: "open panel message, choosing a library folder")

		let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
			guard response == .OK, let url = panel.url, let self = self else { return }
			do {
				let bookmark = try SCLibrarySource.bookmark(for: url)
				let folder = SCLibraryFolder(bookmark: bookmark,
											 name: url.lastPathComponent,
											 path: url.path)
				// Scanning the id the store hands back, which is the existing one when this
				// folder was already tracked.
				self.rescan(folderID: self.store.addFolder(folder))
			} catch {
				self.present(error)
			}
		}
		if let window = window {
			panel.beginSheetModal(for: window, completionHandler: handler)
		} else {
			handler(panel.runModal())
		}
	}

	func rescanAll() {
		guard let first = store.folders.first else { return }
		rescan(folderID: first.id, remaining: Array(store.folders.dropFirst()).map { $0.id })
	}

	/// Scans one folder, then any folders queued behind it. One at a time on purpose: two
	/// scans over the same network volume are slower than one, not faster.
	func rescan(folderID: UUID, remaining: [UUID] = []) {
		guard let folder = store.folder(id: folderID) else {
			// Removed while it waited: carry on with the rest of the run.
			if let next = remaining.first { rescan(folderID: next, remaining: Array(remaining.dropFirst())) }
			return
		}
		guard scan == nil else {
			// A folder added while another scans waits its turn instead of being dropped.
			for id in [folderID] + remaining
			where id != scanningFolderID && !pendingFolderIDs.contains(id) {
				pendingFolderIDs.append(id)
			}
			return
		}

		cancelFlag.value = false
		skipped = []
		scanningFolderID = folderID
		scan = ScanProgress(folderName: folder.name, done: 0, total: 0)

		var seenPaths = Set<String>()
		let known = knownFiles(inFolder: folderID)

		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			guard let self = self else { return }
			var failure: Error?
			do {
				try SCLibraryImporter.scan(
					folder: folder,
					known: known,
					isCancelled: { [weak self] in self?.cancelFlag.value ?? true },
					progress: { [weak self] done, total in
						self?.scan = ScanProgress(folderName: folder.name, done: done, total: total)
					},
					outcome: { [weak self] outcome in
						guard let self = self else { return }
						switch outcome {
						case .added(let prepared):
							if let path = prepared.sourceRelativePath { seenPaths.insert(path) }
							// The folder may have been removed while this file was being read.
							guard self.store.folder(id: folderID) != nil else { return }
							SCLibraryImporter.commit(prepared, into: self.store)
						case .refreshed(let prepared, let fileChanged):
							if let path = prepared.sourceRelativePath { seenPaths.insert(path) }
							SCLibraryImporter.merge(prepared, into: self.store)
							// Re-read only for a missing cover: the download is still good.
							if fileChanged { self.dropStaleCopy(of: prepared.id) }
						case .unchanged(let id):
							if let path = self.store.entry(id: id)?.sourceRelativePath {
								seenPaths.insert(path)
							}
						case .failed(let path, _):
							// The file is there, it just couldn't be read this time (half written,
							// a network hiccup). Counting it as seen keeps its entry, cover and
							// reading position; only files the walk no longer finds are pruned.
							seenPaths.insert(path)
							self.skipped.append(path)
						}
					})
			} catch {
				failure = error
			}

			DispatchQueue.main.async {
				self.scan = nil
				self.scanningFolderID = nil
				if let failure = failure {
					self.present(failure)
				} else if !self.cancelFlag.value {
					// Only a scan that ran to completion may conclude that a comic is gone.
					self.pruneMissing(folderID: folderID, seen: seenPaths)
					self.store.updateFolder(id: folderID) { $0.dateScanned = Date() }
				}
				// A stop ends the whole run, not just the folder it happened to land on.
				// Removing the folder being scanned stops only that scan.
				let stopped = self.cancelFlag.value && !self.scannedFolderRemoved
				self.scannedFolderRemoved = false
				var queued: [UUID] = []
				if !stopped {
					for id in remaining + self.pendingFolderIDs where id != folderID && !queued.contains(id) {
						queued.append(id)
					}
				}
				self.pendingFolderIDs = []
				if let next = queued.first {
					self.rescan(folderID: next, remaining: Array(queued.dropFirst()))
				}
			}
		}
	}

	func cancelRunningScan() {
		cancelFlag.value = true
	}

	func removeFolder(id: UUID) {
		pendingFolderIDs.removeAll { $0 == id }
		if scan != nil, scanningFolderID == id {
			scannedFolderRemoved = true
			cancelRunningScan()
		}
		store.removeFolder(id: id)
	}

	/// The file behind a refreshed entry changed, so a copy fetched from the old one is stale:
	/// drop it, and the next open fetches the new file. Kept while the comic is open.
	private func dropStaleCopy(of entryID: UUID) {
		guard let entry = store.entry(id: entryID), entry.isFolderBacked,
			  download?.entryID != entryID, openWindow(for: entryID) == nil else { return }
		SCLibraryStorage.removeLocalArchive(of: entry)
		store.update(id: entryID) { $0.hasLocalArchive = false }
	}

	/// Entries whose file is no longer in the folder. Their cover and reading state go with
	/// them: nothing about them can be opened again.
	private func pruneMissing(folderID: UUID, seen: Set<String>) {
		let gone = store.entries.filter {
			$0.sourceFolderID == folderID && !seen.contains($0.sourceRelativePath ?? "")
		}
		guard !gone.isEmpty else { return }
		store.remove(ids: Set(gone.map { $0.id }))
	}

	private func knownFiles(inFolder folderID: UUID) -> [String: SCLibraryImporter.KnownFile] {
		var known: [String: SCLibraryImporter.KnownFile] = [:]
		for entry in store.entries where entry.sourceFolderID == folderID {
			guard let path = entry.sourceRelativePath else { continue }
			let hasCover = entry.coverURL.map { SCLibraryStorage.fm.fileExists(atPath: $0.path) } ?? false
			known[path] = SCLibraryImporter.KnownFile(id: entry.id,
													  size: entry.sourceSize,
													  modified: entry.sourceModified,
													  hasCover: hasCover)
		}
		return known
	}

	// MARK: Opening

	/// Opens a comic in a normal session window, fetching its bytes first if the library
	/// only holds its cover.
	func open(_ entry: SCLibraryEntry) {
		// Already open: raise that window instead of stacking a second session on the same
		// file, which is what every document-based app does and what the reading position
		// write-back assumes.
		if let existing = openWindow(for: entry.id) {
			existing.showWindow(self)
			existing.window?.makeKeyAndOrderFront(self)
			return
		}

		let url = entry.archiveURL
		if SCLibraryStorage.fm.fileExists(atPath: url.path) {
			if !entry.hasLocalArchive {
				// The file system is the truth; the flag exists only so views update.
				store.update(id: entry.id) { $0.hasLocalArchive = true }
			}
			present(entry: entry, url: url)
			return
		}
		fetch(entry) { [weak self] result in
			switch result {
			case .success(let url):
				self?.present(entry: entry, url: url)
			case .failure(let error):
				// Cancelling is a decision, not a failure: no alert for it.
				if case SCLibrarySource.SourceError.cancelled = error { return }
				self?.present(error)
			}
		}
	}

	/// Copies the archive out of the library folder into the container. `.part` first, moved
	/// into place on success, so a cancelled or failed fetch never leaves a half archive that
	/// would read as present.
	func fetch(_ entry: SCLibraryEntry, completion: @escaping (Result<URL, Error>) -> Void) {
		// One at a time; the caller is told rather than left waiting on a callback that would
		// never arrive.
		if download?.entryID == entry.id {
			// Already on its way: wait for that fetch rather than reporting a different comic.
			downloadWaiters.append(completion)
			return
		}
		guard download == nil else {
			completion(.failure(SCLibrarySource.SourceError.busy))
			return
		}
		guard let folderID = entry.sourceFolderID,
			  let folder = store.folder(id: folderID),
			  let relativePath = entry.sourceRelativePath else {
			completion(.failure(SCLibrarySource.SourceError.unresolved(
				entry.sourceFolderID.flatMap { store.folder(id: $0)?.name } ?? entry.title)))
			return
		}

		let destination = entry.archiveURL
		downloadCancelFlag.value = false
		download = DownloadProgress(entryID: entry.id, title: entry.displayTitle, fraction: 0)

		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			let result: Result<URL, Error>
			do {
				try SCLibrarySource.withAccess(to: folder, relativePath: relativePath) { source in
					try SCLibraryController.copy(from: source, to: destination,
												 isCancelled: { self?.downloadCancelFlag.value ?? true },
												 onProgress: { fraction in
						DispatchQueue.main.async {
							self?.download?.fraction = fraction
						}
					})
				}
				result = .success(destination)
			} catch {
				result = .failure(error)
			}

			DispatchQueue.main.async {
				self?.download = nil
				switch result {
				case .success:
					self?.store.update(id: entry.id) { $0.hasLocalArchive = true }
				case .failure:
					// Leave nothing behind, not even the empty folder the copy created.
					SCLibraryStorage.removeLocalArchive(of: entry)
				}
				completion(result)
				let waiters = self?.downloadWaiters ?? []
				self?.downloadWaiters = []
				waiters.forEach { $0(result) }
			}
		}
	}

	/// Stops a running fetch. The partial file is removed by the copy itself, so the entry is
	/// left exactly as it was before the download started.
	func cancelDownload() {
		downloadCancelFlag.value = true
	}

	/// Throws the fetched copy away. Cover, metadata and reading position stay — the entry
	/// simply goes back to being remote.
	func evict(_ entry: SCLibraryEntry) {
		guard entry.isFolderBacked else { return }
		SCLibraryStorage.removeLocalArchive(of: entry)
		store.update(id: entry.id) { $0.hasLocalArchive = false }
	}

	func evictAll() {
		for entry in store.entries where entry.isFolderBacked && entry.hasLocalArchive {
			evict(entry)
		}
	}

	/// Reopens whatever was read last. Only when its copy is still in the container: a launch
	/// should not start pulling a comic off a file server, and the fetch would be the first
	/// thing the user sees. Returns whether a window was opened.
	@discardableResult
	func openLastReadComic() -> Bool {
		let candidates = store.entries.filter { $0.dateOpened != nil }
		guard let entry = candidates.max(by: { ($0.dateOpened ?? .distantPast) < ($1.dateOpened ?? .distantPast) }),
			  SCLibraryStorage.fm.fileExists(atPath: entry.archiveURL.path) else { return false }
		open(entry)
		return true
	}

	func revealInFinder(_ entry: SCLibraryEntry) {
		guard let folderID = entry.sourceFolderID,
			  let folder = store.folder(id: folderID),
			  let relativePath = entry.sourceRelativePath else { return }
		DispatchQueue.global(qos: .userInitiated).async {
			// Resolving needs the scope; revealing the file does not, and the panel outlives it.
			guard let url = try? SCLibrarySource.withAccess(to: folder, { $0.appendingPathComponent(relativePath) }) else { return }
			DispatchQueue.main.async {
				NSWorkspace.shared.activateFileViewerSelecting([url])
			}
		}
	}

	// MARK: Session bridge

	/// Hands the file to the app's existing open path and remembers which entry the resulting
	/// session belongs to.
	private func present(entry: SCLibraryEntry, url: URL) {
		guard let delegate = NSApp.delegate as? SimpleComicAppDelegate else { return }
		// Two opens can wait on the same fetch; the second one only raises the window.
		if let existing = openWindow(for: entry.id) {
			existing.window?.makeKeyAndOrderFront(self)
			return
		}
		let session = delegate.newSession(withFileURLs: [url])
		guard let images = session.images, !images.isEmpty else {
			// The copy is unreadable — most likely truncated. Drop it so the next open refetches.
			SCLibraryStorage.removeLocalArchive(of: entry)
			store.update(id: entry.id) { $0.hasLocalArchive = false }
			present(SCArchiveError.unreadable)
			return
		}
		sessionEntries[ObjectIdentifier(session)] = entry.id

		// Resume where the reader left off. A session made by `newSessionWithFileURLs:` starts
		// at 0, and `-windowDidLoad` reads `session.selection` into the page controller before
		// it binds the two together — so the page has to be on the session BEFORE the window
		// exists. Clamped against this copy's actual page count, which may differ from the one
		// the library recorded if the file was replaced.
		let resumePage = min(max(0, entry.lastReadPage), max(0, images.count - 1))
		session.selection = Int16(clamping: resumePage)

		store.update(id: entry.id) { item in
			item.dateOpened = Date()
			item.openCount += 1
			if item.pageCount != images.count { item.pageCount = images.count }
		}
		delegate.window(for: session)
	}

	/// The open session window showing `entryID`, if there is one.
	private func openWindow(for entryID: UUID) -> TSSTSessionWindowController? {
		guard let delegate = NSApp.delegate as? SimpleComicAppDelegate else { return nil }
		return delegate.sessions.first { sessionEntries[ObjectIdentifier($0.session)] == entryID }
	}

	/// Stops a fetch that is loading `entryID`, used when its entry is about to disappear.
	func cancelDownload(ifFetching entryID: UUID) {
		if download?.entryID == entryID { cancelDownload() }
	}

	/// Writes the reading position of a closing session back into its library entry.
	/// Called from `-[SimpleComicAppDelegate endSession:]` before the session is deleted.
	func sessionWillEnd(_ session: TSSTManagedSession) {
		let key = ObjectIdentifier(session)
		guard let entryID = sessionEntries.removeValue(forKey: key) else { return }
		recordProgress(of: session, into: entryID)
	}

	/// Writes back every still-open session. Called on quit, when windows are left open.
	func recordOpenSessions() {
		guard let delegate = NSApp.delegate as? SimpleComicAppDelegate else { return }
		for controller in delegate.sessions {
			let session = controller.session
			if let entryID = sessionEntries[ObjectIdentifier(session)] {
				recordProgress(of: session, into: entryID)
			}
		}
	}

	private func recordProgress(of session: TSSTManagedSession, into entryID: UUID) {
		let page = Int(session.selection)
		let pages = session.images?.count ?? 0
		store.update(id: entryID) { entry in
			if pages > 0 { entry.pageCount = pages }
			entry.lastReadPage = max(0, min(page, max(0, entry.pageCount - 1)))
			entry.isRead = entry.pageCount > 0 && entry.lastReadPage >= entry.pageCount - 1
		}
	}

	// MARK: Helpers

	private func present(_ error: Error) {
		let message = (error as? LocalizedError)?.errorDescription
			?? (error as NSError).localizedDescription
		NSApp.presentError(NSError(domain: "de.wiredframe.simplecomic.library",
								   code: 1,
								   userInfo: [NSLocalizedDescriptionKey: message]))
	}

	/// Chunked copy so a fetch over a network volume can report progress and doesn't read a
	/// whole comic into memory.
	private static func copy(from source: URL, to destination: URL,
							 isCancelled: @escaping () -> Bool,
							 onProgress: @escaping (Double) -> Void) throws {
		let fm = SCLibraryStorage.fm
		let partial = destination.appendingPathExtension("part")
		try? fm.createDirectory(at: destination.deletingLastPathComponent(),
								withIntermediateDirectories: true)
		try? fm.removeItem(at: partial)
		try? fm.removeItem(at: destination)

		let total = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
		let input = try FileHandle(forReadingFrom: source)
		defer { try? input.close() }

		guard fm.createFile(atPath: partial.path, contents: nil) else {
			throw CocoaError(.fileWriteUnknown)
		}
		let output = try FileHandle(forWritingTo: partial)
		defer { try? output.close() }

		let chunkSize = 1024 * 1024
		var written: Int64 = 0
		while true {
			if isCancelled() {
				try? output.close()
				try? fm.removeItem(at: partial)
				throw SCLibrarySource.SourceError.cancelled
			}
			// The throwing variants: the old readData/write raise an Objective-C exception on an
			// I/O error (a share that drops off, a full disk), which Swift cannot catch.
			guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
			try output.write(contentsOf: chunk)
			written += Int64(chunk.count)
			if total > 0 { onProgress(Double(written) / Double(total)) }
		}
		try output.close()
		try fm.moveItem(at: partial, to: destination)
		onProgress(1)
	}
}

/// A Bool that is safe to set on one thread and read on another.
final class SCAtomicFlag {
	private let lock = NSLock()
	private var storage = false
	var value: Bool {
		get { lock.lock(); defer { lock.unlock() }; return storage }
		set { lock.lock(); storage = newValue; lock.unlock() }
	}
}

/// The Objective-C face of the library, for the two places the app delegate has to call in.
@objc(SCLibraryBridge)
final class SCLibraryBridge: NSObject {

	/// Called from `-[SimpleComicAppDelegate endSession:]`, before the session is deleted.
	@objc(sessionWillEnd:)
	static func sessionWillEnd(_ session: TSSTManagedSession) {
		SCLibraryController.shared.sessionWillEnd(session)
	}

	/// Called at the end of `-applicationDidFinishLaunching:` when no window was restored and
	/// no file was opened at launch.
	@objc(openLastReadComic)
	static func openLastReadComic() {
		SCLibraryController.shared.openLastReadComic()
	}

	/// Called from `-applicationWillTerminate:`: record whatever is still open, then make
	/// sure the index is on disk.
	@objc(applicationWillTerminate)
	static func applicationWillTerminate() {
		SCLibraryController.shared.recordOpenSessions()
		SCLibraryStore.shared.flush()
	}
}





