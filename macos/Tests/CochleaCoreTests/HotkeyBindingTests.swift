import XCTest
@testable import CochleaCore

final class HotkeyBindingTests: XCTestCase {

    func testTheDefaultIsWhatM0Hardcoded() {
        // Preserved rather than improved: an upgrade must not move someone's
        // shortcut under them, even a shortcut they disliked.
        XCTAssertEqual(HotkeyBinding.default.displayString, "⌃⌥D")
    }

    func testModifiersRenderInTheOrderMacOSWritesThem() {
        let all = HotkeyBinding(
            keyCode: 0x31,
            modifiers: HotkeyBinding.control | HotkeyBinding.option
                     | HotkeyBinding.shift | HotkeyBinding.command)
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘Space")
    }

    func testAShortcutWithoutModifiersIsRefused() {
        // It would swallow that key everywhere on the system.
        XCTAssertFalse(HotkeyBinding(keyCode: 0x02, modifiers: 0).isUsable)
        XCTAssertTrue(HotkeyBinding(keyCode: 0x02,
                                    modifiers: HotkeyBinding.control).isUsable)
    }

    func testAnUnmappableKeyIsRefusedRatherThanShownAsANumber() {
        let unknown = HotkeyBinding(keyCode: 0xFF, modifiers: HotkeyBinding.command)
        XCTAssertFalse(unknown.isUsable)
        XCTAssertEqual(unknown.displayString, "⌘?")
    }

    func testItSurvivesTheConfigFile() {
        // The point of the type: M0 hardcoded the shortcut, so it did not.
        var config = Configuration(home: URL(fileURLWithPath: "/tmp/x"))
        config.hotkey = HotkeyBinding(keyCode: 0x31, modifiers: HotkeyBinding.option)
        let data = try! JSONEncoder().encode(config)
        let decoded = try! JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(decoded.hotkey.displayString, "⌥Space")
    }
}

final class ActivationTests: XCTestCase {

    func testHybridIsTheDefault() {
        // One binding, both behaviours, no mode setting to discover: holding
        // works for a phrase, tapping works for a paragraph.
        XCTAssertEqual(Configuration(home: URL(fileURLWithPath: "/tmp/x")).activation,
                       .hybrid)
    }

    func testEveryModeExplainsItself() {
        // These strings are the entire explanation in Settings.
        for mode in Configuration.Activation.allCases {
            XCTAssertFalse(mode.explanation.isEmpty, "\(mode) has no explanation")
        }
    }

    func testAnUtteranceCapExistsAndIsNotAbsurd() {
        // Toggle and hybrid make it possible to start dictating and walk away.
        let config = Configuration(home: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertGreaterThan(config.maximumUtteranceSeconds, 60)
        XCTAssertLessThanOrEqual(config.maximumUtteranceSeconds, 1800)
    }

    func testActivationSurvivesTheConfigFile() throws {
        let decoded = try JSONDecoder().decode(
            Configuration.self, from: Data("{\"activation\": \"toggle\"}".utf8))
        XCTAssertEqual(decoded.activation, .toggle)
    }

    func testAnOlderConfigWithoutActivationGetsTheDefault() throws {
        // A config written by M0 has none of these keys.
        let decoded = try JSONDecoder().decode(
            Configuration.self, from: Data("{\"modelIdentifier\": \"whisper-small\"}".utf8))
        XCTAssertEqual(decoded.activation, .hybrid)
        XCTAssertEqual(decoded.hotkey, .default)
    }
}

/// Fix-last needs a second binding, and the two must not collide by default.
final class FixHotkeyTests: XCTestCase {

    func testTheFixShortcutIsOneKeyFromDictation() {
        // Used seconds apart -- dictate, see the error, fix it. A correction
        // that costs a different chord is one people do not make, which is the
        // capture-rate problem SPEC §1 warns about.
        XCTAssertEqual(HotkeyBinding.default.modifiers, HotkeyBinding.defaultFix.modifiers)
        XCTAssertNotEqual(HotkeyBinding.default.keyCode, HotkeyBinding.defaultFix.keyCode)
    }

    func testTheDefaultsRenderAsTheyDoInTheMenu() {
        XCTAssertEqual(HotkeyBinding.default.displayString, "⌃⌥D")
        XCTAssertEqual(HotkeyBinding.defaultFix.displayString, "⌃⌥F")
    }

    func testTheFixShortcutIsUsable() {
        XCTAssertTrue(HotkeyBinding.defaultFix.isUsable)
    }
}
