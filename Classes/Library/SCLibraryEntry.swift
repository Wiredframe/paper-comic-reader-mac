//
//  SCLibraryEntry.swift
//  Simple Comic
//
//  The library's value types: one entry per comic, one folder per scanned source, and
//  the document that holds both and is written to library.json.
//
//  Deliberately plain Codable structs rather than managed objects. The app's Core Data
//  store is scratch space for open windows — closing a window deletes its session, and
//  SimpleComicAppDelegate deletes the whole store outright on a version mismatch. The
//  library has to outlive all of that, so it owns its own file.
//
//  Decoding is written by hand with `decodeIfPresent` throughout: a field added in a
//  later version must never make an older index unreadable, and one unknown comic must
//  never cost the user their whole library.
//

import Foundation

// MARK: - Entry

struct SCLibraryEntry: Codable, Identifiable, Hashable {

	let id: UUID

	/// File name without extension. The comic's identity to a human, and what the reader
	/// window is titled with.
	var title: String

	// MARK: Source

	/// The scanned folder this comic came from, or nil for a one-off added file.
	var sourceFolderID: UUID?
	/// Path relative to that folder — "Topolino/1900.cbz". The stable identity of a
	/// folder-backed comic: re-pointing a moved folder relinks every entry at once.
	var sourceRelativePath: String?

	/// Size and modification date of the source file when it was last scanned. A rescan
	/// skips files that match, which is what keeps a second scan of a large folder cheap.
	var sourceSize: Int64?
	var sourceModified: Date?

	// MARK: Local files

	/// Path of the on-demand copy inside `SCLibraryStorage.comics` — `<uuid>/<original name>`.
	var fileName: String
	/// Name of the cover inside `SCLibraryStorage.covers` — `<uuid>.jpg`. Nil if the cover
	/// couldn't be extracted (an unreadable or password-protected archive).
	var coverName: String?
	var coverAspect: Double?

	/// Whether the archive copy is present. Kept as stored state rather than computed from
	/// the file system so that views observing the store actually update when it changes;
	/// the file system still wins whenever the two disagree (see SCLibraryImporter.ensureLocal).
	var hasLocalArchive: Bool = false

	// MARK: Reading state

	var pageCount: Int = 0
	var lastReadPage: Int = 0
	var dateAdded: Date = Date()
	var dateOpened: Date?
	var openCount: Int = 0
	var isRead: Bool = false
	var isFavorite: Bool = false

	// MARK: ComicInfo

	/// False means "not looked at yet", as opposed to "looked at and found nothing".
	var metadataScanned: Bool = false
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
	var stories: [SCComicStory] = []

	// MARK: Derived

	var archiveURL: URL { SCLibraryStorage.archiveURL(fileName) }

	/// The folder holding the on-demand copy. The copy keeps the comic's own file name inside
	/// a folder named after the entry, so removing a download means removing this folder — and
	/// never `Comics` itself, which is what the nil case guards.
	var archiveContainerURL: URL? {
		let parent = archiveURL.deletingLastPathComponent().standardizedFileURL
		return parent == SCLibraryStorage.comics.standardizedFileURL ? nil : parent
	}
	var coverURL: URL? { coverName.map(SCLibraryStorage.coverURL) }

	var isFolderBacked: Bool { sourceFolderID != nil && sourceRelativePath != nil }

	/// The comic is in the library but its bytes are not — the badge state.
	var isRemote: Bool { isFolderBacked && !hasLocalArchive }

	/// Series and issue number when tagged, the file name otherwise. Metadata is often
	/// better than the file name, but never worse than nothing.
	var displayTitle: String {
		guard let series = series?.sc_nonEmpty else { return title }
		if let number = issueNumber?.sc_nonEmpty {
			return "\(series) \(number)"
		}
		return series
	}

	/// The issue title, or the first story from the index — the second line under a cover.
	var displaySubtitle: String? {
		if let issueTitle = issueTitle?.sc_nonEmpty { return issueTitle }
		return stories.first?.title.sc_nonEmpty
	}

	var progress: Double {
		guard pageCount > 1 else { return isRead ? 1 : 0 }
		return min(1, max(0, Double(lastReadPage) / Double(pageCount - 1)))
	}

	var dateLabel: String? {
		guard let year = year else { return nil }
		guard let month = month, (1...12).contains(month) else { return String(year) }
		var components = DateComponents()
		components.year = year
		components.month = month
		components.day = day ?? 1
		guard let date = Calendar.current.date(from: components) else { return String(year) }
		let formatter = DateFormatter()
		formatter.setLocalizedDateFormatFromTemplate(day == nil ? "yMMMM" : "yMMMMd")
		return formatter.string(from: date)
	}

	/// Case- and diacritic-insensitive match across the fields a search should reach.
	func matches(searchQuery query: String) -> Bool {
		let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !needle.isEmpty else { return true }
		let haystack = [title, series, issueNumber, issueTitle, publisher, writers,
						pencillers, inkers, characters]
			.compactMap { $0 }
			.joined(separator: " ")
		if haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
			return true
		}
		return stories.contains {
			$0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
		}
	}

	// MARK: Mutation

	mutating func apply(_ info: SCComicInfoData?) {
		metadataScanned = true
		guard let info = info else {
			// Read, but untagged: clear stale fields rather than leave a previous scan behind.
			series = nil; issueNumber = nil; issueTitle = nil; summary = nil
			publisher = nil; year = nil; month = nil; day = nil
			writers = nil; pencillers = nil; inkers = nil; characters = nil
			languageISO = nil; webURL = nil; notes = nil; stories = []
			return
		}
		series = info.series
		issueNumber = info.number
		issueTitle = info.title
		summary = info.summary
		publisher = info.publisher
		year = info.year
		month = info.month
		day = info.day
		writers = info.writer
		pencillers = info.penciller
		inkers = info.inker
		characters = info.characters
		languageISO = info.languageISO
		webURL = info.web
		notes = info.notes
		stories = info.stories
	}

	// MARK: Init

	init(id: UUID = UUID(), title: String, fileName: String) {
		self.id = id
		self.title = title
		self.fileName = fileName
	}

	// MARK: Codable

	private enum CodingKeys: String, CodingKey {
		case id, title, sourceFolderID, sourceRelativePath, sourceSize, sourceModified
		case fileName, coverName, coverAspect, hasLocalArchive
		case pageCount, lastReadPage, dateAdded, dateOpened, openCount, isRead, isFavorite
		case metadataScanned, series, issueNumber, issueTitle, summary, publisher
		case year, month, day, writers, pencillers, inkers, characters
		case languageISO, webURL, notes, stories
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		// id, title and fileName are the only fields an entry cannot exist without.
		id = try container.decode(UUID.self, forKey: .id)
		title = try container.decode(String.self, forKey: .title)
		fileName = try container.decode(String.self, forKey: .fileName)

		sourceFolderID = try container.decodeIfPresent(UUID.self, forKey: .sourceFolderID)
		sourceRelativePath = try container.decodeIfPresent(String.self, forKey: .sourceRelativePath)
		sourceSize = try container.decodeIfPresent(Int64.self, forKey: .sourceSize)
		sourceModified = try container.decodeIfPresent(Date.self, forKey: .sourceModified)
		coverName = try container.decodeIfPresent(String.self, forKey: .coverName)
		coverAspect = try container.decodeIfPresent(Double.self, forKey: .coverAspect)
		hasLocalArchive = try container.decodeIfPresent(Bool.self, forKey: .hasLocalArchive) ?? false

		pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
		lastReadPage = try container.decodeIfPresent(Int.self, forKey: .lastReadPage) ?? 0
		dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
		dateOpened = try container.decodeIfPresent(Date.self, forKey: .dateOpened)
		openCount = try container.decodeIfPresent(Int.self, forKey: .openCount) ?? 0
		isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
		isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false

		metadataScanned = try container.decodeIfPresent(Bool.self, forKey: .metadataScanned) ?? false
		series = try container.decodeIfPresent(String.self, forKey: .series)
		issueNumber = try container.decodeIfPresent(String.self, forKey: .issueNumber)
		issueTitle = try container.decodeIfPresent(String.self, forKey: .issueTitle)
		summary = try container.decodeIfPresent(String.self, forKey: .summary)
		publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
		year = try container.decodeIfPresent(Int.self, forKey: .year)
		month = try container.decodeIfPresent(Int.self, forKey: .month)
		day = try container.decodeIfPresent(Int.self, forKey: .day)
		writers = try container.decodeIfPresent(String.self, forKey: .writers)
		pencillers = try container.decodeIfPresent(String.self, forKey: .pencillers)
		inkers = try container.decodeIfPresent(String.self, forKey: .inkers)
		characters = try container.decodeIfPresent(String.self, forKey: .characters)
		languageISO = try container.decodeIfPresent(String.self, forKey: .languageISO)
		webURL = try container.decodeIfPresent(String.self, forKey: .webURL)
		notes = try container.decodeIfPresent(String.self, forKey: .notes)
		stories = try container.decodeIfPresent([SCComicStory].self, forKey: .stories) ?? []
	}
}

// MARK: - Folder

/// A scanned source folder. The bookmark lives here rather than in UserDefaults so that
/// several folders can be tracked and each entry can say which one it came from.
struct SCLibraryFolder: Codable, Identifiable, Hashable {
	let id: UUID
	/// Security-scoped bookmark, created while the open panel's grant was held.
	var bookmark: Data
	/// Last known display name and path, for the sources list — shown even when the volume
	/// is offline and the bookmark won't resolve.
	var name: String
	var path: String
	var dateAdded: Date
	var dateScanned: Date?

	init(id: UUID = UUID(), bookmark: Data, name: String, path: String) {
		self.id = id
		self.bookmark = bookmark
		self.name = name
		self.path = path
		self.dateAdded = Date()
	}
}

// MARK: - Document

/// What library.json holds.
struct SCLibraryDocument: Codable {
	static let currentVersion = 1

	var version: Int = SCLibraryDocument.currentVersion
	var folders: [SCLibraryFolder] = []
	var entries: [SCLibraryEntry] = []

	init() {}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
		// Element by element: one entry this build can't read must not cost the whole library.
		folders = (try container.decodeIfPresent([SCLossy<SCLibraryFolder>].self, forKey: .folders) ?? [])
			.compactMap(\.value)
		entries = (try container.decodeIfPresent([SCLossy<SCLibraryEntry>].self, forKey: .entries) ?? [])
			.compactMap(\.value)
	}
}

/// Decodes to nil instead of throwing, so an array of these skips the elements it can't read.
struct SCLossy<Value: Decodable>: Decodable {
	let value: Value?

	init(from decoder: Decoder) throws {
		do {
			value = try Value(from: decoder)
		} catch {
			NSLog("Simple Comic: skipped an unreadable library record (%@)", String(describing: error))
			value = nil
		}
	}
}
