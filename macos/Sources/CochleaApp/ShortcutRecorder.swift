import AppKit
import CochleaCore
import SwiftUI

/// A field that captures the next chord the user presses.
///
/// There is no AppKit control for this, and the obvious shortcut — reading
/// `NSEvent.addGlobalMonitorForEvents` — would watch every keystroke on the
/// system, which is the permission `HotkeyMonitor` deliberately refuses. This
/// takes first responder and reads its own `keyDown` instead, so it only ever
/// sees keys pressed while it is focused.
struct ShortcutRecorder: NSViewRepresentable {

    @Binding var binding: HotkeyBinding
    /// Reported when the user records something unusable, so the screen can
    /// say why rather than silently ignoring the press.
    var onRejected: (String) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { captured in
            guard captured.isUsable else {
                onRejected(captured.hasModifiers
                    ? "That key cannot be used as a shortcut."
                    : "A shortcut needs at least one modifier — ⌃, ⌥, ⇧ or ⌘ — "
                      + "or it would swallow that key everywhere on your Mac.")
                return
            }
            binding = captured
        }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.binding = binding
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var binding: HotkeyBinding = .default
        var onCapture: ((HotkeyBinding) -> Void)?
        private var recording = false

        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool { recording = true; needsDisplay = true; return true }
        override func resignFirstResponder() -> Bool { recording = false; needsDisplay = true; return true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

        override func keyDown(with event: NSEvent) {
            // Escape leaves the shortcut alone rather than recording Escape,
            // which is what someone pressing it almost always means.
            if event.keyCode == 0x35 {
                window?.makeFirstResponder(nil)
                return
            }
            onCapture?(HotkeyBinding(keyCode: UInt32(event.keyCode),
                                     modifiers: Self.carbonModifiers(event.modifierFlags)))
            window?.makeFirstResponder(nil)
        }

        /// AppKit and Carbon disagree about how to spell a modifier.
        static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
            var mask: UInt32 = 0
            if flags.contains(.control) { mask |= HotkeyBinding.control }
            if flags.contains(.option)  { mask |= HotkeyBinding.option }
            if flags.contains(.shift)   { mask |= HotkeyBinding.shift }
            if flags.contains(.command) { mask |= HotkeyBinding.command }
            return mask
        }

        override func draw(_ dirtyRect: NSRect) {
            let radius: CGFloat = 6
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                    xRadius: radius, yRadius: radius)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                       : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = recording ? 2 : 1
            path.stroke()

            let text = recording ? "Press a shortcut…" : binding.displayString
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: style,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(in: NSRect(x: 0, y: (bounds.height - size.height) / 2,
                                 width: bounds.width, height: size.height),
                      withAttributes: attributes)
        }
    }
}
