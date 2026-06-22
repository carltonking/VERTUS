import AppKit

/// Builds Alfred's 18×18 menu-bar icon.
///
/// Extracted from `AppDelegate` (which had grown past 2,400 lines) as the first
/// step in decomposing that god object: the drawing holds no app state, so it
/// lives cleanly on its own and can be unit-tested in isolation.
enum MenuBarIcon {
    static func make() -> NSImage {
        if let url = Bundle.main.url(forResource: "alfred-small-logo", withExtension: "png"),
           let sourceImage = NSImage(contentsOf: url) {
            sourceImage.size = NSSize(width: 18, height: 18)
            sourceImage.isTemplate = false
            sourceImage.accessibilityDescription = "Alfred"
            return sourceImage
        }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.black.setFill()

        let path = NSBezierPath()
        path.windingRule = .evenOdd

        // Outer triangle
        path.move(to: NSPoint(x: 9, y: 17))
        path.line(to: NSPoint(x: 17, y: 1))
        path.line(to: NSPoint(x: 1, y: 1))
        path.close()

        // Inner triangular counterform
        path.move(to: NSPoint(x: 9, y: 9.8))
        path.line(to: NSPoint(x: 5.4, y: 3.5))
        path.line(to: NSPoint(x: 12.6, y: 3.5))
        path.close()

        path.fill()

        image.isTemplate = true
        image.accessibilityDescription = "Alfred"
        return image
    }
}
