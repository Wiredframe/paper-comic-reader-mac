//
//  AppCommands.swift
//  Paper Comic Reader
//
//  The menu bar. Reader commands act on the reader of the frontmost window and are disabled
//  while it shows the library.
//

import SwiftUI

struct AppCommands: Commands {
	let model: AppModel

	@FocusedValue(\.readerSession) private var session
	@FocusedValue(\.windowActions) private var window

	var body: some Commands {
		CommandGroup(after: .newItem) {
			Button("Import Comics…") { model.importComics() }
				.keyboardShortcut("o")
			Divider()
			Button("Choose Library Folder…") { model.chooseLibraryFolder() }
				.disabled(model.job != nil)
			Button("Scan Library Folder") { Task { await model.scanLibraryFolder() } }
				.keyboardShortcut("r")
				.disabled(model.job != nil || !LibrarySource.isConfigured)
			Divider()
			Button("Export Library…") { model.exportLibrary() }
				.disabled(model.job != nil)
			Button("Import Library Backup…") { model.importLibrary() }
				.disabled(model.job != nil)
		}

		CommandGroup(after: .toolbar) {
			Toggle("Two Pages", isOn: binding(\.doublePage))
				.keyboardShortcut("2", modifiers: [.command, .option])
			Toggle("Right to Left", isOn: binding(\.rightToLeft))
			Picker("Fit", selection: binding(\.fit)) {
				Text("Fit Page").tag(ReaderSettings.Fit.page)
				Text("Fit Width").tag(ReaderSettings.Fit.width)
			}
			.pickerStyle(.inline)
			Toggle("Fit Window to Pages", isOn: binding(\.fitWindow))
			Divider()
			Button("Zoom In") { session?.canvas.view?.zoomIn(nil) }
				.keyboardShortcut("+")
				.disabled(session?.phase != .ready)
			Button("Zoom Out") { session?.canvas.view?.zoomOut(nil) }
				.keyboardShortcut("-")
				.disabled(session?.phase != .ready)
			Button("Actual Size") { session?.canvas.view?.zoomToActualFit(nil) }
				.keyboardShortcut("0")
				.disabled(session?.phase != .ready)
			Divider()
			Toggle("Paper Effect", isOn: Binding(get: { model.paper.isEnabled }, set: { model.paper.isEnabled = $0 }))
				.keyboardShortcut("p", modifiers: [.command, .shift])
			Toggle("Live Text", isOn: binding(\.liveText))
			Divider()
		}

		CommandMenu("Go") {
			Button("Next Page") { session?.next() }
				.keyboardShortcut(.rightArrow, modifiers: .command)
				.disabled(!(session?.canGoNext ?? false))
			Button("Previous Page") { session?.previous() }
				.keyboardShortcut(.leftArrow, modifiers: .command)
				.disabled(!(session?.canGoPrevious ?? false))
			Button("First Page") { session?.first() }
				.keyboardShortcut(.upArrow, modifiers: .command)
				.disabled(session?.phase != .ready || !(session?.canGoPrevious ?? false))
			Button("Last Page") { session?.last() }
				.keyboardShortcut(.downArrow, modifiers: .command)
				.disabled(session?.phase != .ready || !(session?.canGoNext ?? false))
			Divider()
			Button("Bookmark Page") { session?.toggleBookmark() }
				.keyboardShortcut("d")
				.disabled(session?.phase != .ready)
			Divider()
			Button("Back to Library") { window?.leaveReader?() }
				.keyboardShortcut("l", modifiers: [.command, .shift])
				.disabled(window?.leaveReader == nil)
			Button("New Library Tab") { window?.newTab() }
				.keyboardShortcut("t")
		}

		// No help book: the item would only say that help isn't available. The landing page is
		// where help lives.
		CommandGroup(replacing: .help) {
			Link("Paper Comic Reader Website",
				 destination: URL(string: "https://wiredframe.github.io/paper-comic-reader-landingpage/")!)
		}
	}

	private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<ReaderSettings, Value>) -> Binding<Value> {
		Binding(get: { model.reader[keyPath: keyPath] }, set: { model.reader[keyPath: keyPath] = $0 })
	}
}
