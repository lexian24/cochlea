import AppKit
import Carbon.HIToolbox
import CochleaCore
import Foundation

/// The app's global hotkeys.
///
/// Uses `RegisterEventHotKey` rather than a CGEventTap: an event tap would see
/// every keystroke on the system, which is both far more permission than
/// dictation needs and impossible to square with the privacy positioning.
///
/// Registers several shortcuts, not one. Carbon delivers every hotkey event to
/// the same installed handler, so two `HotkeyMonitor` instances would each see
/// the other's presses and fire on them — the events carry an `EventHotKeyID`,
/// and telling them apart means reading it. One monitor owning all of them is
/// what makes that possible.
public final class HotkeyMonitor {

    /// The binding type lives in `CochleaCore` because `Configuration`
    /// persists it; this alias keeps existing call sites reading naturally.
    public typealias Binding = HotkeyBinding

    /// What a shortcut does. The raw value is the `EventHotKeyID` Carbon hands
    /// back, so it is the thing that distinguishes one press from another.
    public enum Action: UInt32, CaseIterable, Sendable {
        case dictate = 1
        case fixLast = 2
    }

    public var onPress: ((Action) -> Void)?
    public var onRelease: ((Action) -> Void)?

    /// What is registered right now, so the settings screen can show it and
    /// `rebind` can no-op when nothing changed.
    public private(set) var bindings: [Action: Binding] = [:]

    /// The dictation shortcut, which most callers mean when they say "the
    /// hotkey".
    public var binding: Binding { bindings[.dictate] ?? .default }

    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
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
    public func rebind(_ action: Action = .dictate, to binding: Binding)
        -> Result<Void, Error> {
        guard binding != bindings[action] else { return .success(()) }
        let previous = bindings
        var updated = bindings
        updated[action] = binding
        do {
            try register(updated)
            return .success(())
        } catch {
            // Put the working shortcuts back rather than leaving the app with
            // no way to dictate. A rejected binding must cost nothing.
            try? register(previous)
            return .failure(error)
        }
    }

    /// Register every shortcut, replacing whatever was registered before.
    ///
    /// All-or-nothing on purpose. A partial registration leaves the app in a
    /// state nobody can describe — some shortcuts live, some not — and the
    /// caller cannot put it back without knowing which half succeeded.
    public func register(_ bindings: [Action: Binding]) throws {
        try unregister()
        try installHandler()
        for action in Action.allCases {
            guard let binding = bindings[action] else { continue }
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: action.rawValue)
            let status = RegisterEventHotKey(
                binding.keyCode, binding.modifiers, id,
                GetApplicationEventTarget(), 0, &reference)
            guard status == noErr, let reference else {
                try? unregister()
                throw HotkeyError.registrationFailed(status)
            }
            hotKeyRefs[action] = reference
        }
        self.bindings = bindings
        let described = Action.allCases
            .compactMap { bindings[$0].map { b in b.displayString } }
            .joined(separator: ", ")
        Diagnostics.log("hotkey", "registered \(described)")
    }

    /// Convenience for the dictation shortcut alone.
    public func register(_ binding: Binding = .default) throws {
        try register([.dictate: binding])
    }

    private func installHandler() throws {
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
                // Which shortcut, not just which kind of event. Without this
                // every registered shortcut would fire every handler, so
                // pressing the fix-last key would also start dictating.
                var identifier = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard read == noErr,
                      let action = Action(rawValue: identifier.id) else { return noErr }
                switch GetEventKind(event) {
                case UInt32(kEventHotKeyPressed):  monitor.onPress?(action)
                case UInt32(kEventHotKeyReleased): monitor.onRelease?(action)
                default: break
                }
                return noErr
            },
            eventTypes.count, &eventTypes, context, &handlerRef
        )
        guard status == noErr else { throw HotkeyError.handlerInstallFailed(status) }
    }

    public func unregister() throws {
        for reference in hotKeyRefs.values { UnregisterEventHotKey(reference) }
        hotKeyRefs.removeAll()
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
