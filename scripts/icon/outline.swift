// Prints the SVG path data behind PaperComic/Resources/AppIcon.icon: swift scripts/icon/outline.swift
//
// Icon Composer fills every path and ignores strokes, so the eyes, the mouth's rounded edge and the
// bubbles' blunt tails are outlined here and pasted into the layer SVGs as plain filled paths.
// Coordinates are on the 824-point macOS icon body inside a 1024 canvas; each SVG maps them onto
// Icon Composer's full-bleed canvas with its `canvas` group transform, and rotates the bubble
// (3 degrees front, -7 back) around 505,492. The face group is lifted 45 points to sit centred.
import CoreGraphics
import Foundation

func svg(_ path: CGPath) -> String {
	var out: [String] = []
	func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
	path.applyWithBlock { e in
		let p = e.pointee.points
		switch e.pointee.type {
		case .moveToPoint: out.append("M\(f(p[0].x)),\(f(p[0].y))")
		case .addLineToPoint: out.append("L\(f(p[0].x)),\(f(p[0].y))")
		case .addQuadCurveToPoint: out.append("Q\(f(p[0].x)),\(f(p[0].y)) \(f(p[1].x)),\(f(p[1].y))")
		case .addCurveToPoint: out.append("C\(f(p[0].x)),\(f(p[0].y)) \(f(p[1].x)),\(f(p[1].y)) \(f(p[2].x)),\(f(p[2].y))")
		case .closeSubpath: out.append("Z")
		@unknown default: break
		}
	}
	return out.joined(separator: " ")
}

func eye(_ x0: CGFloat) -> CGPath {
	let p = CGMutablePath()
	p.move(to: CGPoint(x: x0, y: 446))
	p.addCurve(to: CGPoint(x: x0 + 136, y: 446), control1: CGPoint(x: x0 + 24, y: 366), control2: CGPoint(x: x0 + 112, y: 366))
	return p.copy(strokingWithWidth: 40, lineCap: .round, lineJoin: .round, miterLimit: 10)
}
let eyes = eye(319).union(eye(555))

let mouthShape = CGMutablePath()
mouthShape.move(to: CGPoint(x: 325, y: 552)); mouthShape.addLine(to: CGPoint(x: 685, y: 552))
mouthShape.addCurve(to: CGPoint(x: 505, y: 696), control1: CGPoint(x: 685, y: 624), control2: CGPoint(x: 627.4, y: 696))
mouthShape.addCurve(to: CGPoint(x: 325, y: 552), control1: CGPoint(x: 382.6, y: 696), control2: CGPoint(x: 325, y: 624))
mouthShape.closeSubpath()
let mouth = mouthShape.union(mouthShape.copy(strokingWithWidth: 24, lineCap: .round, lineJoin: .round, miterLimit: 10))

func bubble(_ rect: CGRect, tail: [CGPoint]) -> CGPath {
	let box = CGPath(roundedRect: rect, cornerWidth: 96, cornerHeight: 96, transform: nil)
	let t = CGMutablePath(); t.addLines(between: tail); t.closeSubpath()
	return box.union(t).union(t.copy(strokingWithWidth: 34, lineCap: .round, lineJoin: .round, miterLimit: 10))
}
let front = bubble(CGRect(x: 205, y: 222, width: 600, height: 540), tail: [CGPoint(x: 315, y: 732), CGPoint(x: 309, y: 858), CGPoint(x: 445, y: 732)])
let back = bubble(CGRect(x: 185, y: 182, width: 580, height: 480), tail: [CGPoint(x: 655, y: 632), CGPoint(x: 661, y: 758), CGPoint(x: 525, y: 632)])

print("EYES", svg(eyes))
print("MOUTH", svg(mouth))
print("FRONT", svg(front))
print("BACK", svg(back))
