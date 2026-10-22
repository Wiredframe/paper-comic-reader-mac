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
			Divider()
			Button("Zoom In") { NSApp.sendAction(#selector(PageCanvasView.zoomIn(_:)), to: nil, from: nil) }
				.keyboardShortcut("+")
				.disabled(session == nil)
			Button("Zoom Out") { NSApp.sendAction(#selector(PageCanvasView.zoomOut(_:)), to: nil, from: nil) }
				.keyboardShortcut("-")
				.disabled(session == nil)
			Button("Actual Size") { NSApp.sendAction(#selector(PageCanvasView.zoomToActualFit(_:)), to: nil, from: nil) }
				.keyboardShortcut("0")
				.disabled(session == nil)
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
				.disabled(session == nil)
			Button("Last Page") { session?.last() }
				.keyboardShortcut(.downArrow, modifiers: .command)
				.disabled(session == nil)
			Divider()
			Button("Bookmark Page") { session?.toggleBookmark() }
				.keyboardShortcut("d")
				.disabled(session?.phase != .ready)
			Divider()
			Button("Back to Library") { window?.leaveReader?() }
				.keyboardShortcut("l", modifiers: [.command, .shift])
				.disabled(window?.leaveReader == nil)
			Button("New Library Tab") { window?.openInNewTab(nil) }
				.keyboardShortcut("t")
		}
	}

	private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<ReaderSettings, Value>) -> Binding<Value> {
		Binding(get: { model.reader[keyPath: keyPath] }, set: { model.reader[keyPath: keyPath] = $0 })
	}
}
