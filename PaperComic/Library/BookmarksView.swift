//
//  BookmarksView.swift
//  Paper Comic Reader
//
//  Every bookmark in the library, newest first, as the page it marks. Selected with a click or
//  the arrow keys like the comics, and opened with a double click or Return on its page. Like
//  the iOS app's Bookmarks tab.
//

import SwiftUI
import SwiftData

struct BookmarksView: View {
	let search: String
	@Binding var selection: UUID?
	let onOpen: (ComicBook, Int?) -> Void

	@Environment(AppModel.self) private var model
	@Query(sort: \Bookmark.dateAdded, order: .reverse) private var bookmarks: [Bookmark]
	@State private var hovered: UUID?
	@State private var columns = 1
	@FocusState private var focused: Bool

	private static let cardWidth: CGFloat = 170

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
			grid(visible)
		}
	}

	private func grid(_ marks: [Bookmark]) -> some View {
		GeometryReader { geometry in
			ScrollViewReader { proxy in
				ScrollView {
					LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cardWidth), spacing: LibraryMetrics.spacing, alignment: .top)],
							  spacing: LibraryMetrics.spacing) {
						ForEach(marks) { mark in
							card(mark)
								.id(mark.id)
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
		}
		.focusable()
		.focusEffectDisabled()
		.focused($focused)
		.onKeyPress(.leftArrow) { move(-1, in: marks) }
		.onKeyPress(.rightArrow) { move(1, in: marks) }
		.onKeyPress(.upArrow) { move(-columns, in: marks) }
		.onKeyPress(.downArrow) { move(columns, in: marks) }
		.onKeyPress(.return) {
			guard let mark = marks.first(where: { $0.id == selection }), let book = mark.book else { return .ignored }
			onOpen(book, mark.pageIndex)
			return .handled
		}
	}

	private func card(_ mark: Bookmark) -> some View {
		let isSelected = selection == mark.id
		let isHovered = hovered == mark.id
		return VStack(alignment: .leading, spacing: 4) {
			CoverImage(url: mark.thumbURL, maxPixel: 400)
				.frame(width: Self.cardWidth, height: Self.cardWidth / CGFloat(mark.pageAspect ?? Double(LibraryMetrics.defaultAspect)))
				.background(.quaternary)
				.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
				.overlay(
					RoundedRectangle(cornerRadius: 6, style: .continuous)
						.strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
				)
				.shadow(color: .black.opacity(isHovered ? 0.35 : 0.25), radius: isHovered ? 9 : 4, y: isHovered ? 5 : 2)
				.scaleEffect(isHovered ? 1.02 : 1)
				.animation(.easeOut(duration: 0.12), value: isHovered)
			Text(mark.book?.displayTitle ?? "")
				.font(.system(size: 12, weight: .medium))
				.foregroundStyle(isSelected ? Color.accentColor : Color.primary)
				.lineLimit(1)
			Text(mark.storyLabel.map { "\(mark.pageLabel) · \($0)" } ?? mark.pageLabel)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.frame(width: Self.cardWidth)
		.overlay {
			CellMouse(onSelect: { select(mark.id) },
					  onOpen: { if let book = mark.book { onOpen(book, mark.pageIndex) } },
					  onHover: { inside in
						  if inside { hovered = mark.id } else if hovered == mark.id { hovered = nil }
					  })
		}
		.contextMenu {
			Button("Open") { if let book = mark.book { onOpen(book, mark.pageIndex) } }
			if let book = mark.book {
				Button("Open in New Tab") { model.openInNewTab(book.id) }
			}
			Divider()
			Button("Remove Bookmark", role: .destructive) {
				if selection == mark.id { selection = nil }
				try? Storage.fm.removeItem(at: mark.thumbURL)
				model.context.delete(mark)
				try? model.context.save()
			}
		}
	}

	private func select(_ id: UUID) {
		selection = id
		focused = true
	}

	private func columnCount(forWidth width: CGFloat) -> Int {
		let usable = width - LibraryMetrics.spacing * 2
		let step = Self.cardWidth + LibraryMetrics.spacing
		return max(1, Int((usable + LibraryMetrics.spacing) / step))
	}

	private func move(_ offset: Int, in marks: [Bookmark]) -> KeyPress.Result {
		guard !marks.isEmpty else { return .ignored }
		guard let current = selection, let index = marks.firstIndex(where: { $0.id == current }) else {
			selection = marks.first?.id
			return .handled
		}
		selection = marks[min(max(index + offset, 0), marks.count - 1)].id
		return .handled
	}
}
