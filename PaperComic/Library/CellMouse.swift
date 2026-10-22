//
//  CellMouse.swift
//  Paper Comic Reader
//
//  Native mouse handling for one cover in the library grid: select on mouse-down, open on
//  the second click, highlight on hover.
//
//  This is AppKit rather than SwiftUI gestures because SwiftUI cannot express what a Finder
//  icon does. A `.onTapGesture` next to an `.onTapGesture(count: 2)` has to wait out
//  `NSEvent.doubleClickInterval` (half a second) before it can tell the two apart, and that
//  wait is plainly felt. A zero-distance `DragGesture` reports immediately but wins the
//  gesture race, which kills the double click. AppKit has had the answer since the beginning:
//  one `mouseDown:` carrying a `clickCount`. Nothing has to be disambiguated, so nothing has
//  to be waited for.
//
//  Hover rides along in the same view, through a tracking area, which is also what AppKit
//  does natively.
//

import SwiftUI

struct CellMouse: NSViewRepresentable {

	let onSelect: () -> Void
	let onOpen: () -> Void
	let onHover: (Bool) -> Void

	func makeNSView(context: Context) -> MouseView {
		let view = MouseView()
		apply(to: view)
		return view
	}

	func updateNSView(_ nsView: MouseView, context: Context) {
		apply(to: nsView)
	}

	private func apply(to view: MouseView) {
		view.onSelect = onSelect
		view.onOpen = onOpen
		view.onHover = onHover
	}

	final class MouseView: NSView {

		var onSelect: (() -> Void)?
		var onOpen: (() -> Void)?
		var onHover: ((Bool) -> Void)?

		private var trackingArea: NSTrackingArea?

		override func updateTrackingAreas() {
			super.updateTrackingAreas()
			if let trackingArea = trackingArea {
				removeTrackingArea(trackingArea)
			}
			let area = NSTrackingArea(rect: .zero,
									  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
									  owner: self,
									  userInfo: nil)
			addTrackingArea(area)
			trackingArea = area
		}

		override func mouseEntered(with event: NSEvent) { onHover?(true) }
		override func mouseExited(with event: NSEvent) { onHover?(false) }

		override func mouseDown(with event: NSEvent) {
			onSelect?()
			if event.clickCount == 2 {
				onOpen?()
			}
		}

		/// A click into a background window both activates it and lands, the way a Finder icon
		/// behaves, so no click is wasted.
		override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

		/// Right-clicks belong to the SwiftUI context menu on the cell behind this view, so the
		/// lookup is handed straight up the view hierarchy.
		override func menu(for event: NSEvent) -> NSMenu? {
			superview?.menu(for: event)
		}
	}
}
