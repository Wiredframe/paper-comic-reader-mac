//
//  PageCanvas.swift
//  Paper Comic Reader
//
//  The pages on screen. AppKit rather than SwiftUI, because a comic page wants exactly what
//  NSScrollView already does well: pinch and keyboard zoom around the pointer, smooth scrolling
//  of a page wider or taller than the window, and a clip view that keeps a small page centred.
//
//  One or two page views sit side by side in a flipped document view. They share a height, so a
//  spread reads as one sheet, and the whole spread is scaled either to the window (fit page) or
//  to its width (fit width, the rest scrolls). Images come from PageImageStore, decoded and
//  papered off the main thread; a page without its image yet keeps its shape as a blank sheet.
//
//  Live Text (VisionKit) sits over each page when it is switched on: text can be selected,
//  looked up and copied, and a click anywhere else still turns the page.
//

import AppKit
import SwiftUI
import VisionKit

/// What the canvas shows, as plain values, so SwiftUI hands over a fresh one whenever anything
/// the reader depends on changes.
struct PageCanvasState: Equatable {
	var pages: [Int]
	var generation: Int
	var fit: ReaderSettings.Fit
	var rightToLeft: Bool
	var liveText: Bool
	var clickToTurn: Bool
	var fitWindow: Bool
}

/// The reader's moves, as the canvas asks for them. Directions are already in reading order:
/// `forward` is the next page whichever side it is on.
struct PageCanvasActions {
	var forward: () -> Void
	var backward: () -> Void
	var first: () -> Void
	var last: () -> Void
	var toggleFit: () -> Void
	var leave: () -> Void
}

/// Lets menu commands reach the canvas of a reader directly, rather than through the responder
/// chain, which loses it whenever something else holds the focus.
@MainActor
final class CanvasBridge {
	weak var view: PageCanvasView?
}

struct PageCanvas: NSViewRepresentable {
	let store: PageImageStore
	let bridge: CanvasBridge
	let state: PageCanvasState
	let actions: PageCanvasActions

	func makeNSView(context: Context) -> PageCanvasView {
		let view = PageCanvasView(store: store)
		bridge.view = view
		view.actions = actions
		view.apply(state)
		return view
	}

	func updateNSView(_ view: PageCanvasView, context: Context) {
		view.actions = actions
		view.apply(state)
	}

	static func dismantleNSView(_ view: PageCanvasView, coordinator: ()) {
		view.tearDown()
	}
}

// MARK: - Canvas

final class PageCanvasView: NSView {

	var actions: PageCanvasActions?

	private let store: PageImageStore
	private let scrollView = CenteringScrollView()
	private let spread = SpreadView()
	private var state: PageCanvasState?
	private var pageViews: [PageView] = []
	/// The shape of each page seen so far, so a page that is still decoding is laid out right.
	private var aspects: [Int: CGFloat] = [:]
	private var requests: [CancelFlag] = []

	init(store: PageImageStore) {
		self.store = store
		super.init(frame: .zero)
		aspects = store.knownAspects()

		scrollView.hasVerticalScroller = true
		scrollView.hasHorizontalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.scrollerStyle = .overlay
		scrollView.drawsBackground = false
		scrollView.allowsMagnification = true
		scrollView.minMagnification = 1
		scrollView.maxMagnification = 6
		scrollView.contentView = CenteringClipView()
		scrollView.contentView.drawsBackground = false
		scrollView.documentView = spread
		scrollView.autoresizingMask = [.width, .height]
		scrollView.frame = bounds
		addSubview(scrollView)

		spread.tracker.canvas = self
		(scrollView.contentView as? CenteringClipView)?.tracker = spread.tracker
		scrollView.onSwipe = { [weak self] forward in
			guard let self else { return }
			forward ? self.actions?.forward() : self.actions?.backward()
		}
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

	func tearDown() {
		requests.forEach { $0.cancel() }
		requests = []
		restoreWindowFrame()
	}

	// MARK: State

	func apply(_ new: PageCanvasState) {
		let old = state
		state = new
		let moved = old?.pages != new.pages
		let pagesChanged = moved || old?.generation != new.generation
		if pagesChanged || old?.rightToLeft != new.rightToLeft {
			showPages(new.pages, rightToLeft: new.rightToLeft, keepImages: !moved, prefetch: moved)
		}
		if old?.fitWindow == true, !new.fitWindow { restoreWindowFrame() }
		// A new paper look keeps the zoom and the place on the page; only a turn starts over.
		if moved || old?.fit != new.fit || old?.fitWindow != new.fitWindow || old?.rightToLeft != new.rightToLeft {
			// A new page starts at its top, unzoomed: carrying a zoom across a turn lands the
			// reader in the middle of a page they haven't seen yet.
			scrollView.magnification = 1
			layoutSpread()
			scrollToTop()
		}
		if old?.liveText != new.liveText || pagesChanged {
			pageViews.forEach { $0.setLiveText(new.liveText) }
		}
		// Back from the page grid or a toolbar click, the keys belong to the pages again.
		// Never from something inside the canvas, such as a Live Text selection waiting for ⌘C.
		if let window, let responder = window.firstResponder, responder !== self, !(responder is NSText),
		   !((responder as? NSView)?.isDescendant(of: self) ?? false) {
			window.makeFirstResponder(self)
		}
	}

	private func showPages(_ pages: [Int], rightToLeft: Bool, keepImages: Bool, prefetch: Bool) {
		requests.forEach { $0.cancel() }
		requests = []
		let ordered = rightToLeft ? Array(pages.reversed()) : pages
		// Reuse the views for the same pages so a re-render (paper changed) swaps the image in
		// place instead of flashing a blank sheet.
		var reusable = Dictionary(uniqueKeysWithValues: pageViews.map { ($0.page, $0) })
		pageViews.forEach { $0.removeFromSuperview() }
		pageViews = ordered.map { page in
			let view = reusable.removeValue(forKey: page) ?? PageView(page: page)
			spread.addSubview(view)
			return view
		}
		for view in pageViews {
			if let cached = store.cachedImage(at: view.page) {
				view.setImage(cached)
				remember(cached, for: view.page)
				continue
			}
			if !keepImages { view.setImage(nil) }
			let page = view.page
			if let flag = store.requestImage(at: page, completion: { [weak self, weak view] index, image in
				guard let self, let view, view.page == index, let image else { return }
				view.setImage(image)
				if self.remember(image, for: index) { self.layoutSpread() }
			}) {
				requests.append(flag)
			}
		}
		// Only after a turn. After a paper change the neighbours would each be rendered again,
		// and a slider drag would queue renders nobody waits for.
		guard prefetch else { return }
		if let last = pages.last { store.prefetch(around: last) }
		if let first = pages.first { store.prefetch(around: first) }
	}

	/// Notes a page's shape; true when it differs from what the layout assumed.
	@discardableResult
	private func remember(_ image: CGImage, for page: Int) -> Bool {
		guard image.height > 0 else { return false }
		let aspect = CGFloat(image.width) / CGFloat(image.height)
		defer { aspects[page] = aspect }
		guard let known = aspects[page] else { return true }
		return abs(known - aspect) > 0.001
	}

	// MARK: Layout

	override func layout() {
		super.layout()
		scrollView.frame = bounds
		layoutSpread()
	}

	/// Sizes the spread for the window at magnification 1. Pages share a height; their widths
	/// follow their own shapes.
	private func layoutSpread() {
		guard let state else { return }
		// The window's size, not the clip view's bounds: those shrink as the page is magnified,
		// and the spread is always laid out for magnification 1.
		let visible = scrollView.contentSize
		guard visible.width > 1, visible.height > 1, !pageViews.isEmpty else { return }

		let shapes = pageViews.map { aspects[$0.page] ?? 0.66 }
		let unitWidth = shapes.reduce(0, +)   // total width at height 1
		let height: CGFloat
		switch state.fit {
		case .page:
			height = min(visible.height, visible.width / unitWidth)
		case .width:
			height = visible.width / unitWidth
		}
		var x: CGFloat = 0
		for (view, shape) in zip(pageViews, shapes) {
			let width = (height * shape).rounded()
			view.frame = NSRect(x: x, y: 0, width: width, height: height.rounded())
			x += width
		}
		spread.frame = NSRect(x: 0, y: 0, width: x, height: height.rounded())
		// After this layout pass, not inside it: resizing the window lays the canvas out again.
		pendingUnitWidth = unitWidth
		if !fitScheduled {
			fitScheduled = true
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				self.fitScheduled = false
				self.fitWindowToSpread(unitWidth: self.pendingUnitWidth)
			}
		}
	}

	private var pendingUnitWidth: CGFloat = 0
	private var fitScheduled = false
	/// Kept from the moment the canvas joins a window, because by the time SwiftUI dismantles
	/// it the view may already have left the window whose frame has to be given back.
	private weak var hostWindow: NSWindow?

	// MARK: Window fitted to the pages

	/// The window's frame before the reader first fitted it, given back when the reader leaves.
	private var savedWindowFrame: NSRect?

	/// Makes the window the full height of the screen and exactly as wide as the spread at that
	/// height, keeping its left edge where it is (moved left only if it would run off the screen).
	/// The same rule Simple Comic used. Not in full screen, and not while fitting the width, where
	/// the window's width is the reader's choice.
	private func fitWindowToSpread(unitWidth: CGFloat) {
		guard let state, state.fitWindow, state.fit == .page, unitWidth > 0,
			  let window = hostWindow, let screen = window.screen ?? NSScreen.main,
			  !window.styleMask.contains(.fullScreen), window.inLiveResize == false,
			  // Tabs share one frame: fitting it to a comic would squeeze the library tabs too.
			  (window.tabbedWindows?.count ?? 1) <= 1 else { return }
		let visible = screen.visibleFrame
		let chromeHeight = window.frame.height - window.contentLayoutRect.height
		let chromeWidth = window.frame.width - window.contentLayoutRect.width
		let contentHeight = visible.height - chromeHeight
		guard contentHeight > 100 else { return }
		var width = (contentHeight * unitWidth).rounded() + chromeWidth
		width = min(max(width, window.minSize.width), visible.width)
		var x = window.frame.minX
		if x + width > visible.maxX { x = visible.maxX - width }
		x = max(x, visible.minX)
		let target = NSRect(x: x, y: visible.minY, width: width, height: visible.height)
		guard abs(target.width - window.frame.width) > 1 || abs(target.height - window.frame.height) > 1
				|| abs(target.minX - window.frame.minX) > 1 || abs(target.minY - window.frame.minY) > 1 else { return }
		if savedWindowFrame == nil { savedWindowFrame = window.frame }
		window.setFrame(target, display: true, animate: false)
	}

	private func restoreWindowFrame() {
		guard let frame = savedWindowFrame, let window = hostWindow else { return }
		savedWindowFrame = nil
		guard !window.styleMask.contains(.fullScreen) else { return }
		window.setFrame(frame, display: true, animate: false)
	}

	private func scrollToTop() {
		let clip = scrollView.contentView
		clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: .zero, size: clip.bounds.size)).origin)
		scrollView.reflectScrolledClipView(clip)
	}

	// MARK: Keyboard

	override var acceptsFirstResponder: Bool { true }

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if let window { hostWindow = window }
		window?.makeFirstResponder(self)
	}

	override func keyDown(with event: NSEvent) {
		guard let actions, let state else { return super.keyDown(with: event) }
		let rtl = state.rightToLeft
		switch Int(event.keyCode) {
		case 123: // left arrow
			rtl ? actions.forward() : actions.backward()
		case 124: // right arrow
			rtl ? actions.backward() : actions.forward()
		case 49: // space: down the page first, then on
			event.modifierFlags.contains(.shift) ? pageUpOrBack() : pageDownOrOn()
		case 121: pageDownOrOn()   // page down
		case 116: pageUpOrBack()   // page up
		case 125: scrollLine(down: true)   // down arrow
		case 126: scrollLine(down: false)  // up arrow
		case 115: actions.first()  // home
		case 119: actions.last()   // end
		case 53: actions.leave()   // escape
		case 36, 76: actions.toggleFit() // return
		default:
			super.keyDown(with: event)
		}
	}

	/// Arrow keys up and down move along a page that is taller than the window.
	private func scrollLine(down: Bool) {
		let clip = scrollView.contentView
		var origin = clip.bounds.origin
		origin.y += down ? 60 : -60
		clip.animator().setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
		scrollView.reflectScrolledClipView(clip)
	}

	/// Scrolls one screen down when there is more of the page below, otherwise turns.
	private func pageDownOrOn() {
		let clip = scrollView.contentView
		let maxY = spread.frame.height - clip.bounds.height
		if clip.bounds.origin.y < maxY - 1 {
			let step = clip.bounds.height * 0.9
			clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: min(maxY, clip.bounds.origin.y + step)))
			scrollView.reflectScrolledClipView(clip)
		} else {
			actions?.forward()
		}
	}

	private func pageUpOrBack() {
		let clip = scrollView.contentView
		if clip.bounds.origin.y > 1 {
			let step = clip.bounds.height * 0.9
			clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: max(0, clip.bounds.origin.y - step)))
			scrollView.reflectScrolledClipView(clip)
		} else {
			actions?.backward()
		}
	}

	// MARK: Zoom

	@objc func zoomIn(_ sender: Any?) { zoom(by: 1.25) }
	@objc func zoomOut(_ sender: Any?) { zoom(by: 0.8) }
	@objc func zoomToActualFit(_ sender: Any?) {
		scrollView.animator().magnification = 1
	}

	private func zoom(by factor: CGFloat) {
		let target = min(max(scrollView.magnification * factor, scrollView.minMagnification), scrollView.maxMagnification)
		let clip = scrollView.contentView.bounds
		scrollView.animator().setMagnification(target, centeredAt: NSPoint(x: clip.midX, y: clip.midY))
	}

	// MARK: Mouse

	/// A click that wasn't a drag or a text selection, anywhere on the canvas (the pages or the
	/// margin around them), in window coordinates. The outer thirds turn the page, every click
	/// of a quick series counting, so clicking fast flips fast; a double click in the middle
	/// third switches between fitting the page and the width.
	fileprivate func clicked(atWindowPoint point: NSPoint, clickCount: Int) {
		guard let actions, let state else { return }
		window?.makeFirstResponder(self)
		let x = convert(point, from: nil).x
		let third = bounds.width / 3
		let zone: Int = x < third ? -1 : (x > bounds.width - third ? 1 : 0)
		if zone == 0 {
			if clickCount == 2 { actions.toggleFit() }
			return
		}
		guard state.clickToTurn, scrollView.magnification <= 1.01 else { return }
		let towardsRight = zone == 1
		towardsRight != state.rightToLeft ? actions.forward() : actions.backward()
	}

	/// Dragging a magnified page moves it, like a sheet of paper under the hand.
	fileprivate func dragged(by delta: NSPoint) {
		guard scrollView.magnification > 1.01 else { return }
		let clip = scrollView.contentView
		var origin = clip.bounds.origin
		origin.x -= delta.x / scrollView.magnification
		origin.y += delta.y / scrollView.magnification
		clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
		scrollView.reflectScrolledClipView(clip)
	}
}

// MARK: - Spread and pages

/// Clicks and drags on the pages and on the margin around them, shared by the document view
/// and the clip view, so the whole canvas answers the same way.
private final class ClickTracker {
	weak var canvas: PageCanvasView?
	private var downPoint: NSPoint?
	private var lastPoint: NSPoint?
	private var dragged = false

	func mouseDown(_ event: NSEvent) {
		downPoint = event.locationInWindow
		lastPoint = event.locationInWindow
		dragged = false
	}

	func mouseDragged(_ event: NSEvent) {
		guard let last = lastPoint, let down = downPoint else { return }
		let point = event.locationInWindow
		if hypot(point.x - down.x, point.y - down.y) >= 4 { dragged = true }
		canvas?.dragged(by: NSPoint(x: point.x - last.x, y: point.y - last.y))
		lastPoint = point
	}

	func mouseUp(_ event: NSEvent) {
		defer { downPoint = nil; lastPoint = nil }
		// A drag is a pan, never a page turn.
		guard downPoint != nil, !dragged else { return }
		canvas?.clicked(atWindowPoint: event.locationInWindow, clickCount: event.clickCount)
	}
}

/// The document view: top-down coordinates, and the place clicks on the pages land.
private final class SpreadView: NSView {
	let tracker = ClickTracker()

	override var isFlipped: Bool { true }
	override func mouseDown(with event: NSEvent) { tracker.mouseDown(event) }
	override func mouseDragged(with event: NSEvent) { tracker.mouseDragged(event) }
	override func mouseUp(with event: NSEvent) { tracker.mouseUp(event) }
}

/// One page: its image as layer contents, scaled to the frame the canvas gives it, with the
/// Live Text overlay on top when that is switched on.
private final class PageView: NSView {
	let page: Int
	private var image: CGImage?
	private var overlay: ImageAnalysisOverlayView?
	private var analysisTask: Task<Void, Never>?
	private var liveTextEnabled = false

	private static let analyzer: ImageAnalyzer? = ImageAnalyzer.isSupported ? ImageAnalyzer() : nil

	init(page: Int) {
		self.page = page
		super.init(frame: .zero)
		wantsLayer = true
		layer?.contentsGravity = .resize
		layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.12).cgColor
		layer?.magnificationFilter = .linear
		layer?.minificationFilter = .trilinear
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

	override var isFlipped: Bool { true }

	func setImage(_ image: CGImage?) {
		guard image !== self.image else { return }
		self.image = image
		layer?.contents = image
		layer?.backgroundColor = image == nil ? NSColor(white: 0.5, alpha: 0.12).cgColor : nil
		overlay?.analysis = nil
		analyze()
	}

	func setLiveText(_ enabled: Bool) {
		liveTextEnabled = enabled && Self.analyzer != nil
		if liveTextEnabled {
			if overlay == nil {
				let overlay = ImageAnalysisOverlayView()
				// Text selection explicitly: `.automaticTextOnly` leaves the selection view waiting for a
				// Live Text button that is hidden here, so a drag across text did nothing.
				overlay.preferredInteractionTypes = .textSelection
				// Selecting text is enough; the Live Text button in the corner would sit on the art.
				overlay.isSupplementaryInterfaceHidden = true
				overlay.autoresizingMask = [.width, .height]
				overlay.frame = bounds
				addSubview(overlay)
				self.overlay = overlay
			}
			analyze()
		} else {
			analysisTask?.cancel()
			overlay?.removeFromSuperview()
			overlay = nil
		}
	}

	override func layout() {
		super.layout()
		overlay?.frame = bounds
	}

	/// Live Text reads the page as it is shown: the displayed image, paper and all. Started a
	/// moment after the page settles, so flipping through doesn't queue an analysis per page.
	private func analyze() {
		analysisTask?.cancel()
		guard liveTextEnabled, let image, let analyzer = Self.analyzer, let overlay else { return }
		analysisTask = Task { @MainActor [weak overlay] in
			try? await Task.sleep(for: .milliseconds(350))
			guard !Task.isCancelled else { return }
			let configuration = ImageAnalyzer.Configuration([.text])
			let analysis = try? await analyzer.analyze(image, orientation: .up, configuration: configuration)
			guard !Task.isCancelled, let overlay else { return }
			overlay.analysis = analysis
		}
	}


	// Clicks pass through to the spread unless Live Text claims them for a selection.
	override func hitTest(_ point: NSPoint) -> NSView? {
		guard let overlay, liveTextEnabled else { return nil }
		let local = convert(point, from: superview)
		if overlay.hasInteractiveItem(at: convert(local, to: overlay)) || overlay.hasActiveTextSelection {
			return super.hitTest(point)
		}
		return nil
	}
}

// MARK: - Scroll view

/// Keeps a spread smaller than the window in the middle of it rather than in a corner.
private final class CenteringClipView: NSClipView {
	/// Clicks on the margin beside a small spread land here, not on the spread.
	var tracker: ClickTracker?

	override func mouseDown(with event: NSEvent) { tracker?.mouseDown(event) ?? super.mouseDown(with: event) }
	override func mouseDragged(with event: NSEvent) { tracker?.mouseDragged(event) ?? super.mouseDragged(with: event) }
	override func mouseUp(with event: NSEvent) { tracker?.mouseUp(event) ?? super.mouseUp(with: event) }

	override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
		var rect = super.constrainBoundsRect(proposedBounds)
		guard let document = documentView else { return rect }
		if rect.width > document.frame.width {
			rect.origin.x = (document.frame.width - rect.width) / 2
		}
		if rect.height > document.frame.height {
			rect.origin.y = (document.frame.height - rect.height) / 2
		}
		return rect
	}
}

/// Turns a two-finger horizontal swipe into one page turn, but only while the page has no room
/// to scroll sideways; a zoomed page pans as usual. Each gesture decides once, on its first
/// clear movement, whether it is a swipe or a scroll, and sticks to that until the fingers lift
/// and its momentum has run out, so a slightly diagonal scroll is never swallowed and a swipe
/// never turns twice.
private final class CenteringScrollView: NSScrollView {
	var onSwipe: ((_ forward: Bool) -> Void)?

	private enum Gesture { case undecided, swipe, scroll }
	private var gesture = Gesture.undecided
	private var swipeDistance: CGFloat = 0
	private var swipeHandled = false

	override func scrollWheel(with event: NSEvent) {
		// A mouse wheel, or a gesture this view didn't see begin: plain scrolling.
		guard event.hasPreciseScrollingDeltas else { return super.scrollWheel(with: event) }

		if event.phase == .began || event.phase == .mayBegin {
			gesture = .undecided
			swipeDistance = 0
			swipeHandled = false
		}

		if gesture == .undecided, event.phase != [] {
			let dx = abs(event.scrollingDeltaX), dy = abs(event.scrollingDeltaY)
			if dx + dy > 0.5 {
				let document = documentView?.frame.width ?? 0
				let canPanSideways = document * magnification > contentView.frame.width + 1
				gesture = (dx > dy * 1.5 && !canPanSideways) ? .swipe : .scroll
			}
		}

		switch gesture {
		case .swipe:
			if event.phase != [] {
				swipeDistance += event.scrollingDeltaX
				if !swipeHandled, abs(swipeDistance) > 50 {
					swipeHandled = true
					// Content follows the fingers: swiping to the left brings in the page on
					// the right. The canvas maps that onto reading order.
					let towardsRight = swipeDistance < 0
					let rtl = (superview as? PageCanvasView)?.isRightToLeft ?? false
					onSwipe?(towardsRight != rtl)
				}
			}
			// Its momentum events (phase empty) are swallowed with it; the next gesture's
			// `.began` starts over.
		case .scroll, .undecided:
			super.scrollWheel(with: event)
		}
	}
}

private extension PageCanvasView {
	var isRightToLeft: Bool { state?.rightToLeft ?? false }
}
