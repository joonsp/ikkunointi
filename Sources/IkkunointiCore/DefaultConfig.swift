import Foundation

public enum DefaultConfig {
    /// The config written on first launch. Bindings mirror Omarchy's Hyprland defaults.
    public static func text(terminal: String, browser: String, fileManager: String) -> String {
        var s = """
        # ──────────────────────────────────────────────────────────────────────
        #  Ikkunointi: Hyprland / Omarchy style tiling for macOS
        #
        #  This file reloads automatically when you save it.
        #  Syntax follows hyprland.conf: sections { }, $variables, bind / bindd /
        #  binde / bindm, windowrule, exec-once, source. `#` starts a comment.
        #  Errors show up in the menu bar item.
        # ──────────────────────────────────────────────────────────────────────

        input {
            # Physical key that acts as SUPER:
            #   capslock  Caps Lock becomes SUPER while Ikkunointi runs (restored on quit)
            #   rcmd / ropt / rctrl   only the right-hand modifier
            #   cmd / alt / ctrl / ctrl+alt
            super_key = capslock
        }

        general {
            gaps_in = 5              # around each window (2x between neighbours)
            gaps_out = 10            # between windows and the screen edge
            border_size = 2          # focus border, 0 disables it
            col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
        }

        decoration {
            rounding = 12            # corner radius of the focus border
        }

        dwindle {
            default_split_ratio = 1.0   # 0.1 - 1.9, like Hyprland (1.0 = even split)
        }

        binds {
            workspace_back_and_forth = false   # SUPER+N on the current workspace jumps back
        }

        # Apps. `newwindow` opens a new window in the running app (it sends ⌘N),
        # or launches the app. Use `exec` for arbitrary shell commands.
        $terminal = \(terminal)
        $browser = \(browser)
        $fileManager = \(fileManager)

        bindd = SUPER, RETURN, Terminal, newwindow, $terminal
        bindd = SUPER SHIFT, B, Browser, newwindow, $browser
        bindd = SUPER SHIFT, F, File manager, newwindow, $fileManager
        # bindd = SUPER SHIFT, N, Notes, exec, open -a Notes

        # Windows
        bindd = SUPER, W, Close window, killactive,
        bindd = SUPER, T, Toggle floating, togglefloating,
        # bindd = SUPER, V, Toggle floating, togglefloating,
        bindd = SUPER, F, Fullscreen, fullscreen, 0
        bindd = SUPER ALT, F, Maximize, fullscreen, 1
        bindd = SUPER, J, Toggle split, togglesplit,
        bindd = SUPER, P, Pseudo tile, pseudo,
        bindd = SUPER, C, Center floating window, centerwindow,
        bindd = SUPER, K, Show key bindings, showkeys,

        # Move focus
        bindd = SUPER, LEFT, Focus left, movefocus, l
        bindd = SUPER, RIGHT, Focus right, movefocus, r
        bindd = SUPER, UP, Focus up, movefocus, u
        bindd = SUPER, DOWN, Focus down, movefocus, d

        # Swap windows
        bindd = SUPER SHIFT, LEFT, Swap left, swapwindow, l
        bindd = SUPER SHIFT, RIGHT, Swap right, swapwindow, r
        bindd = SUPER SHIFT, UP, Swap up, swapwindow, u
        bindd = SUPER SHIFT, DOWN, Swap down, swapwindow, d

        # Cycle windows on the workspace
        # bindd = ALT, TAB, Next window, cyclenext,
        # bindd = ALT SHIFT, TAB, Previous window, cyclenext, prev

        # Workspaces
        bindd = SUPER, TAB, Next workspace, workspace, e+1
        bindd = SUPER SHIFT, TAB, Previous workspace, workspace, e-1
        bindd = SUPER CTRL, TAB, Former workspace, workspace, previous

        """
        for i in 1...10 {
            let key = i == 10 ? "0" : "\(i)"
            s += "bindd = SUPER, \(key), Workspace \(i), workspace, \(i)\n"
        }
        s += "\n# Move the focused window (and follow it); movetoworkspacesilent stays put\n"
        for i in 1...10 {
            let key = i == 10 ? "0" : "\(i)"
            s += "bindd = SUPER SHIFT, \(key), Move window to workspace \(i), movetoworkspace, \(i)\n"
        }
        s += """

        # Resize. MINUS / EQUAL are the two keys right of 0 (+ and ´ on Nordic layouts).
        binde = SUPER, MINUS, resizeactive, -100 0
        binde = SUPER, EQUAL, resizeactive, 100 0
        binde = SUPER SHIFT, MINUS, resizeactive, 0 -100
        binde = SUPER SHIFT, EQUAL, resizeactive, 0 100

        # Mouse: SUPER + left drag moves (drop on a tile to swap), SUPER + right drag resizes
        bindm = SUPER, mouse:272, movewindow
        bindm = SUPER, mouse:273, resizewindow

        # Window rules: float, tile, workspace N [silent]. class: matches bundle id or app name.
        windowrule = float, class:^(com\\.apple\\.calculator|com\\.apple\\.systempreferences|com\\.apple\\.archiveutility)$
        windowrule = float, class:^(com\\.apple\\.ScreenSharing|com\\.apple\\.PhotoBooth)$
        windowrule = float, title:^(Picture[- ]in[- ]Picture)$
        # windowrule = workspace 3 silent, class:^(com\\.tinyspeck\\.slackmacgap)$

        # Commands run once at startup
        # exec-once = open -a Raycast

        """
        return s
    }
}
