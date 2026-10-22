//
//  SCLibraryView.swift
//  Simple Comic
//
//  The two panes of the library window: the cover grid and the details pane. The window,
//  its toolbar and the split between them are AppKit and live in SCLibraryWindowController.
//
//  Sorting and filtering happen in memory over the whole array, so the toolbar's controls
//  change the view immediately and the store stays a plain list. Those settings live in
//  UserDefaults, which is what lets the AppKit toolbar and these SwiftUI views share them
//  without either one owning the other: the toolbar writes, @AppStorage reads and re-renders.
//
//  The deployment target is macOS 11.5, so nothing here uses .searchable, AsyncImage, Table
//  or @FocusState.
//

import SwiftUI

// MARK: - Settings

/// The library's persisted view settings, in one place, so the AppKit toolbar and the SwiftUI
/// panes can't drift apart on a key name or a default.
enum SCLibraryDefaults {

	enum Key {
		static let sortField = "SCLibrarySortField"
		static let sortAscending = "SCLibrarySortAscending"
		static let columnWidth = "SCLibraryColumnWidth"
		static let onlyDownloaded = "SCLibraryOnlyDownloaded"
		static let onlyFavorites = "SCLibraryOnlyFavorites"
		static let showsDetails = "SCLibraryShowsDetails"
	}

	static let defaultColumnWidth: Double = 170

	private static var defaults: UserDefaults { .standard }

	static var sortField: String {
		get { defaults.string(forKey: Key.sortField) ?? SCLibrarySort.dateAdded.rawValue }
		set { defaults.set(newValue, forKey: Key.sortField) }
	}

	static var sortAscending: Bool {
		get { defaults.bool(forKey: Key.sortAscending) }
		set { defaults.set(newValue, forKey: Key.sortAscending) }
	}

	static var columnWidth: Double {
		get {
			let stored = defaults.double(forKey: Key.columnWidth)
			return stored > 0 ? stored : defaultColumnWidth
		}
		set { defaults.set(newValue, forKey: Key.columnWidth) }
	}

	static var onlyDownloaded: Bool {
		get { defaults.bool(forKey: Key.onlyDownloaded) }
		set { defaults.set(newValue, forKey: Key.onlyDownloaded) }
	}

	static var onlyFavorites: Bool {
		get { defaults.bool(forKey: Key.onlyFavorites) }
		set { defaults.set(newValue, forKey: Key.onlyFavorites) }
	}

	/// Shown by default, and `bool(forKey:)` would answer false for "never set".
	static var showsDetails: Bool {
		get { defaults.object(forKey: Key.showsDetails) as? Bool ?? true }
		set { defaults.set(newValue, forKey: Key.showsDetails) }
	}
}

// MARK: - Sorting

enum SCLibrarySort: String, CaseIterable, Identifiable {
	case dateAdded
	case title
	case series
	case opened

	var id: String { rawValue }

	var label: String {
		switch self {
		case .dateAdded: return NSLocalizedString("Date Added", comment: "library sort order")
		case .title: return NSLocalizedString("Title", comment: "library sort order")
		case .series: return NSLocalizedString("Series", comment: "library sort order")
		case .opened: return NSLocalizedString("Last Opened", comment: "library sort order")
		}
	}
}

// MARK: - Grid metrics

enum SCLibraryMetrics {
	/// Cover shape when the comic hasn't told us otherwise. Between a US comic (0.66) and a
	/// European album, so neither looks wrong in a mixed library.
	static let defaultAspect: CGFloat = 0.69
	static let spacing: CGFloat = 22
	static let minimumColumnWidth: CGFloat = 110
	/// Rounded rather than squared off — a cover is an object on a shelf here, not a page.
	static let coverRadius: CGFloat = 10
	static let maximumColumnWidth: CGFloat = 320
}

// MARK: - Shared state

/// What the window's chrome and its panes have to agree on: the search text, the selected
/// comic, and what the arrow keys need in order to move that selection — the visible order
/// and how many covers sit in a row.
///
/// A shared object because the pieces live on both sides of the AppKit/SwiftUI line: the
/// search field is a toolbar item, the key handling is a monitor on the window, the grid is
/// SwiftUI. `visibleIDs` and `columns` are deliberately NOT @Published: the grid assigns them
/// while laying out, and publishing there would re-enter the update it is already in.
final class SCLibraryUIState: ObservableObject {

	static let shared = SCLibraryUIState()

	@Published var selectedID: UUID?
	@Published var searchText: String = ""

	var visibleIDs: [UUID] = []
	var columns: Int = 1

	/// Set by the grid so the key monitor can open a comic without knowing the controller.
	var openHandler: ((UUID) -> Void)?

	private init() {}

	/// Moves by `dx` covers and `dy` rows. Moving past either end stops there rather than
	/// wrapping: wrapping in a grid is disorienting, and the ends are what you aim for.
	func move(dx: Int, dy: Int) {
		guard !visibleIDs.isEmpty else { return }
		guard let current = selectedID, let index = visibleIDs.firstIndex(of: current) else {
			selectedID = visibleIDs.first
			return
		}
		let target = index + dx + dy * max(1, columns)
		guard target >= 0, target < visibleIDs.count else {
			if dy > 0 || dx > 0 { selectedID = visibleIDs.last }
			if dy < 0 || dx < 0 { selectedID = visibleIDs.first }
			return
		}
		selectedID = visibleIDs[target]
	}

	func openSelection() {
		guard let selectedID = selectedID else { return }
		openHandler?(selectedID)
	}

	/// After a removal, land on the comic that took its place, the way a list does, instead of
	/// leaving the details pane empty.
	func selectNeighbour(of removed: UUID) {
		guard let index = visibleIDs.firstIndex(of: removed) else { return }
		let remaining = visibleIDs.filter { $0 != removed }
		guard !remaining.isEmpty else {
			selectedID = nil
			return
		}
		selectedID = remaining[min(index, remaining.count - 1)]
	}
}

// MARK: - Grid

struct SCLibraryGridView: View {

	@ObservedObject var store: SCLibraryStore
	@ObservedObject var controller: SCLibraryController
	@ObservedObject var state: SCLibraryUIState

	@State private var hoveredID: UUID?
	@State private var pendingDeletion: SCLibraryEntry?

	@AppStorage(SCLibraryDefaults.Key.sortField) private var sortField = SCLibrarySort.dateAdded.rawValue
	@AppStorage(SCLibraryDefaults.Key.sortAscending) private var ascending = false
	@AppStorage(SCLibraryDefaults.Key.columnWidth) private var columnWidth = SCLibraryDefaults.defaultColumnWidth
	@AppStorage(SCLibraryDefaults.Key.onlyDownloaded) private var onlyDownloaded = false
	@AppStorage(SCLibraryDefaults.Key.onlyFavorites) private var onlyFavorites = false

	private var sort: SCLibrarySort {
		SCLibrarySort(rawValue: sortField) ?? .dateAdded
	}

	private var visibleEntries: [SCLibraryEntry] {
		var result = store.entries.filter { entry in
			if onlyDownloaded && !entry.hasLocalArchive { return false }
			if onlyFavorites && !entry.isFavorite { return false }
			return entry.matches(searchQuery: state.searchText)
		}
		result.sort { lhs, rhs in
			let ordered: Bool
			switch sort {
			case .dateAdded:
				ordered = lhs.dateAdded < rhs.dateAdded
			case .title:
				ordered = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
			case .series:
				let left = lhs.series ?? lhs.title
				let right = rhs.series ?? rhs.title
				if left == right {
					ordered = (lhs.issueNumber ?? "").localizedStandardCompare(rhs.issueNumber ?? "") == .orderedAscending
				} else {
					ordered = left.localizedStandardCompare(right) == .orderedAscending
				}
			case .opened:
				ordered = (lhs.dateOpened ?? .distantPast) < (rhs.dateOpened ?? .distantPast)
			}
			return ascending ? ordered : !ordered
		}
		return result
	}

	var body: some View {
		VStack(spacing: 0) {
			content
			if controller.scan != nil || controller.download != nil || !controller.skipped.isEmpty {
				Divider()
				statusBar
			}
		}
		.onAppear {
			// The key monitor opens through this, so it never needs the controller itself.
			state.openHandler = { id in
				guard let entry = store.entry(id: id) else { return }
				controller.open(entry)
			}
		}
		.alert(item: $pendingDeletion) { entry in
			Alert(title: Text("Remove “\(entry.displayTitle)” from the library?"),
				  message: Text("The comic file itself is not deleted."),
				  primaryButton: .destructive(Text("Remove")) {
					state.selectNeighbour(of: entry.id)
					store.remove(ids: [entry.id])
				  },
				  secondaryButton: .cancel())
		}
	}

	// MARK: Content

	@ViewBuilder
	private var content: some View {
		if store.entries.isEmpty {
			emptyState.onAppear { clearSelectionContext() }
		} else if visibleEntries.isEmpty {
			centered(Text("No comic matches “\(state.searchText)”.").foregroundColor(.secondary))
				.onAppear { clearSelectionContext() }
		} else {
			grid
		}
	}

	private var grid: some View {
		let entries = visibleEntries
		return GeometryReader { geometry in
			// How many covers fit across, so the arrow keys can move by a row. Assigned during
			// layout rather than published: the value is only ever read afterwards, by the key
			// monitor.
			let _ = updateSelectionContext(entries: entries,
										   columns: columnCount(forWidth: geometry.size.width))

			ScrollViewReader { proxy in
				ScrollView {
					LazyVGrid(columns: [GridItem(.adaptive(minimum: CGFloat(columnWidth)),
												 spacing: SCLibraryMetrics.spacing,
												 alignment: .top)],
							  spacing: SCLibraryMetrics.spacing) {
						ForEach(entries) { entry in
							SCLibraryCoverCell(entry: entry,
											   width: CGFloat(columnWidth),
											   isSelected: state.selectedID == entry.id,
											   isHovered: hoveredID == entry.id,
											   downloadFraction: downloadFraction(for: entry),
											   onCancelDownload: { controller.cancelDownload() })
								.id(entry.id)
								// Reached only while this cell is downloading, when the AppKit
								// catcher steps aside for the stop button. A lone tap gesture
								// has nothing to disambiguate, so it fires without a delay.
								.onTapGesture { state.selectedID = entry.id }
								.overlay(mouseHandling(for: entry))
								.contextMenu { menu(for: entry) }
						}
					}
					.padding(SCLibraryMetrics.spacing)
				}
				.onChange(of: state.selectedID) { id in
					guard let id = id else { return }
					withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
				}
			}
		}
	}

	/// Mouse handling for one cover.
	///
	/// The AppKit catcher covers the whole cell, and an NSView always wins hit-testing against
	/// the SwiftUI content behind it — including the stop button that appears while a comic is
	/// being fetched. So the one cell that is downloading keeps that button clickable and
	/// falls back to a plain tap for selection; double-clicking a comic whose bytes are still
	/// arriving would mean nothing anyway.
	@ViewBuilder
	private func mouseHandling(for entry: SCLibraryEntry) -> some View {
		if downloadFraction(for: entry) == nil {
			SCCellMouse(onSelect: { state.selectedID = entry.id },
						onOpen: { controller.open(entry) },
						onHover: { inside in
							if inside {
								hoveredID = entry.id
							} else if hoveredID == entry.id {
								hoveredID = nil
							}
						})
		} else {
			EmptyView()
		}
	}

	private func columnCount(forWidth width: CGFloat) -> Int {
		let usable = width - SCLibraryMetrics.spacing * 2
		let step = CGFloat(columnWidth) + SCLibraryMetrics.spacing
		return max(1, Int((usable + SCLibraryMetrics.spacing) / step))
	}

	@discardableResult
	private func updateSelectionContext(entries: [SCLibraryEntry], columns: Int) -> Int {
		state.visibleIDs = entries.map { $0.id }
		state.columns = columns
		return columns
	}

	/// With no grid on screen there is nothing for the arrow keys to move through, and a
	/// selection left over from a previous filter would drive the details pane to a comic the
	/// user cannot see.
	private func clearSelectionContext() {
		state.visibleIDs = []
		state.columns = 1
		state.selectedID = nil
	}

	private func downloadFraction(for entry: SCLibraryEntry) -> Double? {
		guard let download = controller.download, download.entryID == entry.id else { return nil }
		return download.fraction
	}

	private var emptyState: some View {
		centered(
			VStack(spacing: 14) {
				Image(systemName: "books.vertical")
					.font(.system(size: 44, weight: .thin))
					.foregroundColor(.secondary)
				Text("Your library is empty.")
					.font(.title3)
				Text("Add a folder of comics. Covers and details are read into the library; the files stay where they are.")
					.font(.callout)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
					.frame(maxWidth: 360)
				Button(NSLocalizedString("Add Folder…", comment: "library empty state button")) {
					controller.addFolder(relativeTo: NSApp.keyWindow)
				}
			}
		)
	}

	private func centered<V: View>(_ view: V) -> some View {
		VStack { Spacer(); view; Spacer() }
			.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	@ViewBuilder
	private func menu(for entry: SCLibraryEntry) -> some View {
		Button(NSLocalizedString("Open", comment: "library context menu")) { controller.open(entry) }
		Divider()
		Button(entry.isFavorite
				? NSLocalizedString("Remove from Favorites", comment: "library context menu")
				: NSLocalizedString("Add to Favorites", comment: "library context menu")) {
			store.update(id: entry.id) { $0.isFavorite.toggle() }
		}
		Button(entry.isRead
				? NSLocalizedString("Mark as Unread", comment: "library context menu")
				: NSLocalizedString("Mark as Read", comment: "library context menu")) {
			store.update(id: entry.id) { item in
				item.isRead.toggle()
				item.lastReadPage = item.isRead ? max(0, item.pageCount - 1) : 0
			}
		}
		Divider()
		if entry.isFolderBacked {
			Button(NSLocalizedString("Show in Finder", comment: "library context menu")) {
				controller.revealInFinder(entry)
			}
			if entry.hasLocalArchive {
				Button(NSLocalizedString("Remove Download", comment: "library context menu")) {
					controller.evict(entry)
				}
			} else {
				Button(NSLocalizedString("Download Now", comment: "library context menu")) {
					controller.fetch(entry) { _ in }
				}
			}
		}
		Divider()
		Button(NSLocalizedString("Remove from Library", comment: "library context menu")) {
			pendingDeletion = entry
		}
	}

	// MARK: Status

	private var statusBar: some View {
		HStack(spacing: 10) {
			if let scan = controller.scan {
				ProgressView(value: scan.total > 0 ? Double(scan.done) / Double(scan.total) : 0)
					.frame(width: 130)
				Text(scan.total > 0
					 ? "Scanning \(scan.folderName): \(scan.done) of \(scan.total)"
					 : "Scanning \(scan.folderName)…")
					.font(.caption)
				Button(NSLocalizedString("Stop", comment: "library scan button")) {
					controller.cancelRunningScan()
				}
			} else if let download = controller.download {
				ProgressView(value: download.fraction)
					.frame(width: 130)
				Text("Fetching \(download.title)…").font(.caption)
				Button(NSLocalizedString("Cancel", comment: "library download button")) {
					controller.cancelDownload()
				}
			} else if !controller.skipped.isEmpty {
				Image(systemName: "exclamationmark.triangle").foregroundColor(.secondary)
				Text("\(controller.skipped.count) file(s) could not be read.")
					.font(.caption)
					.foregroundColor(.secondary)
					.help(controller.skipped.prefix(20).joined(separator: "\n"))
			}
			Spacer()
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
	}
}

// MARK: - Cover cell

struct SCLibraryCoverCell: View {

	let entry: SCLibraryEntry
	let width: CGFloat
	let isSelected: Bool
	let isHovered: Bool
	/// Non-nil while this comic is being fetched — the cloud badge becomes a stop button.
	let downloadFraction: Double?
	let onCancelDownload: () -> Void

	private var aspect: CGFloat {
		guard let aspect = entry.coverAspect, aspect > 0.2, aspect < 3 else {
			return SCLibraryMetrics.defaultAspect
		}
		return CGFloat(aspect)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			ZStack(alignment: .bottomLeading) {
				RoundedRectangle(cornerRadius: SCLibraryMetrics.coverRadius, style: .continuous)
					.fill(Color(NSColor.quaternaryLabelColor))
				if entry.coverURL == nil {
					// No cover could be extracted: say so instead of showing an empty slab.
					Image(systemName: "exclamationmark.triangle")
						.font(.system(size: width * 0.18, weight: .thin))
						.foregroundColor(.secondary)
				}
				SCCoverImage(url: entry.coverURL, maxPixel: width * 2)
					.clipShape(RoundedRectangle(cornerRadius: SCLibraryMetrics.coverRadius, style: .continuous))
				badges
			}
			.frame(width: width, height: width / aspect)
			.overlay(
				RoundedRectangle(cornerRadius: SCLibraryMetrics.coverRadius, style: .continuous)
					.strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
			)
			.shadow(color: Color.black.opacity(isHovered ? 0.35 : 0.25),
					radius: isHovered ? 9 : 4, x: 0, y: isHovered ? 5 : 2)
			.scaleEffect(isHovered ? 1.02 : 1)
			.animation(.easeOut(duration: 0.12), value: isHovered)

			Text(entry.displayTitle)
				.font(.system(size: 12, weight: .medium))
				.foregroundColor(isSelected ? Color.accentColor : Color.primary)
				.lineLimit(1)
			Text(entry.displaySubtitle ?? " ")
				.font(.system(size: 11))
				.foregroundColor(.secondary)
				.lineLimit(1)
			progressLine
		}
		.frame(width: width)
	}

	private var badges: some View {
		HStack(spacing: 4) {
			if entry.isFavorite {
				badge(systemImage: "heart.fill")
			}
			if let fraction = downloadFraction {
				stopButton(fraction: fraction)
			} else if entry.isRemote {
				badge(systemImage: "icloud.and.arrow.down")
			}
			Spacer()
			if entry.isRead {
				badge(systemImage: "checkmark")
			}
		}
		.padding(5)
	}

	private func badge(systemImage: String) -> some View {
		Image(systemName: systemImage)
			.font(.system(size: 9, weight: .semibold))
			.foregroundColor(.white)
			.padding(4)
			.background(Circle().fill(Color.black.opacity(0.55)))
	}

	/// Takes the cloud badge's place while a fetch runs: a progress ring you click to stop.
	private func stopButton(fraction: Double) -> some View {
		Button(action: onCancelDownload) {
			ZStack {
				Circle().fill(Color.black.opacity(0.6))
				Circle()
					.trim(from: 0, to: CGFloat(max(0.02, min(1, fraction))))
					.stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
					.rotationEffect(.degrees(-90))
					.padding(1.5)
				Image(systemName: "xmark")
					.font(.system(size: 8, weight: .bold))
					.foregroundColor(.white)
			}
			.frame(width: 21, height: 21)
		}
		.buttonStyle(PlainButtonStyle())
		.help(NSLocalizedString("Cancel the download", comment: "cover badge tooltip"))
	}

	@ViewBuilder
	private var progressLine: some View {
		if entry.pageCount > 0 && entry.lastReadPage > 0 && !entry.isRead {
			GeometryReader { geometry in
				ZStack(alignment: .leading) {
					Capsule().fill(Color(NSColor.quaternaryLabelColor))
					Capsule()
						.fill(Color.accentColor)
						.frame(width: geometry.size.width * CGFloat(entry.progress))
				}
			}
			.frame(height: 3)
		} else {
			Color.clear.frame(height: 3)
		}
	}
}

// MARK: - Cover image

/// Loads a cover off the main thread, decoded straight to the size it is drawn at, and
/// releases the bitmap when the cell scrolls away. Together with the bounded SCImageCache
/// that keeps a large grid from pinning every cover it has ever shown.
struct SCCoverImage: View {

	let url: URL?
	let maxPixel: CGFloat

	@State private var image: NSImage?
	/// What the cell currently wants. A decode that finishes after the cell scrolled away or
	/// moved on to another cover is dropped instead of pinning its bitmap.
	@State private var wanted: URL?

	var body: some View {
		Group {
			if let image = image {
				Image(nsImage: image)
					.resizable()
					.aspectRatio(contentMode: .fill)
			} else {
				Color.clear
			}
		}
		.onAppear { load(url) }
		// The grid gives every cell its own identity, so a new cover means a new view and
		// onAppear fires. The details pane reuses one view and only swaps the url, so the
		// reload has to be driven from here — with the URL the closure is handed, never the
		// one on `self`, which is a copy of the view as it was before the change.
		.onChange(of: url) { newURL in load(newURL) }
		.onDisappear {
			wanted = nil
			image = nil
		}
	}

	/// Loads `target`, which is passed in rather than read from `self` on purpose.
	///
	/// The previous version cleared `image` and then called a loader that began with
	/// `guard image == nil`. That read does not see the write that precedes it, so the guard
	/// bailed out every time and the pane only caught up on the *next* selection: it was
	/// permanently one comic behind.
	private func load(_ target: URL?) {
		wanted = target
		guard let target = target else {
			image = nil
			return
		}
		// Decoded in 128-pixel steps, so dragging the size slider reuses cached covers instead
		// of re-decoding every visible one at each notch.
		let pixel = (maxPixel / 128).rounded(.up) * 128
		let key = "\(target.path)#\(Int(pixel))"
		if let cached = SCImageCache.image(forKey: key) {
			image = cached
			return
		}
		image = nil
		DispatchQueue.global(qos: .userInitiated).async {
			guard let decoded = SCImageDownsampler.downsample(url: target, maxPixel: pixel) else { return }
			let nsImage = SCImageDownsampler.nsImage(decoded)
			SCImageCache.set(nsImage, forKey: key)
			DispatchQueue.main.async {
				guard self.wanted == target else { return }
				self.image = nsImage
			}
		}
	}
}

// MARK: - Details pane

struct SCLibraryDetailPane: View {

	@ObservedObject var store: SCLibraryStore
	@ObservedObject var controller: SCLibraryController
	@ObservedObject var state: SCLibraryUIState

	private var entry: SCLibraryEntry? {
		state.selectedID.flatMap { store.entry(id: $0) }
	}

	var body: some View {
		Group {
			if let entry = entry {
				details(for: entry)
			} else {
				VStack {
					Spacer()
					Text("No comic selected.")
						.foregroundColor(.secondary)
					Spacer()
				}
				.frame(maxWidth: .infinity)
			}
		}
		.background(Color(NSColor.windowBackgroundColor))
	}

	private func details(for entry: SCLibraryEntry) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					cover(for: entry)
					facts(for: entry)
					if !entry.stories.isEmpty {
						stories(for: entry)
					} else if let summary = entry.summary {
						section(NSLocalizedString("Summary", comment: "comic metadata section")) {
							Text(summary).font(.callout)
						}
					}
				}
				.padding(16)
			}
			Divider()
			actions(for: entry)
		}
	}

	private func cover(for entry: SCLibraryEntry) -> some View {
		HStack {
			Spacer(minLength: 0)
			SCCoverImage(url: entry.coverURL, maxPixel: 500)
				.id(entry.id)
				.frame(width: 170,
					   height: 170 / CGFloat(entry.coverAspect ?? Double(SCLibraryMetrics.defaultAspect)))
				.clipShape(RoundedRectangle(cornerRadius: SCLibraryMetrics.coverRadius, style: .continuous))
				.shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
			Spacer(minLength: 0)
		}
	}

	private func facts(for entry: SCLibraryEntry) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(entry.displayTitle).font(.title3).bold()
			if let subtitle = entry.displaySubtitle {
				Text(subtitle).foregroundColor(.secondary)
			}
			VStack(alignment: .leading, spacing: 3) {
				row(NSLocalizedString("Publisher", comment: "comic metadata"), entry.publisher)
				row(NSLocalizedString("Published", comment: "comic metadata"), entry.dateLabel)
				row(NSLocalizedString("Writer", comment: "comic metadata"), entry.writers)
				row(NSLocalizedString("Artist", comment: "comic metadata"), entry.pencillers)
				row(NSLocalizedString("Inker", comment: "comic metadata"), entry.inkers)
				row(NSLocalizedString("Pages", comment: "comic metadata"), "\(entry.pageCount)")
				row(NSLocalizedString("Progress", comment: "comic metadata"), progressLabel(for: entry))
				row(NSLocalizedString("File", comment: "comic metadata"),
					entry.sourceRelativePath ?? entry.title)
			}
			.padding(.top, 2)
		}
	}

	private func progressLabel(for entry: SCLibraryEntry) -> String? {
		guard entry.pageCount > 0 else { return nil }
		if entry.isRead { return NSLocalizedString("Read", comment: "reading progress") }
		if entry.lastReadPage == 0 { return NSLocalizedString("Unread", comment: "reading progress") }
		return String(format: NSLocalizedString("Page %d of %d", comment: "reading progress"),
					  entry.lastReadPage + 1, entry.pageCount)
	}

	private func stories(for entry: SCLibraryEntry) -> some View {
		section(NSLocalizedString("Contents", comment: "comic metadata section")) {
			VStack(alignment: .leading, spacing: 10) {
				ForEach(entry.stories) { story in
					VStack(alignment: .leading, spacing: 2) {
						HStack(alignment: .firstTextBaseline, spacing: 6) {
							Text("\(story.number).").foregroundColor(.secondary).font(.caption)
							Text(story.title).font(.callout).bold()
						}
						if !story.kind.isEmpty {
							Text(story.kind)
								.font(.caption2)
								.padding(.horizontal, 5).padding(.vertical, 1)
								.background(Capsule().fill(Color(NSColor.quaternaryLabelColor)))
						}
						if !story.credits.isEmpty {
							Text(story.credits.map { "\($0.role): \($0.name)" }.joined(separator: " · "))
								.font(.caption)
								.foregroundColor(.secondary)
						}
					}
				}
			}
		}
	}

	private func actions(for entry: SCLibraryEntry) -> some View {
		HStack(spacing: 8) {
			Button(NSLocalizedString("Open", comment: "details button")) {
				controller.open(entry)
			}
			Button(action: { store.update(id: entry.id) { $0.isFavorite.toggle() } }) {
				Image(systemName: entry.isFavorite ? "heart.fill" : "heart")
			}
			.help(NSLocalizedString("Favorite", comment: "details button"))
			Spacer()
			if entry.isFolderBacked {
				if entry.hasLocalArchive {
					Button(NSLocalizedString("Remove Download", comment: "details button")) {
						controller.evict(entry)
					}
				} else {
					Button(NSLocalizedString("Download", comment: "details button")) {
						controller.fetch(entry) { _ in }
					}
				}
			}
		}
		.padding(12)
	}

	@ViewBuilder
	private func row(_ label: String, _ value: String?) -> some View {
		if let value = value, !value.isEmpty {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Text(label)
					.font(.caption)
					.foregroundColor(.secondary)
					.frame(width: 72, alignment: .trailing)
				Text(value).font(.caption)
			}
		}
	}

	private func section<Content: View>(_ title: String,
										@ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title)
				.font(.caption)
				.foregroundColor(.secondary)
			content()
		}
	}
}
