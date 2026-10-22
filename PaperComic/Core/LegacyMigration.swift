//
//  LegacyMigration.swift
//  Paper Comic Reader
//
//  One-time move of the Simple Comic library into this app. Same bundle id, same sandbox
//  container, so the old files are simply there:
//
//      Application Support/Simple Comic/Library/library.json   the index
//      Application Support/Simple Comic/Library/Covers/         cover JPEGs
//      Application Support/Simple Comic/Library/Comics/<uuid>/  downloaded copies
//
//  Everything is COPIED, never moved: the old folder stays exactly as it was, so nothing about
//  the user's library history can be lost here, and a failed run can simply run again. The
//  library folder's security-scoped bookmark carries over as is, because both apps make it the
//  same way (`.withSecurityScope`).
//
//  Simple Comic tracked several folders; this app, like the iOS one, has one library folder.
//  The folder holding the most comics becomes it. Entries of any other folder are left behind
//  (the old index still has them) and counted in the log.
//

import Foundation
import SwiftData

enum LegacyMigration {

	private static let doneKey = "migration.simpleComicLibrary"

	/// The old library folder, inside the same container.
	static var legacyRoot: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Simple Comic/Library", isDirectory: true)
	}

	/// What the migration did, for the log and the tests.
	struct Result: Equatable {
		var imported = 0
		var skippedOtherFolders = 0
		var copiedArchives = 0
	}

	/// Runs once per installation. Returns nil when there was nothing to do.
	@MainActor @discardableResult
	static func runIfNeeded(into context: ModelContext,
							from root: URL = legacyRoot,
							defaults: UserDefaults = .standard) -> Result? {
		guard !defaults.bool(forKey: doneKey) else { return nil }
		migratePaperSettings(defaults: defaults)
		let index = root.appendingPathComponent("library.json")
		guard FileManager.default.fileExists(atPath: index.path) else {
			defaults.set(true, forKey: doneKey)
			return nil
		}
		do {
			let data = try Data(contentsOf: index)
			let result = try migrate(data, root: root, into: context, defaults: defaults)
			defaults.set(true, forKey: doneKey)
			NSLog("Paper Comic: migrated %d comics from Simple Comic (%d in other folders left behind, %d downloads copied)",
				  result.imported, result.skippedOtherFolders, result.copiedArchives)
			return result
		} catch {
			// Not marked done: the next launch tries again. The old files are untouched either way.
			NSLog("Paper Comic: could not migrate the Simple Comic library: %@", String(describing: error))
			return nil
		}
	}

	// MARK: The old document

	private struct Document: Decodable {
		var folders: [Folder] = []
		var entries: [Entry] = []

		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			folders = (try c.decodeIfPresent([Lossy<Folder>].self, forKey: .folders) ?? []).compactMap(\.value)
			entries = (try c.decodeIfPresent([Lossy<Entry>].self, forKey: .entries) ?? []).compactMap(\.value)
		}
		enum CodingKeys: String, CodingKey { case folders, entries }
	}

	private struct Folder: Decodable {
		let id: UUID
		let bookmark: Data
		let name: String
		let path: String
	}

	private struct Entry: Decodable {
		let id: UUID
		let title: String
		let fileName: String
		var pageCount: Int?
		var dateAdded: Date?
		var dateOpened: Date?
		var lastReadPage: Int?
		var coverName: String?
		var coverAspect: Double?
		var isRead: Bool?
		var isFavorite: Bool?
		var openCount: Int?
		var sourceFolderID: UUID?
		var sourceRelativePath: String?
		var hasLocalArchive: Bool?
		var metadataScanned: Bool?
		var series: String?
		var issueNumber: String?
		var issueTitle: String?
		var summary: String?
		var publisher: String?
		var year: Int?
		var month: Int?
		var day: Int?
		var writers: String?
		var pencillers: String?
		var inkers: String?
		var characters: String?
		var languageISO: String?
		var webURL: String?
		var notes: String?
		var stories: [ComicStory]?
	}

	private struct Lossy<Value: Decodable>: Decodable {
		let value: Value?
		init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
	}

	// MARK: Migrating

	@MainActor
	static func migrate(_ data: Data, root: URL, into context: ModelContext,
						defaults: UserDefaults) throws -> Result {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let document = try decoder.decode(Document.self, from: data)
		var result = Result()

		let counts = Dictionary(grouping: document.entries.compactMap(\.sourceFolderID), by: { $0 }).mapValues(\.count)
		let folder = document.folders.max { (counts[$0.id] ?? 0) < (counts[$1.id] ?? 0) }
		if let folder, !LibrarySource.isConfigured {
			LibrarySource.adopt(bookmark: folder.bookmark, name: folder.name, path: folder.path, defaults: defaults)
		}

		let existing = Set(((try? context.fetch(FetchDescriptor<ComicBook>())) ?? []).map(\.id))
		let fm = FileManager.default
		for entry in document.entries where !existing.contains(entry.id) {
			if let source = entry.sourceFolderID, source != folder?.id {
				result.skippedOtherFolders += 1
				continue
			}
			let isFolderBacked = entry.sourceFolderID != nil && entry.sourceRelativePath != nil
			let ext = (entry.fileName as NSString).pathExtension.lowercased()
			let fileName = "\(entry.id.uuidString).\(ext.isEmpty ? "cbz" : ext)"

			var coverName: String?
			if let old = entry.coverName {
				let source = root.appendingPathComponent("Covers").appendingPathComponent(old)
				let target = Storage.coverURL(old)
				if fm.fileExists(atPath: target.path) || (try? fm.copyItem(at: source, to: target)) != nil {
					coverName = old
				}
			}

			// Downloads come along, so a comic that was ready to read offline still is.
			let oldArchive = root.appendingPathComponent("Comics").appendingPathComponent(entry.fileName)
			var hasArchive = false
			if fm.fileExists(atPath: oldArchive.path) {
				let target = Storage.comicURL(fileName)
				if fm.fileExists(atPath: target.path) || (try? fm.copyItem(at: oldArchive, to: target)) != nil {
					hasArchive = true
					result.copiedArchives += 1
					if isFolderBacked { Storage.excludeFromDeviceBackup(target) }
				}
			}
			// An owned copy whose bytes are gone has nothing to open; leave it behind.
			if !isFolderBacked && !hasArchive { continue }

			let book = ComicBook(id: entry.id, title: entry.title, fileName: fileName,
								 pageCount: entry.pageCount ?? 0, coverName: coverName,
								 coverAspect: entry.coverAspect)
			book.dateAdded = entry.dateAdded ?? .now
			book.dateOpened = entry.dateOpened
			book.lastReadPage = entry.lastReadPage ?? 0
			book.isRead = entry.isRead ?? false
			book.isFavorite = entry.isFavorite ?? false
			book.openCount = entry.openCount ?? 0
			book.sourceRelativePath = isFolderBacked ? entry.sourceRelativePath : nil
			book.hasLocalArchive = hasArchive || !isFolderBacked
			book.metadataScanned = entry.metadataScanned ?? false
			book.series = entry.series
			book.issueNumber = entry.issueNumber
			book.issueTitle = entry.issueTitle
			book.summary = entry.summary
			book.publisher = entry.publisher
			book.year = entry.year
			book.month = entry.month
			book.day = entry.day
			book.writers = entry.writers
			book.pencillers = entry.pencillers
			book.inkers = entry.inkers
			book.characters = entry.characters
			book.languageISO = entry.languageISO
			book.webURL = entry.webURL
			book.notes = entry.notes
			book.stories = entry.stories ?? []
			context.insert(book)
			result.imported += 1
		}
		try context.save()
		return result
	}

	// MARK: Paper effect

	/// Simple Comic kept the paper settings under its own keys. Taken over once, and only where
	/// this app has no value of its own yet.
	static func migratePaperSettings(defaults: UserDefaults) {
		let pairs = [("SCPaperEffectEnabled", "paper.enabled"),
					 ("SCPaperShowThrough", "paper.showThrough"),
					 ("SCPaperGrain", "paper.grain"),
					 ("SCPaperWarmth", "paper.warmth"),
					 ("SCPaperBlackLift", "paper.blackLift"),
					 ("SCPaperFiberScale", "paper.fiberScale")]
		for (old, new) in pairs where defaults.object(forKey: new) == nil {
			if let value = defaults.object(forKey: old) { defaults.set(value, forKey: new) }
		}
	}
}
