//
//  SCLibraryStore.swift
//  Simple Comic
//
//  The library index in memory, and the one place that reads and writes library.json.
//
//  Everything here is main-thread only: the store is small (a few hundred KB even for a
//  large library), views observe it directly, and the expensive work — opening archives,
//  extracting covers, copying bytes — happens elsewhere and hands finished values back.
//  Writes are debounced and atomic, so a burst of updates during a scan costs one write.
//

import Foundation
import Combine

final class SCLibraryStore: ObservableObject {

	static let shared = SCLibraryStore()

	@Published private(set) var entries: [SCLibraryEntry] = []
	@Published private(set) var folders: [SCLibraryFolder] = []

	private var saveWork: DispatchWorkItem?
	/// Set when library.json exists but could not be read, so it is never overwritten.
	private var isReadOnly = false
	private let saveDelay: TimeInterval = 0.5

	private init() {
		load()
	}

	// MARK: Lookup

	func entry(id: UUID) -> SCLibraryEntry? {
		entries.first { $0.id == id }
	}

	func folder(id: UUID) -> SCLibraryFolder? {
		folders.first { $0.id == id }
	}

	// MARK: Mutation (main thread)

	func insert(_ entry: SCLibraryEntry) {
		precondition(Thread.isMainThread, "SCLibraryStore must be mutated on the main thread")
		if let index = entries.firstIndex(where: { $0.id == entry.id }) {
			entries[index] = entry
		} else {
			entries.append(entry)
		}
		scheduleSave()
	}

	/// Mutates one entry in place. No-op when the entry is gone (it may have been deleted
	/// while a background task was working on it).
	func update(id: UUID, _ mutate: (inout SCLibraryEntry) -> Void) {
		precondition(Thread.isMainThread, "SCLibraryStore must be mutated on the main thread")
		guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
		mutate(&entries[index])
		scheduleSave()
	}

	/// Removes entries from the library and deletes the files they own. The source file in
	/// the scanned folder is never touched — the library is an index, not a file manager.
	func remove(ids: Set<UUID>) {
		precondition(Thread.isMainThread, "SCLibraryStore must be mutated on the main thread")
		let doomed = entries.filter { ids.contains($0.id) }
		guard !doomed.isEmpty else { return }
		for entry in doomed {
			// A fetch that outlived its entry would write files back for a comic that no
			// longer exists.
			SCLibraryController.shared.cancelDownload(ifFetching: entry.id)
			SCLibraryStorage.removeLocalArchive(of: entry)
			if let cover = entry.coverURL {
				try? SCLibraryStorage.fm.removeItem(at: cover)
			}
		}
		entries.removeAll { ids.contains($0.id) }
		scheduleSave()
	}

	/// Adds a source, or refreshes the grant of one that is already tracked, and reports the id
	/// the library actually uses. Re-picking a known folder keeps its existing id — and with it
	/// every entry that points at it — so the caller has to scan the id it gets back, not the
	/// one it passed in.
	@discardableResult
	func addFolder(_ folder: SCLibraryFolder) -> UUID {
		precondition(Thread.isMainThread, "SCLibraryStore must be mutated on the main thread")
		defer { scheduleSave() }
		if let index = folders.firstIndex(where: { $0.path == folder.path }) {
			folders[index].bookmark = folder.bookmark
			folders[index].name = folder.name
			return folders[index].id
		}
		folders.append(folder)
		return folder.id
	}

	func updateFolder(id: UUID, _ mutate: (inout SCLibraryFolder) -> Void) {
		precondition(Thread.isMainThread, "SCLibraryStore must be mutated on the main thread")
		guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
		mutate(&folders[index])
		scheduleSave()
	}

	/// Forgets a source. Its entries are removed too: a library row whose folder is gone can
	/// never be opened again, so leaving it would only be a dead cover.
	func removeFolder(id: UUID) {
		precondition(Thread.isMainThread, "SCLibraryStore must be mutated on the main thread")
		let ids = Set(entries.filter { $0.sourceFolderID == id }.map { $0.id })
		remove(ids: ids)
		folders.removeAll { $0.id == id }
		scheduleSave()
	}

	// MARK: Persistence

	private func load() {
		let url = SCLibraryStorage.indexURL
		guard SCLibraryStorage.fm.fileExists(atPath: url.path) else { return }
		let data: Data
		do {
			data = try Data(contentsOf: url)
		} catch {
			// Present but unreadable right now. Starting empty would let the next save overwrite
			// a good index, so stop saving for this launch instead.
			NSLog("Simple Comic: library index could not be read (%@); not saving this session",
				  String(describing: error))
			isReadOnly = true
			return
		}
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		do {
			let document = try decoder.decode(SCLibraryDocument.self, from: data)
			folders = document.folders
			entries = document.entries
		} catch {
			// Keep the unreadable file instead of overwriting it on the next save — the
			// covers are all still on disk, so a damaged index is recoverable by hand.
			let backup = url.appendingPathExtension("broken")
			try? SCLibraryStorage.fm.removeItem(at: backup)
			try? SCLibraryStorage.fm.moveItem(at: url, to: backup)
			NSLog("Simple Comic: library index unreadable (%@); moved to %@",
				  String(describing: error), backup.lastPathComponent)
		}
	}

	private func scheduleSave() {
		saveWork?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.writeNow() }
		saveWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
	}

	/// Writes any pending change immediately. Called on quit.
	func flush() {
		saveWork?.cancel()
		saveWork = nil
		writeNow()
	}

	private func writeNow() {
		saveWork = nil
		guard !isReadOnly else { return }
		var document = SCLibraryDocument()
		document.folders = folders
		document.entries = entries

		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		guard let data = try? encoder.encode(document) else { return }
		do {
			try data.write(to: SCLibraryStorage.indexURL, options: .atomic)
		} catch {
			NSLog("Simple Comic: could not write the library index: %@", String(describing: error))
		}
	}
}
