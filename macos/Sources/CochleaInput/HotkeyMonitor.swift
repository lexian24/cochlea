import AppKit
import Carbon.HIToolbox
import CochleaCore
import Foundation

/// A push-to-talk global hotkey.
///
/// Uses `RegisterEventHotKey` rather than a CGEventTap: an event tap would see
/// every keystroke on the system, which is both far more permission than
/// dictation needs and impossible to square with the privacy positioning.
public final class HotkeyMonitor {

    /// The binding type lives in `CochleaCore` because `Configuration`
    /// persists it; this alias keeps existing call sites reading naturally.
    public typealias Binding = HotkeyBinding

    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    /// What is registered right now, so the settings screen can show it and
    /// `rebind` can no-op when nothing changed.
    public private(set) var binding: Binding = .default

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x434F4348   // 'COCH'

    public init() {}

    /// Swap the shortcut without restarting the app.
    ///
    /// Carbon has no rebind call: an `EventHotKeyRef` is registered for one
    /// combination and unregistered as a unit. Tearing down and re-registering
    /// is the whole mechanism, which is why this is cheap to offer and why a
    /// settings screen can apply a new shortcut the instant it is recorded.
    @discardableResult
    public func rebind(to binding: Binding) -> Result<Void, Error> {
        guard binding != self.binding else { return .success(()) }
        let previous = self.binding
        do {
            try register(binding)
            return .success(())
        } catch {
            // Put the working shortcut back rather than leaving the app with
            // no way to dictate. A rejected binding must cost nothing.
            try? register(previous)
            return .failure(error)
        }
    }

    public func register(_ binding: Binding = .default) throws {
        try unregister()

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                switch GetEventKind(event) {
                case UInt32(kEventHotKeyPressed):  monitor.onPress?()
                case UInt32(kEventHotKeyReleased): monitor.onRelease?()
                default: break
                }
                return noErr
            },
            eventTypes.count, &eventTypes, context, &handlerRef
        )
        guard status == noErr else { throw HotkeyError.handlerInstallFailed(status) }

        let id = EventHotKeyID(signature: signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            binding.keyCode, binding.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            throw HotkeyError.registrationFailed(registerStatus)
        }
        self.binding = binding
        Diagnostics.log("hotkey", "registered \(binding.displayString)")
    }

    public func unregister() throws {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit { try? unregister() }
}

public enum HotkeyError: Error, CustomStringConvertible {
    case handlerInstallFailed(OSStatus)
    case registrationFailed(OSStatus)

    public var description: String {
        switch self {
        case .handlerInstallFailed(let s): return "could not install hotkey handler (\(s))"
        case .registrationFailed(let s):
            return "could not register the hotkey (\(s)); another app may already own it"
        }
    }
}
