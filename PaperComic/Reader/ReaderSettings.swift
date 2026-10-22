//
//  ReaderSettings.swift
//  Paper Comic Reader
//
//  How the reader lays pages out, persisted in UserDefaults. The iOS app has its own set for a
//  touch screen; these are the ones a Mac window needs.
//

import Foundation
import Observation

@MainActor
@Observable
final class ReaderSettings {

	/// Two pages side by side, the cover alone, as a printed comic opens.
	var doublePage: Bool { didSet { defaults.set(doublePage, forKey: K.doublePage) } }
	/// Manga order: the next page is on the left.
	var rightToLeft: Bool { didSet { defaults.set(rightToLeft, forKey: K.rightToLeft) } }
	/// Whole page in the window, or as wide as the window with the rest scrolling.
	var fit: Fit { didSet { defaults.set(fit.rawValue, forKey: K.fit) } }
	/// Text on a page can be selected and looked up (VisionKit Live Text).
	var liveText: Bool { didSet { defaults.set(liveText, forKey: K.liveText) } }
	/// The window takes the full screen height and the width of the page or spread, as Simple
	/// Comic's did, so no margin is left beside the pages. Only while fitting the whole page.
	var fitWindow: Bool { didSet { defaults.set(fitWindow, forKey: K.fitWindow) } }
	/// A click on the left or right third of the page turns it.
	var clickToTurn: Bool { didSet { defaults.set(clickToTurn, forKey: K.clickToTurn) } }

	enum Fit: String, CaseIterable, Identifiable {
		case page
		case width
		var id: String { rawValue }
	}

	private let defaults: UserDefaults

	private enum K {
		static let doublePage = "reader.doublePage"
		static let rightToLeft = "reader.rightToLeft"
		static let fit = "reader.fit"
		static let liveText = "reader.liveText"
		static let clickToTurn = "reader.clickToTurn"
		static let fitWindow = "reader.fitWindow"
	}

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		doublePage = defaults.object(forKey: K.doublePage) as? Bool ?? true
		rightToLeft = defaults.object(forKey: K.rightToLeft) as? Bool ?? false
		fit = Fit(rawValue: defaults.string(forKey: K.fit) ?? "") ?? .page
		liveText = defaults.object(forKey: K.liveText) as? Bool ?? true
		clickToTurn = defaults.object(forKey: K.clickToTurn) as? Bool ?? true
		fitWindow = defaults.object(forKey: K.fitWindow) as? Bool ?? true
	}
}
