//
//  ComicDetailPane.swift
//  Paper Comic Reader
//
//  The inspector beside the grid: the selected comic's cover, what its ComicInfo says, its
//  contents and where the reader is in it.
//

import SwiftUI

struct ComicDetailPane: View {
	let book: ComicBook?
	let onOpen: (ComicBook) -> Void

	@Environment(AppModel.self) private var model

	var body: some View {
		if let book {
			VStack(spacing: 0) {
				ComicInfoPanel(book: book)
				Divider()
				actions(book)
			}
		} else {
			ContentUnavailableView("No Comic Selected", systemImage: "book.closed")
		}
	}

	private func actions(_ book: ComicBook) -> some View {
		HStack(spacing: 8) {
			Button("Open") { onOpen(book) }
				.keyboardShortcut(.defaultAction)
			Button { model.toggleFavorite(book) } label: {
				Image(systemName: book.isFavorite ? "heart.fill" : "heart")
			}
			.help("Favorite")
			Spacer()
			if book.isFolderBacked {
				if let ticket = model.downloads.ticket(for: book.id) {
					DownloadRing(ticket: ticket) { model.downloads.cancel(book.id) }
				} else if book.isRemote {
					Button("Download") { model.downloads.start(book, in: model.context) }
				} else {
					Button("Remove Download") { model.evict(book) }
				}
			}
		}
		.padding(12)
	}
}

/// What a comic's ComicInfo says, its contents and where the reader is in it. Shown in the
/// library's inspector and in the reader's info popover.
struct ComicInfoPanel: View {
	let book: ComicBook

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				cover
				facts
				if !book.stories.isEmpty {
					stories
				} else if let summary = book.summary?.nonEmpty {
					section("Summary") { Text(summary).font(.callout).textSelection(.enabled) }
				}
				if let notes = book.notes?.nonEmpty {
					Text(notes).font(.caption2).foregroundStyle(.tertiary)
				}
			}
			.padding(16)
		}
	}

	private var cover: some View {
		HStack {
			Spacer(minLength: 0)
			CoverImage(url: book.coverURL, maxPixel: 500)
				.frame(width: 170, height: 170 / CGFloat(book.coverAspect ?? Double(LibraryMetrics.defaultAspect)))
				.background(.quaternary)
				.clipShape(RoundedRectangle(cornerRadius: LibraryMetrics.coverRadius, style: .continuous))
				.shadow(color: .black.opacity(0.3), radius: 6, y: 3)
			Spacer(minLength: 0)
		}
	}

	private var facts: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(book.displayTitle).font(.title3).bold()
			if let subtitle = book.displaySubtitle {
				Text(subtitle).foregroundStyle(.secondary)
			}
			Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
				row("Series", book.series)
				row("Issue", book.issueNumber)
				row("Publisher", book.publisher)
				row("Published", book.dateLabel)
				row("Writer", book.writers)
				row("Artist", book.pencillers)
				row("Inker", book.inkers)
				row("Characters", book.characters)
				row("Pages", book.pageCount > 0 ? "\(book.pageCount)" : nil)
				row("Progress", progress)
				row("Opened", book.openCount > 0 ? book.openCountLabel : nil)
				row("File", book.sourceRelativePath ?? book.title)
			}
			.padding(.top, 2)
			if let web = book.webURL?.nonEmpty, let url = URL(string: web) {
				Link(destination: url) { Label("More on the web", systemImage: "safari") }
					.font(.caption)
			}
		}
	}

	private var progress: String? {
		guard book.pageCount > 0 else { return nil }
		if book.isRead { return String(localized: "Read") }
		if book.lastReadPage == 0 { return String(localized: "Unread") }
		return String(localized: "Page \(book.lastReadPage + 1) of \(book.pageCount)")
	}

	private var stories: some View {
		section("Contents") {
			VStack(alignment: .leading, spacing: 10) {
				ForEach(Array(book.stories.enumerated()), id: \.offset) { _, story in
					VStack(alignment: .leading, spacing: 2) {
						HStack(alignment: .firstTextBaseline, spacing: 6) {
							Text("\(story.number).").foregroundStyle(.secondary).font(.caption)
							Text(story.title).font(.callout).bold()
						}
						if !story.kind.isEmpty {
							Text(story.kind)
								.font(.caption2)
								.padding(.horizontal, 5).padding(.vertical, 1)
								.background(Capsule().fill(.quaternary))
						}
						if !story.credits.isEmpty {
							Text(story.credits.map { "\($0.role): \($0.name)" }.joined(separator: " · "))
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					}
				}
			}
		}
	}

	@ViewBuilder
	private func row(_ label: LocalizedStringKey, _ value: String?) -> some View {
		if let value, !value.isEmpty {
			GridRow {
				Text(label)
					.font(.caption)
					.foregroundStyle(.secondary)
					.gridColumnAlignment(.trailing)
				Text(value).font(.caption).textSelection(.enabled)
			}
		}
	}

	private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title).font(.caption).foregroundStyle(.secondary)
			content()
		}
	}
}
