//
//  BookmarksView.swift
//  Paper Comic Reader
//
//  Every bookmark in the library, newest first, as the page it marks. A click opens the comic
//  on that page. Like the iOS app's Bookmarks tab.
//

import SwiftUI
import SwiftData

struct BookmarksView: View {
	let search: String
	let onOpen: (ComicBook, Int?) -> Void

	@Environment(AppModel.self) private var model
	@Query(sort: \Bookmark.dateAdded, order: .reverse) private var bookmarks: [Bookmark]

	private var visible: [Bookmark] {
		bookmarks.filter { $0.book != nil && $0.matches(searchQuery: search) }
	}

	var body: some View {
		if bookmarks.isEmpty {
			ContentUnavailableView("No Bookmarks",
								   systemImage: "bookmark",
								   description: Text("Bookmark a page while reading, and it shows up here."))
		} else if visible.isEmpty {
			ContentUnavailableView.search(text: search)
		} else {
			ScrollView {
				LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: LibraryMetrics.spacing, alignment: .top)],
						  spacing: LibraryMetrics.spacing) {
					ForEach(visible) { mark in
						card(mark)
					}
				}
				.padding(LibraryMetrics.spacing)
			}
		}
	}

	private func card(_ mark: Bookmark) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			CoverImage(url: mark.thumbURL, maxPixel: 400)
				.frame(width: 170, height: 170 / CGFloat(mark.pageAspect ?? Double(LibraryMetrics.defaultAspect)))
				.background(.quaternary)
				.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
				.shadow(color: .black.opacity(0.25), radius: 4, y: 2)
			Text(mark.book?.displayTitle ?? "")
				.font(.system(size: 12, weight: .medium))
				.lineLimit(1)
			Text(mark.storyLabel.map { "\(mark.pageLabel) · \($0)" } ?? mark.pageLabel)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.frame(width: 170)
		.contentShape(Rectangle())
		.onTapGesture(count: 2) {
			if let book = mark.book { onOpen(book, mark.pageIndex) }
		}
		.contextMenu {
			Button("Open") { if let book = mark.book { onOpen(book, mark.pageIndex) } }
			Button("Remove Bookmark", role: .destructive) {
				try? Storage.fm.removeItem(at: mark.thumbURL)
				model.context.delete(mark)
				try? model.context.save()
			}
		}
	}
}
