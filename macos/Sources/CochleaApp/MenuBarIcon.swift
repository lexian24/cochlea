import AppKit
import CochleaCore

/// The status item's icon: the cochlea mark, drawn rather than shipped.
///
/// A template image, so macOS tints it — dark on a light menu bar, light on a
/// dark one, inverted while the menu is open. An ordinary bitmap gets none of
/// that and looks wrong in at least one of those three states.
///
/// The state language is deliberately lopsided. **Listening is the one that
/// has to be unmissable**, because it means the microphone is open, and an app
/// that positions itself on privacy cannot have that read as a subtle
/// difference in a small glyph. So listening inverts: the mark knocks out of a
/// filled block, which changes the icon's whole silhouette rather than its
/// detail. The other states differ by a small mark, which is all they need.
enum MenuBarIcon {

    /// Menu bar glyphs live in an 18pt box on every macOS version that matters.
    static let size: CGFloat = 18

    static func image(for state: DictationController.State) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size),
                            flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(state: state, in: context)
            return true
        }
        // Template, so the colour is the system's decision and not ours.
        image.isTemplate = true
        return image
    }

    private static func draw(state: DictationController.State, in context: CGContext) {
        let listening = state == .listening
        let center = CGPoint(x: size / 2, y: size / 2)
        // The mark shrinks when it is inside a block, so the block itself can
        // occupy the same 18pt the bare mark did. Without this, listening is
        // visibly larger than idle and the bar twitches on every utterance.
        let extent = size * (listening ? 0.60 : 0.86)

        if listening {
            let box = CGRect(x: 0.5, y: 0.5, width: size - 1, height: size - 1)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(CGPath(roundedRect: box, cornerWidth: size * 0.26,
                                   cornerHeight: size * 0.26, transform: nil))
            context.fillPath()
            // Knocked out rather than drawn in white: a template image has no
            // white, only coverage, so painting the mark would fill the hole
            // back in with whatever tint the system chose for the block.
            context.setBlendMode(.clear)
        } else {
            context.setFillColor(NSColor.black.cgColor)
        }

        fillMark(center: center, extent: extent, in: context)
        context.setBlendMode(.normal)

        // Both badges sit in the gap under the mark's open mouth, which is the
        // only part of an 18pt spiral with room to spare.
        context.setFillColor(NSColor.black.cgColor)
        switch state {
        case .transcribing:
            context.fillEllipse(in: CGRect(x: size - 5.6, y: 0.9,
                                           width: 4.6, height: 4.6))
        case .failed:
            // A triangle, not a ring. At this size a ring and a dot are the
            // same shape with different weights, and the two states they mean
            // -- working and broken -- are not ones to confuse. Silhouette is
            // the only thing that survives 5px.
            let w: CGFloat = 6.4, h: CGFloat = 5.6
            let x = size - w - 0.3, y: CGFloat = 0.4
            context.move(to: CGPoint(x: x + w / 2, y: y + h))
            context.addLine(to: CGPoint(x: x + w, y: y))
            context.addLine(to: CGPoint(x: x, y: y))
            context.closePath()
            context.fillPath()
        case .idle, .listening:
            break
        }
    }

    private static func fillMark(center: CGPoint, extent: CGFloat,
                                 in context: CGContext) {
        let points = CochleaMark.outline(center: center, extent: extent)
        guard let first = points.first else { return }
        context.move(to: first)
        for point in points.dropFirst() { context.addLine(to: point) }
        context.closePath()
        context.fillPath()
    }
}
