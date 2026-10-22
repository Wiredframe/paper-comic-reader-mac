//
//  SettingsView.swift
//  Paper Comic Reader
//
//  Settings: the library folder and backups, reading, and the paper effect.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		TabView {
			LibrarySettings()
				.tabItem { Label("Library", systemImage: "books.vertical") }
			ReadingSettings()
				.tabItem { Label("Reading", systemImage: "book") }
			PaperSettingsView(settings: model.paper)
				.tabItem { Label("Paper", systemImage: "doc.richtext") }
		}
		.frame(width: 520)
		.frame(minHeight: 420)
	}
}

private struct LibrarySettings: View {
	@Environment(AppModel.self) private var model
	@Query private var books: [ComicBook]
	@State private var storage = ""
	@State private var confirmsRemoval = false

	var body: some View {
		Form {
			Section("Library Folder") {
				LabeledContent("Folder") {
					Text(LibrarySource.displayName ?? String(localized: "None"))
						.foregroundStyle(.secondary)
				}
				HStack {
					Button("Choose…") { model.chooseLibraryFolder() }
					Button("Scan Now") { Task { await model.scanLibraryFolder() } }
						.disabled(model.job != nil || !LibrarySource.isConfigured)
				}
				Text("Covers and details are read from the folder. A comic is downloaded when you open it and can be removed again to save space; it stays in the library.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Section("Downloads") {
				LabeledContent("On this Mac", value: storage)
				Button("Remove All Downloads…") { confirmsRemoval = true }
					.confirmationDialog("Remove all downloaded comics from this Mac?", isPresented: $confirmsRemoval) {
						Button("Remove Downloads", role: .destructive) {
							for book in books where book.isFolderBacked && !book.isRemote {
								model.evict(book)
							}
							refreshStorage()
						}
					} message: {
						Text("They stay in the library and are downloaded again when you open them.")
					}
			}
			Section("Metadata") {
				Button("Re-read Metadata") {
					Task { await model.refreshMetadata() }
				}
				.disabled(model.job != nil)
				Text("Reads titles, series and contents again from every comic’s ComicInfo, keeping reading progress and bookmarks.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Section("Backup") {
				Text("A backup holds reading progress, favorites, bookmarks and the comics you imported yourself. The iPhone and iPad app reads the same file.")
					.font(.caption)
					.foregroundStyle(.secondary)
				HStack {
					Button("Export Library…") { model.exportLibrary() }
					Button("Import Backup…") { model.importLibrary() }
				}
				.disabled(model.job != nil)
			}
		}
		.formStyle(.grouped)
		.onAppear(perform: refreshStorage)
	}

	private func refreshStorage() {
		Task.detached {
			let bytes = Self.size(of: Storage.comics)
			let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
			await MainActor.run { storage = text }
		}
	}

	nonisolated private static func size(of folder: URL) -> Int64 {
		guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
		var total: Int64 = 0
		for case let url as URL in walker {
			total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
		}
		return total
	}
}

private struct ReadingSettings: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		@Bindable var reader = model.reader
		Form {
			Section {
				Toggle("Show two pages side by side", isOn: $reader.doublePage)
				Toggle("Read right to left (manga)", isOn: $reader.rightToLeft)
				Picker("Fit", selection: $reader.fit) {
					Text("Whole page").tag(ReaderSettings.Fit.page)
					Text("Window width").tag(ReaderSettings.Fit.width)
				}
				Toggle("Fit the window to the pages (full screen height)", isOn: $reader.fitWindow)
			}
			Section {
				Toggle("Click the left or right edge to turn pages", isOn: $reader.clickToTurn)
				Toggle("Live Text: select and look up text on pages", isOn: $reader.liveText)
			}
		}
		.formStyle(.grouped)
	}
}
