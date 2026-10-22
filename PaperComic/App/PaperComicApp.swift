//
//  PaperComicApp.swift
//  Paper Comic Reader
//
//  The app: one kind of window (library or reader, tabbed), Settings, and the menus.
//

import SwiftUI

@main
struct PaperComicApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

	var body: some Scene {
		WindowGroup(id: "main", for: UUID.self) { $comic in
			RootView(requested: comic)
				.environment(appDelegate.model)
				.environment(appDelegate.model.paper)
				.modelContainer(appDelegate.model.container)
		}
		.defaultSize(width: 1180, height: 820)
		.commands { AppCommands(model: appDelegate.model) }

		Settings {
			SettingsView()
				.environment(appDelegate.model)
				.modelContainer(appDelegate.model.container)
		}
	}
}

/// AppKit's side of the app: files opened from the Finder, and quitting.
final class AppDelegate: NSObject, NSApplicationDelegate {

	@MainActor lazy var model = AppModel()

	@MainActor
	func application(_ application: NSApplication, open urls: [URL]) {
		model.openExternal(urls)
	}

	@MainActor
	func applicationWillTerminate(_ notification: Notification) {
		model.prepareToQuit()
	}

	@MainActor
	func applicationDidResignActive(_ notification: Notification) {
		model.saveSnapshot()
	}
}
