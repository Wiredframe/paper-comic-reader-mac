//
//  RootView.swift
//  Paper Comic Reader
//
//  One window: the library, which turns into the reader when a comic is opened and back again
//  when the reader leaves. More comics open as tabs of the same window (native window tabbing),
//  each tab its own library-or-reader.
//

import SwiftUI
import SwiftData

struct RootView: View {
	/// The comic this window was opened for, nil for a library window.
	let requested: UUID?

	@Environment(AppModel.self) private var model
	@Environment(\.openWindow) private var openWindow
	@State private var session: ReaderSession?
	@State private var didStart = false

	var body: some View {
		Group {
			if let session {
				ReaderView(session: session, onLeave: leaveReader)
					.id(session.id)
			} else {
				LibraryView(onOpen: open)
			}
		}
		.frame(minWidth: 640, minHeight: 480)
		.background(WindowConfigurator())
		.onAppear(perform: start)
		.alert(model.message?.title ?? "",
			   isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } }),
			   presenting: model.message) { _ in
			Button("OK") { model.message = nil }
		} message: { message in
			Text(message.text)
		}
		.focusedSceneValue(\.windowActions, WindowActions(openInNewTab: { openWindow(id: "main", value: $0) },
														  leaveReader: session == nil ? nil : leaveReader))
	}

	private func start() {
		guard !didStart else { return }
		didStart = true
		if model.openWindow == nil {
			model.openWindow = { id in openWindow(id: "main", value: id) }
		}
		var queue = model.pendingOpen
		model.pendingOpen = []
		if let requested { queue.insert(requested, at: 0) }
		#if DEBUG
		// Development only: `-debugOpenComic <uuid>` opens a comic at launch, so the reader can
		// be checked from a script without clicking.
		if let id = UserDefaults.standard.string(forKey: "debugOpenComic").flatMap(UUID.init) {
			queue.insert(id, at: 0)
		}
		#endif
		guard let first = queue.first else { return }
		if let book = model.book(id: first) { open(book, nil) }
		queue.dropFirst().forEach { openWindow(id: "main", value: $0) }
	}

	private func open(_ book: ComicBook, _ page: Int?) {
		session?.close()
		session = ReaderSession(book: book, initialPage: page, model: model)
	}

	private func leaveReader() {
		session?.close()
		session = nil
	}
}

/// What the menu commands can do to the frontmost window.
struct WindowActions {
	var openInNewTab: (UUID?) -> Void
	var leaveReader: (() -> Void)?
}

struct WindowActionsKey: FocusedValueKey {
	typealias Value = WindowActions
}

extension FocusedValues {
	var windowActions: WindowActions? {
		get { self[WindowActionsKey.self] }
		set { self[WindowActionsKey.self] = newValue }
	}
}

/// Lets new windows join the current one as tabs, as Finder and Safari windows do.
private struct WindowConfigurator: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async {
			guard let window = view.window else { return }
			window.tabbingMode = .preferred
			window.tabbingIdentifier = "PaperComicReader"
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {}
}

extension AppModel {
	func book(id: UUID) -> ComicBook? {
		var descriptor = FetchDescriptor<ComicBook>(predicate: #Predicate { $0.id == id })
		descriptor.fetchLimit = 1
		return try? context.fetch(descriptor).first
	}
}
