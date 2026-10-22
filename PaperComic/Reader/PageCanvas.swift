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

struct PageCanvas: NSViewRepresentable {
	let store: PageImageStore
	let state: PageCanvasState
	let actions: PageCanvasActions

	func makeNSView(context: Context) -> PageCanvasView {
		let view = PageCanvasView(store: store)
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

		spread.canvas = self
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
		let pagesChanged = old?.pages != new.pages || old?.generation != new.generation
		if pagesChanged || old?.rightToLeft != new.rightToLeft {
			showPages(new.pages, rightToLeft: new.rightToLeft, keepImages: old?.pages == new.pages)
		}
		if old?.fitWindow == true, !new.fitWindow { restoreWindowFrame() }
		if pagesChanged || old?.fit != new.fit || old?.fitWindow != new.fitWindow {
			// A new page starts at its top, unzoomed: carrying a zoom across a turn lands the
			// reader in the middle of a page they haven't seen yet.
			scrollView.magnification = 1
			layoutSpread()
			scrollToTop()
		}
		if old?.liveText != new.liveText || pagesChanged {
			pageViews.forEach { $0.setLiveText(new.liveText) }
		}
	}

	private func showPages(_ pages: [Int], rightToLeft: Bool, keepImages: Bool) {
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
			  !window.styleMask.contains(.fullScreen), window.inLiveResize == false else { return }
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
		case 115: actions.first()  // home
		case 119: actions.last()   // end
		case 53: actions.leave()   // escape
		case 36, 76: actions.toggleFit() // return
		default:
			super.keyDown(with: event)
		}
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

	/// Called by the spread for a single click that wasn't a drag or a text selection.
	fileprivate func clicked(at point: NSPoint, clickCount: Int) {
		guard let actions, let state else { return }
		if clickCount == 2 {
			actions.toggleFit()
			return
		}
		guard state.clickToTurn, scrollView.magnification <= 1.01 else { return }
		let inCanvas = convert(point, from: spread)
		let third = bounds.width / 3
		if inCanvas.x > bounds.width - third {
			state.rightToLeft ? actions.backward() : actions.forward()
		} else if inCanvas.x < third {
			state.rightToLeft ? actions.forward() : actions.backward()
		}
	}
}

// MARK: - Spread and pages

/// The document view: top-down coordinates, and the place clicks on the pages land.
private final class SpreadView: NSView {
	weak var canvas: PageCanvasView?
	private var mouseDownPoint: NSPoint?

	override var isFlipped: Bool { true }

	override func mouseDown(with event: NSEvent) {
		mouseDownPoint = event.locationInWindow
		if event.clickCount == 2 {
			canvas?.clicked(at: convert(event.locationInWindow, from: nil), clickCount: 2)
			mouseDownPoint = nil
		}
	}

	override func mouseUp(with event: NSEvent) {
		guard let start = mouseDownPoint, event.clickCount <= 1 else { return }
		mouseDownPoint = nil
		let end = event.locationInWindow
		// A drag is a pan, never a page turn.
		guard hypot(end.x - start.x, end.y - start.y) < 4 else { return }
		canvas?.clicked(at: convert(end, from: nil), clickCount: 1)
	}
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
				overlay.preferredInteractionTypes = .automaticTextOnly
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

/// Turns a two-finger horizontal swipe into one page turn, but only while the page has no
/// room to scroll sideways; a zoomed page pans as usual.
private final class CenteringScrollView: NSScrollView {
	var onSwipe: ((_ forward: Bool) -> Void)?
	private var swipeDistance: CGFloat = 0
	private var swipeHandled = false

	override func scrollWheel(with event: NSEvent) {
		let document = documentView?.frame.width ?? 0
		let canPanSideways = document * magnification > contentView.bounds.width * magnification + 1
		guard event.hasPreciseScrollingDeltas, !canPanSideways,
			  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || swipeDistance != 0 else {
			super.scrollWheel(with: event)
			return
		}
		if event.phase == .began {
			swipeDistance = 0
			swipeHandled = false
		}
		swipeDistance += event.scrollingDeltaX
		if !swipeHandled, abs(swipeDistance) > 60 {
			swipeHandled = true
			// Content follows the fingers: a swipe to the left brings the next page in from
			// the right. The canvas maps that onto reading order.
			let towardsRight = swipeDistance < 0
			let rtl = (superview as? PageCanvasView)?.isRightToLeft ?? false
			onSwipe?(towardsRight != rtl)
		}
		if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
			swipeDistance = 0
		}
	}
}

private extension PageCanvasView {
	var isRightToLeft: Bool { state?.rightToLeft ?? false }
}
