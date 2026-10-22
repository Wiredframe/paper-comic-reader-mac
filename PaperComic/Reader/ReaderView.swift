//
//  ReaderView.swift
//  Paper Comic Reader
//
//  The reader inside the library window: the page canvas, the toolbar that takes over from the
//  library's, and a page bar along the bottom that shows itself while the pointer is near it.
//

import SwiftUI

struct ReaderView: View {
	@Bindable var session: ReaderSession
	let onLeave: () -> Void

	@Environment(AppModel.self) private var model
	@State private var showsPageBar = false
	@State private var showsPageGrid = false
	@State private var scrubPage: Double = 0

	private var settings: ReaderSettings { model.reader }

	var body: some View {
		ZStack(alignment: .bottom) {
			Color(nsColor: .underPageBackgroundColor).ignoresSafeArea()
			content
			if session.phase == .ready {
				pageBar
					.opacity(showsPageBar ? 1 : 0)
					.animation(.easeOut(duration: 0.15), value: showsPageBar)
			}
		}
		.onContinuousHover { phase in
			if case .active(let point) = phase {
				// The page bar shows while the pointer is in the bottom band of the window.
				showsPageBar = point.y > hoverHeight - 90
			} else {
				showsPageBar = false
			}
		}
		.background(GeometryReader { geometry in
			Color.clear.onAppear { hoverHeight = geometry.size.height }
				.onChange(of: geometry.size.height) { _, height in hoverHeight = height }
		})
		.task { await session.open() }
		.onChange(of: model.paper.isEnabled) { session.paperChanged() }
		.onChange(of: model.paper.params) { session.paperChanged() }
		.onChange(of: settings.doublePage) { session.layoutChanged() }
		.toolbar { toolbar }
		.navigationTitle(session.book.displayTitle)
		.navigationSubtitle(pageLabel)
		.sheet(isPresented: $showsPageGrid) {
			PageGridView(session: session) { page in
				session.go(to: page)
				showsPageGrid = false
			}
			.frame(minWidth: 640, minHeight: 520)
		}
		.focusedSceneValue(\.readerSession, session)
	}

	@State private var hoverHeight: CGFloat = 0

	@ViewBuilder
	private var content: some View {
		switch session.phase {
		case .ready:
			if let store = session.store {
				PageCanvas(store: store,
						   bridge: session.canvas,
						   state: PageCanvasState(pages: session.visiblePages,
												  generation: session.paperGeneration,
												  fit: settings.fit,
												  rightToLeft: settings.rightToLeft,
												  liveText: settings.liveText,
												  clickToTurn: settings.clickToTurn,
												  fitWindow: settings.fitWindow),
						   actions: PageCanvasActions(forward: { session.next() },
													  backward: { session.previous() },
													  first: { session.first() },
													  last: { session.last() },
													  toggleFit: toggleFit,
													  leave: onLeave))
			}
		case .loading:
			ProgressView()
		case .downloading:
			VStack(spacing: 12) {
				ProgressView(value: session.downloadProgress ?? 0)
					.frame(width: 220)
				Text("Downloading from the library folder…")
					.foregroundStyle(.secondary)
				Button("Stop") { model.downloads.cancel(session.book.id) }
			}
		case .failed(let message):
			ContentUnavailableView {
				Label("Can’t Open This Comic", systemImage: "exclamationmark.triangle")
			} description: {
				Text(message)
			} actions: {
				if session.book.isFolderBacked {
					Button("Try Again") { session.retry() }
						.buttonStyle(.borderedProminent)
					Button("Choose Library Folder…") {
						model.chooseLibraryFolder()
						session.retry()
					}
				}
				Button("Choose the Comic’s File…", action: chooseFile)
				Button("Back to Library", action: onLeave)
			}
		}
	}

	// MARK: Page bar

	private var pageBar: some View {
		// Laid out the way the pages are: in right-to-left order the next page, the slider's end
		// and the arrow that leads there are all on the left.
		let rtl = settings.rightToLeft
		return HStack(spacing: 12) {
			Button { rtl ? session.next() : session.previous() } label: { Image(systemName: "chevron.left") }
				.disabled(rtl ? !session.canGoNext : !session.canGoPrevious)
			Slider(value: Binding(get: { Double(rtl ? lastIndex - session.anchorPage : session.anchorPage) },
								  set: { value in
									  let page = Int(value.rounded())
									  session.go(to: rtl ? lastIndex - page : page)
								  }),
				   in: 0...Double(max(lastIndex, 1)))
			Button { rtl ? session.previous() : session.next() } label: { Image(systemName: "chevron.right") }
				.disabled(rtl ? !session.canGoPrevious : !session.canGoNext)
			Text(pageLabel)
				.monospacedDigit()
				.foregroundStyle(.secondary)
				.frame(minWidth: 90, alignment: .trailing)
		}
		.buttonStyle(.borderless)
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.padding(.horizontal, 40)
		.padding(.bottom, 16)
		.frame(maxWidth: 760)
	}

	private var lastIndex: Int { max(session.pageCount - 1, 0) }

	private var pageLabel: String {
		let pages = session.visiblePages.map { $0 + 1 }
		guard let first = pages.first else { return "" }
		if pages.count > 1 {
			return String(localized: "Pages \(first) and \(pages[1]) of \(session.pageCount)")
		}
		return String(localized: "Page \(first) of \(session.pageCount)")
	}

	// MARK: Toolbar

	@ToolbarContentBuilder
	private var toolbar: some ToolbarContent {
		ToolbarItem(placement: .navigation) {
			Button(action: onLeave) {
				Label("Library", systemImage: "chevron.backward")
			}
			.help("Back to the library")
		}
		ToolbarItemGroup(placement: .primaryAction) {
			Button { session.toggleBookmark() } label: {
				Label("Bookmark", systemImage: session.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
			}
			.help("Bookmark this page")
			.disabled(session.phase != .ready)

			Button { showsPageGrid = true } label: {
				Label("Pages", systemImage: "square.grid.3x3")
			}
			.help("Show all pages")
			.disabled(session.phase != .ready)

			Menu {
				Toggle("Two Pages", isOn: Binding(get: { settings.doublePage }, set: { settings.doublePage = $0 }))
				Toggle("Right to Left", isOn: Binding(get: { settings.rightToLeft }, set: { settings.rightToLeft = $0 }))
				Divider()
				Picker("Fit", selection: Binding(get: { settings.fit }, set: { settings.fit = $0 })) {
					Text("Fit Page").tag(ReaderSettings.Fit.page)
					Text("Fit Width").tag(ReaderSettings.Fit.width)
				}
				.pickerStyle(.inline)
				Divider()
				Toggle("Fit Window to Pages", isOn: Binding(get: { settings.fitWindow }, set: { settings.fitWindow = $0 }))
				Divider()
				Toggle("Live Text", isOn: Binding(get: { settings.liveText }, set: { settings.liveText = $0 }))
				Toggle("Click to Turn Pages", isOn: Binding(get: { settings.clickToTurn }, set: { settings.clickToTurn = $0 }))
			} label: {
				Label("Layout", systemImage: settings.doublePage ? "book" : "doc")
			}
			.help("Page layout")

			Toggle(isOn: Binding(get: { model.paper.isEnabled }, set: { model.paper.isEnabled = $0 })) {
				Label("Paper", systemImage: "doc.richtext")
			}
			.help("Paper effect")
		}
	}

	private func chooseFile() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = ComicFileTypes.all
		panel.allowsMultipleSelection = false
		panel.message = String(localized: "Choose the file of “\(session.book.displayTitle)”.")
		guard panel.runModal() == .OK, let url = panel.url else { return }
		session.relink(to: url)
	}

	private func toggleFit() {
		settings.fit = settings.fit == .page ? .width : .page
	}
}

// MARK: - Focused value

struct ReaderSessionKey: FocusedValueKey {
	typealias Value = ReaderSession
}

extension FocusedValues {
	var readerSession: ReaderSession? {
		get { self[ReaderSessionKey.self] }
		set { self[ReaderSessionKey.self] = newValue }
	}
}
