//
//  LegacyMigrationTests.swift
//  PaperComicTests
//
//  The Simple Comic library comes over once, with reading state, metadata, covers and
//  downloads, and the old files stay untouched.
//

import XCTest
import SwiftData

@MainActor
final class LegacyMigrationTests: XCTestCase {

	override class func setUp() {
		super.setUp()
		TestStorage.prepare()
	}

	private var legacy: URL!

	override func setUpWithError() throws {
		legacy = FileManager.default.temporaryDirectory
			.appendingPathComponent("LegacyLibrary-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: legacy.appendingPathComponent("Covers"),
												withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: legacy)
	}

	private func makeContext() throws -> ModelContext {
		let container = try ModelContainer(for: ComicBook.self, Bookmark.self,
										   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
		return ModelContext(container)
	}

	func testFolderComicsComeOverWithStateCoverAndDownload() throws {
		let folder = UUID(), other = UUID()
		let read = UUID(), unread = UUID(), elsewhere = UUID()
		let coverName = "\(read.uuidString).jpg"
		try Data("cover".utf8).write(to: legacy.appendingPathComponent("Covers/\(coverName)"))
		let download = legacy.appendingPathComponent("Comics/\(read.uuidString)/Topolino 1900.cbz")
		try FileManager.default.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("zip".utf8).write(to: download)

		let json = """
		{
		  "version": 1,
		  "folders": [
		    {"id": "\(folder)", "bookmark": "AAAA", "name": "Topolino", "path": "/Volumes/Daten/Comics/Topolino", "dateAdded": "2026-08-08T10:00:00Z"},
		    {"id": "\(other)", "bookmark": "BBBB", "name": "Other", "path": "/tmp/other", "dateAdded": "2026-08-08T10:00:00Z"}
		  ],
		  "entries": [
		    {"id": "\(read)", "title": "Topolino 1900", "fileName": "\(read.uuidString)/Topolino 1900.cbz",
		     "pageCount": 120, "lastReadPage": 41, "isFavorite": true, "openCount": 3, "isRead": false,
		     "dateOpened": "2026-10-01T08:00:00Z", "coverName": "\(coverName)", "coverAspect": 0.66,
		     "sourceFolderID": "\(folder)", "sourceRelativePath": "1900/Topolino 1900.cbz", "hasLocalArchive": true,
		     "series": "Topolino", "issueNumber": "1900", "metadataScanned": true,
		     "stories": [{"number": 1, "kind": "Storia", "title": "Zio Paperone", "code": "I TL 1900-A", "credits": [{"role": "Disegni", "name": "Cavazzano"}]}]},
		    {"id": "\(unread)", "title": "Topolino 1901", "fileName": "\(unread.uuidString)/Topolino 1901.cbz",
		     "pageCount": 118, "sourceFolderID": "\(folder)", "sourceRelativePath": "1901/Topolino 1901.cbz"},
		    {"id": "\(elsewhere)", "title": "Other", "fileName": "x/Other.cbz", "pageCount": 10,
		     "sourceFolderID": "\(other)", "sourceRelativePath": "Other.cbz"},
		    {"id": "not-a-uuid", "title": "Broken"}
		  ]
		}
		"""
		let context = try makeContext()
		let result = try LegacyMigration.migrate(Data(json.utf8), root: legacy, into: context,
												 defaults: TestStorage.defaults)

		XCTAssertEqual(result, LegacyMigration.Result(imported: 2, skippedOtherFolders: 1, copiedArchives: 1))
		XCTAssertEqual(result.skippedFormats, 0)
		let books = try context.fetch(FetchDescriptor<ComicBook>())
		let migrated = try XCTUnwrap(books.first { $0.id == read })
		XCTAssertEqual(migrated.lastReadPage, 41)
		XCTAssertEqual(migrated.pageCount, 120)
		XCTAssertTrue(migrated.isFavorite)
		XCTAssertEqual(migrated.openCount, 3)
		XCTAssertEqual(migrated.sourceRelativePath, "1900/Topolino 1900.cbz")
		XCTAssertEqual(migrated.displayTitle, "Topolino 1900")
		XCTAssertEqual(migrated.stories.first?.code, "I TL 1900-A")
		XCTAssertTrue(migrated.hasLocalArchive)
		XCTAssertEqual(migrated.fileName, "\(read.uuidString).cbz")
		XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.archiveURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(migrated.coverURL).path))

		let remote = try XCTUnwrap(books.first { $0.id == unread })
		XCTAssertFalse(remote.hasLocalArchive)
		XCTAssertTrue(remote.isRemote)

		// The originals are copied, never moved.
		XCTAssertTrue(FileManager.default.fileExists(atPath: download.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Covers/\(coverName)").path))

		// The bigger folder became the library folder.
		XCTAssertEqual(LibrarySource.chosenPath, "/Volumes/Daten/Comics/Topolino")
	}

	func testRunningTwiceAddsNothing() throws {
		let id = UUID()
		let json = """
		{"folders": [], "entries": [{"id": "\(id)", "title": "Owned", "fileName": "\(id.uuidString)/Owned.cbz", "pageCount": 5}]}
		"""
		let archive = legacy.appendingPathComponent("Comics/\(id.uuidString)/Owned.cbz")
		try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("zip".utf8).write(to: archive)
		let context = try makeContext()
		let first = try LegacyMigration.migrate(Data(json.utf8), root: legacy, into: context, defaults: TestStorage.defaults)
		let second = try LegacyMigration.migrate(Data(json.utf8), root: legacy, into: context, defaults: TestStorage.defaults)
		XCTAssertEqual(first.imported, 1)
		XCTAssertEqual(second.imported, 0)
		XCTAssertEqual(try context.fetchCount(FetchDescriptor<ComicBook>()), 1)
	}

	func testPaperSettingsCarryOverButNeverOverwrite() {
		let defaults = UserDefaults(suiteName: "de.wiredframe.papercomic.tests.paper")!
		defaults.removePersistentDomain(forName: "de.wiredframe.papercomic.tests.paper")
		defaults.set(true, forKey: "SCPaperEffectEnabled")
		defaults.set(0.32, forKey: "SCPaperShowThrough")
		defaults.set(0.5, forKey: "SCPaperGrain")
		defaults.set(0.1, forKey: "paper.grain")
		LegacyMigration.migratePaperSettings(defaults: defaults)
		XCTAssertEqual(defaults.object(forKey: "paper.enabled") as? Bool, true)
		XCTAssertEqual(defaults.double(forKey: "paper.showThrough"), 0.32)
		XCTAssertEqual(defaults.double(forKey: "paper.grain"), 0.1)
	}
}
