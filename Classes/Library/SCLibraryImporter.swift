//
//  SCLibraryImporter.swift
//  Simple Comic
//
//  Turns files into library entries, and library entries into readable files.
//
//  The split that matters: `prepare` does the slow part — opening the archive, extracting
//  a cover, parsing metadata — off the main thread and returns a plain value; `commit`
//  takes that value and inserts it into the store on the main thread. Nothing that touches
//  the store ever waits on a disk.
//
//  A scanned comic is never copied. Only its cover and metadata come into the library; the
//  archive itself is fetched on demand when the comic is opened (`ensureLocal`) and can be
//  thrown away again (`evict`) without losing the entry.
//

import AppKit

enum SCLibraryImporter {

	/// Everything a new or refreshed entry needs, with nothing main-thread-bound in it, so it
	/// can be produced on a background queue and handed over as a value.
	struct Prepared {
		var id: UUID
		var title: String
		var fileName: String
		var coverName: String?
		var coverAspect: Double?
		var pageCount: Int
		var info: SCComicInfoData?
		var sourceFolderID: UUID?
		var sourceRelativePath: String?
		var sourceSize: Int64
		var sourceModified: Date?
	}

	/// What a scan decided about one file.
	enum ScanOutcome {
		/// A comic not in the library yet.
		case added(Prepared)
		/// A known comic whose file changed on disk (re-tagged, replaced) — cover and
		/// metadata are refreshed, reading state is kept.
		case refreshed(Prepared)
		/// Known and unchanged. Nothing was opened.
		case unchanged(id: UUID)
		/// Couldn't be read: encrypted, corrupt, or not actually a comic.
		case failed(relativePath: String, error: Error)
	}

	// MARK: Preparing

	/// Opens `url` and produces everything the library stores about it, writing the cover to
	/// disk on the way. Slow: call off the main thread, inside the folder's security scope.
	static func prepare(url: URL,
						folderID: UUID?,
						relativePath: String?,
						size: Int64,
						modified: Date?,
						reusing existingID: UUID? = nil) throws -> Prepared {
		let id = existingID ?? UUID()
		let probe = try SCArchiveProbe.probe(url: url)

		// The copy keeps the comic's own file name inside a folder named after the entry:
		// unique on disk, and the session window ends up titled with the comic rather than
		// with a UUID.
		var prepared = Prepared(id: id,
								title: url.deletingPathExtension().lastPathComponent,
								fileName: "\(id.uuidString)/\(url.lastPathComponent)",
								coverName: nil,
								coverAspect: nil,
								pageCount: probe.pageCount,
								info: probe.info,
								sourceFolderID: folderID,
								sourceRelativePath: relativePath,
								sourceSize: size,
								sourceModified: modified)

		if let data = probe.coverData,
		   let image = SCImageDownsampler.downsample(data, maxPixel: SCImageDownsampler.coverPixel) {
			// A refreshed cover gets a new name, so views keyed on the URL and the decoded
			// cover cache pick it up instead of showing the old picture until the next launch.
			let name = existingID == nil
				? "\(id.uuidString).jpg"
				: "\(id.uuidString)-\(UUID().uuidString.prefix(8)).jpg"
			if SCImageDownsampler.writeJPEG(image, to: SCLibraryStorage.coverURL(name)) {
				prepared.coverName = name
				if image.height > 0 {
					prepared.coverAspect = Double(image.width) / Double(image.height)
				}
			}
		}
		return prepared
	}

	// MARK: Committing (main thread)

	@discardableResult
	static func commit(_ prepared: Prepared, into store: SCLibraryStore) -> SCLibraryEntry {
		var entry = SCLibraryEntry(id: prepared.id, title: prepared.title, fileName: prepared.fileName)
		entry.coverName = prepared.coverName
		entry.coverAspect = prepared.coverAspect
		entry.pageCount = prepared.pageCount
		entry.sourceFolderID = prepared.sourceFolderID
		entry.sourceRelativePath = prepared.sourceRelativePath
		entry.sourceSize = prepared.sourceSize
		entry.sourceModified = prepared.sourceModified
		entry.hasLocalArchive = SCLibraryStorage.fm.fileExists(atPath: entry.archiveURL.path)
		entry.apply(prepared.info)
		store.insert(entry)
		return entry
	}

	/// Folds a re-read of a known comic back in: cover, page count and metadata are replaced,
	/// everything the reader owns (position, favourite, open count) is left alone.
	static func merge(_ prepared: Prepared, into store: SCLibraryStore) {
		if let newCover = prepared.coverName,
		   let old = store.entry(id: prepared.id)?.coverName, old != newCover {
			try? SCLibraryStorage.fm.removeItem(at: SCLibraryStorage.coverURL(old))
		}
		store.update(id: prepared.id) { entry in
			entry.title = prepared.title
			entry.coverName = prepared.coverName ?? entry.coverName
			entry.coverAspect = prepared.coverAspect ?? entry.coverAspect
			entry.pageCount = prepared.pageCount
			entry.sourceSize = prepared.sourceSize
			entry.sourceModified = prepared.sourceModified
			entry.apply(prepared.info)
			// The file behind it changed, so a copy made from the old one is stale.
			if entry.isFolderBacked, entry.lastReadPage >= prepared.pageCount {
				entry.lastReadPage = max(0, prepared.pageCount - 1)
			}
		}
	}

	// MARK: Scanning

	/// What the scanner needs to know about an entry it already has, without holding a
	/// reference to the store from a background queue.
	struct KnownFile {
		let id: UUID
		let size: Int64?
		let modified: Date?
		let hasCover: Bool
	}

	/// Walks `folder` and reports what it finds. Runs synchronously on the calling queue —
	/// call it from a background queue — and holds the folder's security scope throughout.
	///
	/// `progress` and `outcome` are invoked on the main queue so callers can drive UI
	/// directly. Files are prepared a few at a time: enough to keep several cores busy,
	/// few enough not to swamp a network volume.
	@discardableResult
	static func scan(folder: SCLibraryFolder,
					 known: [String: KnownFile],
					 maxConcurrent: Int = 4,
					 isCancelled: @escaping () -> Bool = { false },
					 progress: @escaping (_ done: Int, _ total: Int) -> Void,
					 outcome: @escaping (ScanOutcome) -> Void) throws -> Int {

		try SCLibrarySource.withAccess(to: folder) { root in
			let files = SCLibrarySource.comicFiles(in: root)
			let total = files.count
			DispatchQueue.main.async { progress(0, total) }

			let counter = Counter()
			let group = DispatchGroup()
			let queue = DispatchQueue(label: "de.wiredframe.simplecomic.library.scan",
									  qos: .utility, attributes: .concurrent)
			let slots = DispatchSemaphore(value: max(1, maxConcurrent))

			for file in files {
				if isCancelled() { break }
				slots.wait()
				group.enter()
				queue.async {
					defer { slots.signal(); group.leave() }
					if isCancelled() { return }

					let result = examine(file, folder: folder, known: known[file.relativePath])
					let done = counter.increment()
					DispatchQueue.main.async {
						outcome(result)
						progress(done, total)
					}
				}
			}
			group.wait()
			return total
		}
	}

	/// Decides what to do with one found file. Unchanged files are never opened, which is
	/// what keeps a rescan of a large folder cheap.
	private static func examine(_ file: SCLibrarySource.FoundFile,
								folder: SCLibraryFolder,
								known: KnownFile?) -> ScanOutcome {
		if let known = known {
			let sameSize = known.size == file.size
			let sameDate = known.modified == nil || file.modified == nil
				|| abs(known.modified!.timeIntervalSince(file.modified!)) < 1
			if sameSize, sameDate, known.hasCover {
				return .unchanged(id: known.id)
			}
		}
		do {
			let prepared = try prepare(url: file.url,
									   folderID: folder.id,
									   relativePath: file.relativePath,
									   size: file.size,
									   modified: file.modified,
									   reusing: known?.id)
			return known == nil ? .added(prepared) : .refreshed(prepared)
		} catch {
			return .failed(relativePath: file.relativePath, error: error)
		}
	}

	/// A counter shared across the scan's concurrent workers.
	private final class Counter {
		private let lock = NSLock()
		private var value = 0
		func increment() -> Int {
			lock.lock()
			defer { lock.unlock() }
			value += 1
			return value
		}
	}
}
