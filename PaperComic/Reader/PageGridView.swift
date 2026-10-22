//
//  PageGridView.swift
//  Paper Comic Reader
//
//  Every page of the comic as a thumbnail, the current ones marked, bookmarked ones flagged.
//  Picking one jumps there.
//

import SwiftUI

struct PageGridView: View {
	let session: ReaderSession
	let onPick: (Int) -> Void

	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text(session.book.displayTitle).font(.headline)
				Spacer()
				Button("Done") { dismiss() }
					.keyboardShortcut(.cancelAction)
			}
			.padding()
			Divider()
			ScrollViewReader { proxy in
				ScrollView {
					LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 16)], spacing: 18) {
						ForEach(0..<session.pageCount, id: \.self) { page in
							PageThumbnail(session: session, page: page,
										  isCurrent: session.visiblePages.contains(page),
										  isBookmarked: session.book.bookmarks.contains { $0.pageIndex == page })
								.id(page)
								.onTapGesture { onPick(page) }
						}
					}
					.padding(20)
				}
				.onAppear { proxy.scrollTo(session.currentPage, anchor: .center) }
			}
		}
	}
}

private struct PageThumbnail: View {
	let session: ReaderSession
	let page: Int
	let isCurrent: Bool
	let isBookmarked: Bool

	@State private var image: CGImage?

	var body: some View {
		VStack(spacing: 4) {
			ZStack(alignment: .topTrailing) {
				Group {
					if let image {
						Image(decorative: image, scale: 1).resizable().scaledToFit()
					} else {
						Rectangle().fill(.quaternary).aspectRatio(0.66, contentMode: .fit)
					}
				}
				.frame(height: 160)
				.overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: isCurrent ? 3 : 0))
				if isBookmarked {
					Image(systemName: "bookmark.fill")
						.foregroundStyle(Color.accentColor)
						.padding(4)
				}
			}
			Text("\(page + 1)")
				.font(.caption)
				.monospacedDigit()
				.foregroundStyle(isCurrent ? Color.accentColor : .secondary)
		}
		.contentShape(Rectangle())
		.task(id: page) {
			image = await session.store?.thumbnail(at: page, maxPixel: PageImageStore.gridThumbPixelSizes[1])
		}
	}
}
