//
//  SamplePage.swift
//  Comic Reader
//
//  A synthetic "comic page" (line-art, greys, a gradient and a few colour swatches
//  on white) so the paper effect can be previewed in Settings without loading a real
//  file. Everything is drawn proportionally, so any size renders sensibly.
//

import AppKit

enum SamplePage {

    /// A cached preview-sized page (drawing it every time the sliders move is wasteful).
    static let preview: CGImage = make(size: CGSize(width: 620, height: 900))

    /// Mac port: drawn with AppKit into a flipped bitmap, so the layout reads top-down like the
    /// UIKit original.
    static func make(size: CGSize = CGSize(width: 620, height: 900)) -> CGImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let w = size.width, h = size.height
            func rect(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> CGRect {
                CGRect(x: x * w, y: y * h, width: rw * w, height: rh * h)
            }

            NSColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // Solid black title panel (tests deep blacks + show-through).
            NSColor.black.setFill()
            cg.fill(rect(0.07, 0.08, 0.86, 0.17))
            ("COMIC READER" as NSString).draw(
                in: rect(0.10, 0.12, 0.80, 0.09),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: h * 0.045),
                                 .foregroundColor: NSColor.white])

            // 50% grey block (midtones).
            NSColor(white: 0.5, alpha: 1).setFill()
            cg.fill(rect(0.07, 0.30, 0.38, 0.24))

            // Black to white gradient strip (tonal remap).
            let cs = CGColorSpaceCreateDeviceRGB()
            if let grad = CGGradient(colorsSpace: cs,
                                     colors: [NSColor.black.cgColor, NSColor.white.cgColor] as CFArray,
                                     locations: [0, 1]) {
                cg.saveGState()
                let strip = rect(0.50, 0.30, 0.43, 0.24)
                cg.clip(to: strip)
                cg.drawLinearGradient(grad, start: CGPoint(x: strip.minX, y: 0),
                                      end: CGPoint(x: strip.maxX, y: 0), options: [])
                cg.restoreGState()
            }

            // Thin black "line art".
            NSColor.black.setStroke()
            cg.setLineWidth(max(1, h * 0.002))
            for i in 0..<8 {
                let y = (0.60 + CGFloat(i) * 0.018) * h
                cg.stroke(CGRect(x: 0.07 * w, y: y, width: 0.86 * w, height: 1))
            }

            // Colour swatches (colour handling / show-through on saturated ink).
            let colours: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemYellow]
            for (i, colour) in colours.enumerated() {
                colour.setFill()
                cg.fill(rect(0.07 + CGFloat(i) * 0.22, 0.80, 0.18, 0.13))
            }
            return true
        }
        var proposed = CGRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)!
    }
}
