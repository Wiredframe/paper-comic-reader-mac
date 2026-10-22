//
//  SCLibrarySource.swift
//  Simple Comic
//
//  A scanned comic folder: the app is sandboxed, so reaching a folder the user picked
//  means holding a security-scoped grant, and remembering it across launches means a
//  security-scoped bookmark.
//
//  The same round trip already exists on TSSTManagedGroup (setFileURL:/fileURL), but that
//  one is destructive by design: when a bookmark won't resolve it puts up a modal panel and
//  deletes the managed object. A scan runs over a whole folder, unattended, so this version
//  only ever reports failure and leaves the decision to the caller.
//
//  All the resolving and enumerating here can block on a network volume. Call it off the
//  main thread.
//

import AppKit

enum SCLibrarySource {

	enum SourceError: LocalizedError {
		case unresolved(String)
		case notReachable(String)
		case fileMissing(String)
		/// The user stopped a download. Carries no message: nothing failed.
		case cancelled
		/// Another comic is already being fetched.
		case busy

		var errorDescription: String? {
			switch self {
			case .unresolved(let name):
				return String(format: NSLocalizedString("The folder “%@” could not be opened.",
														comment: "library folder bookmark failed to resolve"), name)
			case .notReachable(let name):
				return String(format: NSLocalizedString("The folder “%@” is not available.",
														comment: "library folder is offline"), name)
			case .fileMissing(let path):
				return String(format: NSLocalizedString("“%@” is no longer in the library folder.",
														comment: "a scanned comic file has gone"), path)
			case .cancelled:
				return nil
			case .busy:
				return NSLocalizedString("Another comic is being downloaded. Try again once it has finished.",
										 comment: "a second download was requested")
			}
		}
	}

	/// What a resolve produced: the folder, plus fresh bookmark data when the old one had
	/// gone stale. The caller writes that back to the store — this type never touches it,
	/// because resolving happens off the main thread and the store is main-thread only.
	struct Resolved {
		let url: URL
		let refreshedBookmark: Data?
	}

	// MARK: Bookmarks

	/// Creates a security-scoped bookmark for a folder the user just picked in an open panel.
	/// Made while the panel's grant is still held, so it carries that grant forward.
	/// Unlike the iOS app, macOS needs `.withSecurityScope` explicitly on both ends.
	static func bookmark(for url: URL) throws -> Data {
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		return try url.bookmarkData(options: [.withSecurityScope],
									includingResourceValuesForKeys: [.volumeURLForRemountingKey,
																	 .volumeUUIDStringKey],
									relativeTo: nil)
	}

	/// Resolves a stored folder. A stale bookmark (the volume remounted elsewhere) still
	/// resolves and is re-made so it keeps working next time.
	static func resolve(_ folder: SCLibraryFolder) throws -> Resolved {
		var stale = false
		guard let url = try? URL(resolvingBookmarkData: folder.bookmark,
								 options: [.withoutUI, .withSecurityScope],
								 relativeTo: nil,
								 bookmarkDataIsStale: &stale) else {
			throw SourceError.unresolved(folder.name)
		}
		guard stale else { return Resolved(url: url, refreshedBookmark: nil) }
		let refreshed = try? bookmark(for: url)
		return Resolved(url: url, refreshedBookmark: refreshed)
	}

	/// Runs `body` with the folder's security scope held — the one place that owns the
	/// start/stop pairing, so a grant can't leak. The scope covers everything below the
	/// folder, so concurrent reads of individual comics inside `body` need no scope of
	/// their own.
	@discardableResult
	static func withAccess<T>(to folder: SCLibraryFolder, _ body: (URL) throws -> T) throws -> T {
		let resolved = try resolve(folder)
		let url = resolved.url
		if let refreshed = resolved.refreshedBookmark {
			// Keep the renewed grant: a stale bookmark that is never rewritten stops resolving
			// altogether after the next move. The store is main-thread only.
			DispatchQueue.main.async {
				SCLibraryStore.shared.updateFolder(id: folder.id) { stored in
					stored.bookmark = refreshed
					stored.path = url.path
					stored.name = url.lastPathComponent
				}
			}
		}
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		guard (try? url.checkResourceIsReachable()) == true else {
			throw SourceError.notReachable(folder.name)
		}
		return try body(url)
	}

	// MARK: Enumeration

	/// One comic file found by a scan.
	struct FoundFile {
		let url: URL
		let relativePath: String
		let size: Int64
		let modified: Date?
	}

	/// The comic files under `folder`, each with its path relative to `folder` — the stable
	/// identity a scanned entry stores, so a moved folder relinks by re-pointing once.
	///
	/// Matched by extension against the same list the app opens (`TSSTManagedArchive`), and
	/// recursive, because a comic folder is nearly always foldered by series. Call inside
	/// `withAccess`.
	static func comicFiles(in folder: URL) -> [FoundFile] {
		let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
		guard let walker = FileManager.default.enumerator(at: folder,
														  includingPropertiesForKeys: keys,
														  options: [.skipsHiddenFiles,
																	.skipsPackageDescendants]) else { return [] }
		let extensions = Set(TSSTManagedArchive.archiveExtensions.map { $0.lowercased() })
		var found: [FoundFile] = []
		for case let url as URL in walker {
			guard extensions.contains(url.pathExtension.lowercased()) else { continue }
			guard let values = try? url.resourceValues(forKeys: Set(keys)),
				  values.isRegularFile == true else { continue }
			found.append(FoundFile(url: url,
								   relativePath: relativePath(of: url, in: folder),
								   size: Int64(values.fileSize ?? 0),
								   modified: values.contentModificationDate))
		}
		return found
	}

	/// `child` expressed relative to `folder` — "Topolino/1900.cbz". The prefix is compared on
	/// a path boundary ("/base/") so a sibling whose name merely starts the same, Comics vs
	/// ComicsExtra, isn't mistaken for a descendant.
	static func relativePath(of child: URL, in folder: URL) -> String {
		let base = folder.standardizedFileURL.path
		let path = child.standardizedFileURL.path
		let prefix = base.hasSuffix("/") ? base : base + "/"
		guard path.hasPrefix(prefix) else { return child.lastPathComponent }
		let relative = String(path.dropFirst(prefix.count))
		return relative.isEmpty ? child.lastPathComponent : relative
	}

	static func contains(_ url: URL, in folder: URL) -> Bool {
		let base = folder.standardizedFileURL.path
		let prefix = base.hasSuffix("/") ? base : base + "/"
		return url.standardizedFileURL.path.hasPrefix(prefix)
	}

	/// Resolves one comic inside a folder, with the folder's scope held for `body`.
	@discardableResult
	static func withAccess<T>(to folder: SCLibraryFolder, relativePath: String,
							  _ body: (URL) throws -> T) throws -> T {
		try withAccess(to: folder) { root in
			let url = root.appendingPathComponent(relativePath)
			guard (try? url.checkResourceIsReachable()) == true else {
				throw SourceError.fileMissing(relativePath)
			}
			return try body(url)
		}
	}
}
