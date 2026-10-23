//
//  LibraryView.swift
//  Paper Comic Reader
//
//  The library: a grid of covers with search, a filter, a sort order and a size, the details of
//  the selected comic in the inspector, and a status line while the library folder is scanned or
//  a comic is downloaded. Opening a comic hands it to the window, which turns into the reader.
//
//  Filtering and sorting run in memory over the whole query. A library is a few thousand comics
//  at most, and the controls should change the grid at once.
//

import SwiftUI
import SwiftData

enum LibraryScope: String, CaseIterable, Identifiable {
	/// The comics opened so far, the last one first: the shelf reached for most.
	case recents
	case comics
	case bookmarks
	var id: String { rawValue }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
	case all
	case unread
	case favorites
	case downloaded
	var id: String { rawValue }

	var label: LocalizedStringKey {
		switch self {
		case .all: "All Comics"
		case .unread: "Unread"
		case .favorites: "Favorites"
		case .downloaded: "Downloaded"
		}
	}
}

enum LibrarySort: String, CaseIterable, Identifiable {
	case dateAdded
	case title
	case series
	case opened
	var id: String { rawValue }

	var label: LocalizedStringKey {
		switch self {
		case .dateAdded: "Date Added"
		case .title: "Title"
		case .series: "Series"
		case .opened: "Last Opened"
		}
	}
}

enum LibraryMetrics {
	/// Cover shape when the comic hasn't said otherwise: between a US comic and a European album.
	static let defaultAspect: CGFloat = 0.69
	static let spacing: CGFloat = 22
	static let coverRadius: CGFloat = 10
	static let columnWidths: ClosedRange<Double> = 110...320
}

struct LibraryView: View {
	let onOpen: (ComicBook, Int?) -> Void

	@Environment(AppModel.self) private var model
	@Query private var books: [ComicBook]

	@AppStorage("library.scope") private var scope = LibraryScope.comics
	@AppStorage("library.filter") private var filter = LibraryFilter.all
	@AppStorage("library.sort") private var sort = LibrarySort.dateAdded
	@AppStorage("library.sortAscending") private var ascending = false
	@AppStorage("library.columnWidth") private var columnWidth = 170.0
	@AppStorage("library.showsDetails") private var showsDetails = true

	@State private var search = ""
	@State private var selection: UUID?
	@State private var bookmarkSelection: UUID?
	@Query private var allBookmarks: [Bookmark]
	@State private var hovered: UUID?
	@State private var pendingDeletion: ComicBook?
	@FocusState private var gridFocused: Bool
	@State private var didFocusGrid = false
	/// How many covers fit across, for moving the selection by a row.
	@State private var columns = 1

	var body: some View {
		VStack(spacing: 0) {
			switch scope {
			case .recents, .comics: comics
			case .bookmarks: BookmarksView(search: search, selection: $bookmarkSelection, onOpen: onOpen)
			}
			if model.job != nil || model.downloads.hasTickets || model.skippedCount > 0 {
				Divider()
				LibraryStatusBar()
			}
		}
		.searchable(text: $search, placement: .toolbar, prompt: scope == .bookmarks ? "Search Bookmarks" : "Search Comics")
		.toolbar { toolbar }
		.navigationTitle("Library")
		.navigationSubtitle(subtitle)
		.inspector(isPresented: $showsDetails) {
			// For a bookmark, the comic it belongs to, opened on its page.
			Group {
				switch scope {
				case .recents, .comics:
					ComicDetailPane(book: selectedBook, onOpen: { onOpen($0, nil) })
				case .bookmarks:
					let mark = bookmarkSelection.flatMap { id in allBookmarks.first { $0.id == id } }
					ComicDetailPane(book: mark?.book, onOpen: { onOpen($0, mark?.pageIndex) })
				}
			}
			.inspectorColumnWidth(min: 240, ideal: 280, max: 380)
		}
		.confirmationDialog(deletionTitle, isPresented: Binding(get: { pendingDeletion != nil },
																set: { if !$0 { pendingDeletion = nil } }),
							titleVisibility: .visible) {
			Button("Remove", role: .destructive) {
				if let book = pendingDeletion {
					selectNeighbour(of: book.id)
					model.delete(book)
				}
				pendingDeletion = nil
			}
		} message: {
			if pendingDeletion?.isFolderBacked == true {
				Text("The comic file in the library folder is not deleted.")
			} else {
				Text("This comic was imported into the library. Its file is deleted with it.")
			}
		}
	}

	private var selectedBook: ComicBook? {
		selection.flatMap { id in books.first { $0.id == id } }
	}

	private var subtitle: String {
		String(localized: "\(visibleBooks.count) comics")
	}

	private var deletionTitle: String {
		guard let book = pendingDeletion else { return "" }
		return String(localized: "Remove “\(book.displayTitle)” from the library?")
	}

	// MARK: Filtering and sorting

	private var visibleBooks: [ComicBook] {
		// Recents has one order of its own and no filter: what was opened, the latest first.
		if scope == .recents {
			return books
				.filter { $0.dateOpened != nil && $0.matches(searchQuery: search) }
				.sorted { $0.dateOpened! > $1.dateOpened! }
		}
		var result = books.filter { book in
			switch filter {
			case .all: break
			case .unread: if book.isRead { return false }
			case .favorites: if !book.isFavorite { return false }
			case .downloaded: if book.isRemote { return false }
			}
			return book.matches(searchQuery: search)
		}
		result.sort { lhs, rhs in
			let ordered: Bool
			switch sort {
			case .dateAdded:
				ordered = lhs.dateAdded < rhs.dateAdded
			case .title:
				ordered = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
			case .series:
				ordered = lhs.sortsBefore(rhs)
			case .opened:
				ordered = (lhs.dateOpened ?? .distantPast) < (rhs.dateOpened ?? .distantPast)
			}
			return ascending ? ordered : !ordered
		}
		return result
	}

	// MARK: Grid

	@ViewBuilder
	private var comics: some View {
		if books.isEmpty {
			LibraryEmptyView()
		} else {
			let visible = visibleBooks
			if visible.isEmpty, scope == .recents, search.isEmpty {
				ContentUnavailableView("No Recent Comics", systemImage: "clock",
									   description: Text("Comics you open show up here."))
			} else if visible.isEmpty {
				ContentUnavailableView.search(text: search)
			} else {
				grid(visible)
			}
		}
	}

	private func grid(_ visible: [ComicBook]) -> some View {
		GeometryReader { geometry in
			ScrollViewReader { proxy in
				ScrollView {
					LazyVGrid(columns: [GridItem(.adaptive(minimum: columnWidth), spacing: LibraryMetrics.spacing, alignment: .top)],
							  spacing: LibraryMetrics.spacing) {
						ForEach(visible) { book in
							CoverCell(book: book,
									  width: columnWidth,
									  isSelected: selection == book.id,
									  isHovered: hovered == book.id,
									  download: model.downloads.ticket(for: book.id),
									  onCancelDownload: { model.downloads.cancel(book.id) })
								.id(book.id)
								.overlay {
									if model.downloads.ticket(for: book.id) == nil {
										CellMouse(onSelect: { select(book.id) },
												  onOpen: { onOpen(book, nil) },
												  onHover: { inside in
													  if inside { hovered = book.id } else if hovered == book.id { hovered = nil }
												  })
									}
								}
								.onTapGesture { select(book.id) }
								.contextMenu { menu(for: book) }
						}
					}
					.padding(LibraryMetrics.spacing)
				}
				.onChange(of: selection) { _, id in
					guard let id else { return }
					withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
				}
			}
			.onAppear { columns = columnCount(forWidth: geometry.size.width) }
			.onChange(of: geometry.size.width) { _, width in columns = columnCount(forWidth: width) }
			.onChange(of: columnWidth) { columns = columnCount(forWidth: geometry.size.width) }
		}
		.focusable()
		.focusEffectDisabled()
		.focused($gridFocused)
		.onAppear {
			#if DEBUG
			if let id = UserDefaults.standard.string(forKey: "debugSelectComic").flatMap(UUID.init) { selection = id }
			#endif
			// Once, when the library first shows: not every time a search brings the grid back,
			// which would pull the focus out of the search field mid-word.
			if !didFocusGrid {
				didFocusGrid = true
				gridFocused = true
			}
		}
		.onKeyPress(.leftArrow) { move(-1, in: visible) }
		.onKeyPress(.rightArrow) { move(1, in: visible) }
		.onKeyPress(.upArrow) { move(-columns, in: visible) }
		.onKeyPress(.downArrow) { move(columns, in: visible) }
		.onKeyPress(.return) {
			guard let book = selectedBook else { return .ignored }
			onOpen(book, nil)
			return .handled
		}
		.onKeyPress(.space) {
			showsDetails.toggle()
			return .handled
		}
	}

	private func select(_ id: UUID) {
		selection = id
		gridFocused = true
	}

	private func columnCount(forWidth width: CGFloat) -> Int {
		let usable = width - LibraryMetrics.spacing * 2
		let step = columnWidth + LibraryMetrics.spacing
		return max(1, Int((usable + LibraryMetrics.spacing) / step))
	}

	/// Moves the selection by `offset` covers. Stops at the ends rather than wrapping.
	private func move(_ offset: Int, in visible: [ComicBook]) -> KeyPress.Result {
		guard !visible.isEmpty else { return .ignored }
		guard let current = selection, let index = visible.firstIndex(where: { $0.id == current }) else {
			selection = visible.first?.id
			return .handled
		}
		let target = min(max(index + offset, 0), visible.count - 1)
		selection = visible[target].id
		return .handled
	}

	/// After a removal, land on the comic that took its place, the way a list does.
	private func selectNeighbour(of removed: UUID) {
		let visible = visibleBooks
		guard let index = visible.firstIndex(where: { $0.id == removed }) else { return }
		let remaining = visible.filter { $0.id != removed }
		selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
	}

	@ViewBuilder
	private func menu(for book: ComicBook) -> some View {
		Button("Open") { onOpen(book, nil) }
		Button("Open in New Tab") { model.openInNewTab(book.id) }
		Divider()
		Button(book.isFavorite ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(book) }
		Button(book.isRead ? "Mark as Unread" : "Mark as Read") { model.toggleRead(book) }
		if scope == .recents {
			Button("Remove from Recents") {
				selectNeighbour(of: book.id)
				model.removeFromRecents(book)
			}
		}
		Divider()
		Button("Show in Finder") { model.revealInFinder(book) }
		if book.isFolderBacked {
			if book.isRemote {
				Button("Download") { model.downloads.start(book, in: model.context) }
			} else {
				Button("Remove Download") { model.evict(book) }
			}
		}
		Divider()
		Button("Remove from Library…") { pendingDeletion = book }
	}

	// MARK: Toolbar

	@ToolbarContentBuilder
	private var toolbar: some ToolbarContent {
		ToolbarItem(placement: .principal) {
			Picker("Show", selection: $scope) {
				Text("Recents").tag(LibraryScope.recents)
				Text("Comics").tag(LibraryScope.comics)
				Text("Bookmarks").tag(LibraryScope.bookmarks)
			}
			.pickerStyle(.segmented)
			.labelsHidden()
		}
		ToolbarItemGroup(placement: .primaryAction) {
			if scope == .recents {
				Button { model.clearRecents() } label: {
					Label("Clear Recents", systemImage: "clock.badge.xmark")
				}
				.help("Clear the list of recent comics. The comics stay in the library.")
				.disabled(!books.contains { $0.dateOpened != nil })
			}
			if scope == .comics {
				Menu {
					Picker("Show", selection: $filter) {
						ForEach(LibraryFilter.allCases) { Text($0.label).tag($0) }
					}
					.pickerStyle(.inline)
					Picker("Sort By", selection: $sort) {
						ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
					}
					.pickerStyle(.inline)
					Toggle("Ascending", isOn: $ascending)
				} label: {
					Label("Filter and Sort", systemImage: filter == .all
						  ? "line.3.horizontal.decrease.circle"
						  : "line.3.horizontal.decrease.circle.fill")
				}
				.help("Filter and sort the library")
			}
			if scope != .bookmarks {
				Slider(value: $columnWidth, in: LibraryMetrics.columnWidths)
					.frame(width: 90)
					.help("Cover size")
			}
			Button { showsDetails.toggle() } label: {
				Label("Details", systemImage: "sidebar.right")
			}
			.help("Show or hide the details")
		}
	}
}

// MARK: - Cover cell

struct CoverCell: View {
	let book: ComicBook
	let width: CGFloat
	let isSelected: Bool
	let isHovered: Bool
	/// Set while this comic is downloading: the cloud badge becomes a progress ring that stops it.
	let download: DownloadManager.Ticket?
	let onCancelDownload: () -> Void

	private var aspect: CGFloat {
		guard let aspect = book.coverAspect, aspect > 0.2, aspect < 3 else { return LibraryMetrics.defaultAspect }
		return CGFloat(aspect)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			ZStack(alignment: .bottomLeading) {
				RoundedRectangle(cornerRadius: LibraryMetrics.coverRadius, style: .continuous)
					.fill(.quaternary)
				if book.coverURL == nil {
					Image(systemName: "exclamationmark.triangle")
						.font(.system(size: width * 0.18, weight: .thin))
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
				CoverImage(url: book.coverURL, maxPixel: width * 2)
					.clipShape(RoundedRectangle(cornerRadius: LibraryMetrics.coverRadius, style: .continuous))
				badges
			}
			.frame(width: width, height: width / aspect)
			.overlay(
				RoundedRectangle(cornerRadius: LibraryMetrics.coverRadius, style: .continuous)
					.strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
			)
			.shadow(color: .black.opacity(isHovered ? 0.35 : 0.25), radius: isHovered ? 9 : 4, y: isHovered ? 5 : 2)
			.scaleEffect(isHovered ? 1.02 : 1)
			.animation(.easeOut(duration: 0.12), value: isHovered)

			Text(book.displayTitle)
				.font(.system(size: 12, weight: .medium))
				.foregroundStyle(isSelected ? Color.accentColor : Color.primary)
				.lineLimit(1)
			Text(book.displaySubtitle ?? " ")
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.lineLimit(1)
			progressLine
		}
		.frame(width: width)
	}

	private var badges: some View {
		HStack(spacing: 4) {
			if book.isFavorite { badge("heart.fill") }
			if let download {
				DownloadRing(ticket: download, onCancel: onCancelDownload)
			} else if book.isRemote {
				badge("icloud.and.arrow.down")
			}
			Spacer()
			if book.isRead { badge("checkmark") }
		}
		.padding(5)
	}

	private func badge(_ systemImage: String) -> some View {
		Image(systemName: systemImage)
			.font(.system(size: 9, weight: .semibold))
			.foregroundStyle(.white)
			.padding(4)
			.background(Circle().fill(.black.opacity(0.55)))
	}

	@ViewBuilder
	private var progressLine: some View {
		if book.pageCount > 0, book.lastReadPage > 0, !book.isRead {
			GeometryReader { geometry in
				ZStack(alignment: .leading) {
					Capsule().fill(.quaternary)
					Capsule().fill(Color.accentColor).frame(width: geometry.size.width * book.progress)
				}
			}
			.frame(height: 3)
		} else {
			Color.clear.frame(height: 3)
		}
	}
}

/// A download in progress, as a ring you click to stop it. Reads only its own ticket, so a
/// progress tick redraws this ring and nothing else.
struct DownloadRing: View {
	let ticket: DownloadManager.Ticket
	let onCancel: () -> Void

	var body: some View {
		Button(action: onCancel) {
			ZStack {
				Circle().fill(.black.opacity(0.6))
				Circle()
					.trim(from: 0, to: max(0.02, min(1, ticket.progress)))
					.stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
					.rotationEffect(.degrees(-90))
					.padding(1.5)
				Image(systemName: "xmark")
					.font(.system(size: 8, weight: .bold))
					.foregroundStyle(.white)
			}
			.frame(width: 21, height: 21)
		}
		.buttonStyle(.plain)
		.help("Stop the download")
	}
}

// MARK: - Empty and status

struct LibraryEmptyView: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		ContentUnavailableView {
			Label("Your Library Is Empty", systemImage: "books.vertical")
		} description: {
			Text("Choose the folder that holds your comics, or import CBZ files. Covers and details are read in; a comic from the library folder is downloaded when you open it.")
		} actions: {
			Button("Choose Library Folder…") { model.chooseLibraryFolder() }
				.buttonStyle(.borderedProminent)
				.disabled(model.job != nil)
			Button("Import Comics…") { model.importComics() }
			Button("Import Library Backup…") { model.importLibrary() }
		}
	}
}

struct LibraryStatusBar: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		HStack(spacing: 10) {
			if let job = model.job {
				if job.total > 0 {
					ProgressView(value: Double(job.done), total: Double(job.total)).frame(width: 130)
					Text("\(job.title): \(job.done) of \(job.total)").font(.caption)
				} else {
					ProgressView().controlSize(.small)
					Text("\(job.title)…").font(.caption)
				}
			} else if model.downloads.hasTickets {
				ProgressView().controlSize(.small)
				Text("Downloading from the library folder…").font(.caption)
			} else if model.skippedCount > 0 {
				Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
				Text("\(model.skippedCount) files in the library folder couldn’t be read.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
	}
}
