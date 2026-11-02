import XCTest
@testable import IkkunointiCore

final class ConfigTests: XCTestCase {
    func testDefaultConfigParsesCleanly() {
        let text = DefaultConfig.text(terminal: "com.mitchellh.ghostty", browser: "company.thebrowser.dia", fileManager: "com.apple.finder")
        let c = Config.parse(text)
        XCTAssertEqual(c.errors, [], c.errors.map(\.description).joined(separator: "\n"))
        XCTAssertEqual(c.warnings, [], c.warnings.map(\.description).joined(separator: "\n"))
        XCTAssertEqual(c.superKey, .capslock)
        XCTAssertEqual(c.gapsIn, 5)
        XCTAssertEqual(c.gapsOut, 10)
        XCTAssertEqual(c.splitRatio, 0.5)
        XCTAssertEqual(c.mouseBindings.count, 2)
        XCTAssertEqual(c.windowRules.count, 3)

        let ret = c.keyBindings.first { $0.key == .code(36) && $0.mods == [.superKey] }
        XCTAssertEqual(ret?.action, .newWindow(app: "com.mitchellh.ghostty"))
        XCTAssertEqual(ret?.description, "Terminal")

        let ws10 = c.keyBindings.first { $0.key == .code(29) && $0.mods == [.superKey, .shift] }
        XCTAssertEqual(ws10?.action, .moveToWorkspace(.number(10), silent: false))

        let close = c.keyBindings.first { $0.key == .character("w") }
        XCTAssertEqual(close?.action, .killActive)

        let grow = c.keyBindings.first { $0.key == .code(24) && $0.mods == [.superKey] }
        XCTAssertEqual(grow?.action, .resizeActive(dx: 100, dy: 0))
        XCTAssertEqual(grow?.repeats, true)

        // No two bindings share a key combo.
        var seen = Set<String>()
        for b in c.keyBindings {
            let k = "\(b.mods.rawValue)-\(b.key)"
            XCTAssertFalse(seen.contains(k), "duplicate binding \(b.mods) \(b.keyLabel)")
            seen.insert(k)
        }
    }

    func testHyprlandSyntax() {
        let c = Config.parse("""
        $mod = SUPER
        $term = open -na Ghostty   # trailing comment
        general:gaps_in = 3
        general {
            gaps_out = 7 7 7 7
            col.active_border = rgb(7aa2f7)
        }
        bind = $mod, Q, exec, $term
        bind = $mod SHIFT, code:12, killactive
        bindd = SUPER_CTRL, left, Focus left, movefocus, l
        bind = SUPER, X, exec, echo "a, b" ## not a comment
        bindm = SUPER, mouse:273, resizewindow
        windowrulev2 = workspace 4 silent, class:^(Slack)$, title:.*
        exec-once = echo hi
        """)
        XCTAssertEqual(c.errors, [])
        XCTAssertEqual(c.gapsIn, 3)
        XCTAssertEqual(c.gapsOut, 7)
        XCTAssertEqual(c.activeBorder.colors, [RGBA(rgba: 0x7aa2f7ff)])
        XCTAssertEqual(c.keyBindings[0].action, .exec("open -na Ghostty"))
        XCTAssertEqual(c.keyBindings[0].key, .character("q"))
        XCTAssertEqual(c.keyBindings[1].key, .code(12))
        XCTAssertEqual(c.keyBindings[1].mods, [.superKey, .shift])
        XCTAssertEqual(c.keyBindings[2].mods, [.superKey, .ctrl])
        XCTAssertEqual(c.keyBindings[2].action, .moveFocus(.left))
        XCTAssertEqual(c.keyBindings[3].action, .exec(#"echo "a, b" # not a comment"#))
        XCTAssertEqual(c.mouseBindings.first?.action, .resize)
        XCTAssertEqual(c.windowRules.first?.effect, .workspace(4, silent: true))
        XCTAssertTrue(c.windowRules[0].matches(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", title: "x"))
        XCTAssertFalse(c.windowRules[0].matches(bundleID: "com.apple.Safari", appName: "Safari", title: "x"))
        XCTAssertEqual(c.execOnce, ["echo hi"])
    }

    func testErrorsAreReportedWithLines() {
        let c = Config.parse("""
        bind = HYPER, Q, exec, x
        bind = SUPER, NOPE, killactive
        bind = SUPER, Q, frobnicate
        input {
            super_key = banana
        }
        general {
        """)
        XCTAssertEqual(c.errors.map(\.line), [1, 2, 3, 5, 7])
        XCTAssertTrue(c.keyBindings.isEmpty)
    }

    func testUnknownShellVariablesSurvive() {
        let c = Config.parse("bind = SUPER, E, exec, open $HOME")
        XCTAssertEqual(c.keyBindings.first?.action, .exec("open $HOME"))
    }

    func testSourceIncludes() {
        let c = Config.parse("source = extra.conf\ngeneral:gaps_out = 4", loader: { path in
            path == "extra.conf" ? "general:gaps_in = 9\nbind = SUPER, A, killactive" : nil
        })
        XCTAssertEqual(c.gapsIn, 9)
        XCTAssertEqual(c.gapsOut, 4)
        XCTAssertEqual(c.keyBindings.count, 1)
    }

    func testGradientParsing() {
        let g = BorderGradient.parse("rgba(33ccffee) rgba(00ff99ee) 45deg")
        XCTAssertEqual(g?.colors.count, 2)
        XCTAssertEqual(g?.angle, 45)
        XCTAssertEqual(BorderGradient.parse("0xff33ccff")?.colors.first, RGBA(rgba: 0x33ccffff))
        XCTAssertEqual(BorderGradient.parse("rgba(255, 0, 0, 0.5)")?.colors.first, RGBA(r: 1, g: 0, b: 0, a: 0.5))
        XCTAssertNil(BorderGradient.parse("blue"))
        XCTAssertNil(BorderGradient.parse("rgb(7aa2f7) banana"))
    }

    func testModifierAndSuperKeyParsing() {
        XCTAssertEqual(Modifiers.parse("SUPERSHIFT"), [.superKey, .shift])
        XCTAssertEqual(Modifiers.parse("super + alt"), [.superKey, .alt])
        XCTAssertEqual(Modifiers.parse(""), [])
        XCTAssertNil(Modifiers.parse("HYPER"))
        XCTAssertEqual(SuperKey(config: "Right_Cmd"), .rcmd)
        XCTAssertEqual(SuperKey(config: "ctrl+alt"), .ctrlAlt)
        XCTAssertEqual(SuperKey.cmd.normalize([.cmd, .shift]), [.superKey, .shift])
        XCTAssertEqual(SuperKey.capslock.normalize([.cmd, .shift]), [.cmd, .shift])
    }

    func testDispatcherParsing() throws {
        XCTAssertEqual(try Action.parse(dispatcher: "workspace", args: "e-1"), .workspace(.existingRelative(-1)))
        XCTAssertEqual(try Action.parse(dispatcher: "workspace", args: "+1"), .workspace(.relative(1)))
        XCTAssertEqual(try Action.parse(dispatcher: "workspace", args: "previous"), .workspace(.previous))
        XCTAssertEqual(try Action.parse(dispatcher: "movetoworkspacesilent", args: "4"), .moveToWorkspace(.number(4), silent: true))
        XCTAssertEqual(try Action.parse(dispatcher: "fullscreen", args: "1"), .fullscreen(mode: 1))
        XCTAssertEqual(try Action.parse(dispatcher: "cyclenext", args: "prev"), .cycleNext(previous: true))
        XCTAssertThrowsError(try Action.parse(dispatcher: "workspace", args: "special:magic"))
        XCTAssertThrowsError(try Action.parse(dispatcher: "resizeactive", args: "10"))
    }
}
