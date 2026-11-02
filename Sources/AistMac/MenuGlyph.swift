import AppKit

enum MenuGlyph {
    /// 18×18 template: a rounded checkbox with a check, and a four-point AI sparkle notched into its corner.
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 18))
            clip.appendOval(in: NSRect(x: 9.9, y: -1.1, width: 9.2, height: 9.2))
            clip.windingRule = .evenOdd
            clip.addClip()
            let box = NSBezierPath(roundedRect: NSRect(x: 1.8, y: 3.4, width: 12.8, height: 12.8), xRadius: 3.8, yRadius: 3.8)
            box.lineWidth = 1.6
            box.stroke()
            NSGraphicsContext.restoreGraphicsState()

            let check = NSBezierPath()
            check.move(to: NSPoint(x: 5.0, y: 9.9))
            check.line(to: NSPoint(x: 7.4, y: 12.3))
            check.line(to: NSPoint(x: 11.4, y: 7.4))
            check.lineWidth = 1.7
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()

            let c = NSPoint(x: 14.5, y: 3.5), r: CGFloat = 3.4, k: CGFloat = 0.55
            let tips = [NSPoint(x: c.x, y: c.y - r), NSPoint(x: c.x + r, y: c.y),
                        NSPoint(x: c.x, y: c.y + r), NSPoint(x: c.x - r, y: c.y)]
            let star = NSBezierPath()
            star.move(to: tips[0])
            for i in 1...4 {
                let to = tips[i % 4]
                let ctrl = NSPoint(x: c.x + (tips[i - 1].x - c.x + to.x - c.x) * k / 2 * 0.5,
                                   y: c.y + (tips[i - 1].y - c.y + to.y - c.y) * k / 2 * 0.5)
                star.curve(to: to, controlPoint1: ctrl, controlPoint2: ctrl)
            }
            star.close()
            star.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Aist"
        return image
    }
}
