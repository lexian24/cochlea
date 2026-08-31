import AppKit
import Carbon.HIToolbox
import Foundation

/// A push-to-talk global hotkey.
///
/// Uses `RegisterEventHotKey` rather than a CGEventTap: an event tap would see
/// every keystroke on the system, which is both far more permission than
/// dictation needs and impossible to square with the privacy positioning.
public final class HotkeyMonitor {

    public struct Binding: Sendable, Equatable {
        public var keyCode: UInt32
        public var modifiers: UInt32

        /// Default: Fn is not addressable via RegisterEventHotKey, so
        /// Control-Option-D is used until the user rebinds it.
        public static let `default` = Binding(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(controlKey | optionKey)
        )

        public init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
    }

    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x434F4348   // 'COCH'

    public init() {}

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
