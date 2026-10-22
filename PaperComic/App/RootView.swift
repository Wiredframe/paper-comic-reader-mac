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
	@Environment(AppModel.self) private var model
	@Environment(\.openWindow) private var openWindow
	@State private var session: ReaderSession?
	@State private var didStart = false
	@State private var window: NSWindow?

	var body: some View {
		Group {
			if let session {
				ReaderView(session: session, onLeave: leaveReader)
					.id(ObjectIdentifier(session))
			} else {
				LibraryView(onOpen: open)
			}
		}
		.frame(minWidth: 640, minHeight: 480)
		.background(WindowConfigurator { window = $0 })
		.onChange(of: model.pendingOpen) { _, pending in
			guard model.frontWindowMayTakePending, !pending.isEmpty, session == nil,
				  let window, window == (NSApp.keyWindow ?? NSApp.mainWindow) else { return }
			takePending()
		}
		.onAppear(perform: start)
		// The reader writes its progress when it leaves: back to the library, or the window closing.
		.onDisappear { session?.close() }
		.onChange(of: model.removedBookIDs) { _, removed in
			if let session, removed.contains(session.book.id) { leaveReader() }
		}
		.onChange(of: model.downloads.failure?.id) { _, id in
			// A download started from the library failed; a reader explains its own.
			guard session == nil, let id, let failure = model.downloads.failure, failure.id == id else { return }
			model.downloads.clearFailure(for: id)
			model.show(String(localized: "“\(failure.book.displayTitle)” couldn’t be downloaded"),
					   ReaderSession.describe(failure.error))
		}
		.alert(model.message?.title ?? "",
			   isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } }),
			   presenting: model.message) { _ in
			Button("OK") { model.message = nil }
		} message: { message in
			Text(message.text)
		}
		.confirmationDialog("Your library couldn’t be opened",
							isPresented: Binding(get: { model.offersRecovery }, set: { _ in }),
							titleVisibility: .visible) {
			Button("Restore from Safety Copy") { model.recover(restore: true) }
			Button("Start with an Empty Library", role: .destructive) { model.recover(restore: false) }
		} message: {
			Text("The library file was damaged and has been set aside, not deleted. Paper Comic keeps a safety copy of your reading progress, favorites and bookmarks, and can rebuild the library from it.")
		}
		.focusedSceneValue(\.windowActions, WindowActions(newTab: { openWindow(id: "main") },
														  leaveReader: session == nil ? nil : leaveReader))
	}

	/// The first window hands SwiftUI's openWindow to the model, and every new window takes the
	/// next comic waiting to be opened.
	private func start() {
		guard !didStart else { return }
		didStart = true
		if model.openWindow == nil {
			model.openWindow = { openWindow(id: "main") }
		}
		#if DEBUG
		// Development only: `-debugOpenComic <uuid>` opens a comic at launch, so the reader can
		// be checked from a script without clicking.
		if let id = UserDefaults.standard.string(forKey: "debugOpenComic").flatMap(UUID.init),
		   let book = model.book(id: id) {
			open(book, nil)
			return
		}
		#endif
		takePending()
	}

	private func takePending() {
		guard !model.pendingOpen.isEmpty else { return }
		let id = model.pendingOpen.removeFirst()
		if let book = model.book(id: id) { open(book, nil) }
		// One window per comic: the rest open in tabs of their own.
		if !model.pendingOpen.isEmpty { openWindow(id: "main") }
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
	var newTab: () -> Void
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

/// Lets new windows join the current one as tabs, as Finder and Safari windows do, and hands
/// the window to the view that hosts it.
private struct WindowConfigurator: NSViewRepresentable {
	let onWindow: (NSWindow) -> Void

	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async {
			guard let window = view.window else { return }
			window.tabbingMode = .preferred
			window.tabbingIdentifier = "PaperComicReader"
			onWindow(window)
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
