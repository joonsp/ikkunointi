# Ikkunointi

Hyprland / Omarchy-style tiling window management for macOS. *Ikkunointi* is Finnish for "windowing".

- **Dwindle tiling** like Hyprland: every new window splits the focused tile along its longer side. Gaps, a gradient focus border, `togglesplit`, pseudo-tiling, fullscreen, floating windows.
- **Workspaces 1–10** with Omarchy's key bindings. They are virtual, AeroSpace-style: windows on hidden workspaces are parked off-screen. That is instant and needs no SIP changes.
- **Caps Lock as SUPER.** It is remapped while the app runs and restored on quit. Option keeps typing `@ [ ] { } | \ $` on Nordic layouts.
- **`hyprland.conf` syntax**: `bind`/`bindd`/`binde`/`bindm`, `$variables`, sections, `windowrule`, `exec-once`, `source`. The config reloads on save.
- **`ikkunointictl`**: a `hyprctl` equivalent for scripting (`dispatch`, `clients`, `workspaces`, …).
- **Mouse**: SUPER + drag moves a window. Dropping it on a tile swaps the two. SUPER + right-drag resizes. Dragging or resizing a tile by its title bar or edges also works.
- **Menu bar workspace indicator** (Waybar-style) and an Omarchy-style key binding cheat sheet (SUPER + K).

## Build & run

Requires macOS 14+ and the Xcode command line tools.

```sh
./scripts/create-signing-cert.sh   # once: a local code-signing identity (see below)
./scripts/build.sh                 # → build/Ikkunointi.app and build/ikkunointictl
open build/Ikkunointi.app
```

On first launch macOS asks for **Accessibility** access (System Settings → Privacy & Security → Accessibility). Ikkunointi starts tiling as soon as access is granted.

macOS ties that permission to the app's code signature. `create-signing-cert.sh` puts a self-signed "Ikkunointi Local Signing" certificate in your login keychain, so rebuilt apps keep the grant. Without it the build is ad-hoc signed and you must re-grant after every rebuild.

`make` wraps the common tasks: `make test`, `make app`, `make run`, and `make install`, which copies the app to `~/Applications` and links `ikkunointictl` into `~/.local/bin`.

**Recommended macOS settings**
- System Settings → Desktop & Dock → *Drag windows to screen edges to tile*: **off**. It fights the tiler.
- Use a single macOS Space per display. Ikkunointi's workspaces replace Spaces.

## Default key bindings

SUPER is Caps Lock by default; change it with `input:super_key`.

| Keys | Action |
|---|---|
| SUPER + Return | New terminal window (Ghostty if installed) |
| SUPER + Shift + B / F | New browser / Finder window |
| SUPER + W | Close window |
| SUPER + T | Toggle floating |
| SUPER + F / SUPER + Alt + F | Fullscreen / maximize (inside gaps) |
| SUPER + J | Toggle split direction |
| SUPER + P | Pseudo-tile (keep the window's own size, centered in its tile) |
| SUPER + C | Center floating window |
| SUPER + K | Show key bindings |
| SUPER + ←→↑↓ | Move focus |
| SUPER + Shift + ←→↑↓ | Swap window (moves to the other monitor when it is empty) |
| SUPER + 1…0 | Workspace 1…10 |
| SUPER + Shift + 1…0 | Move window to workspace (and follow) |
| SUPER + Tab / Shift + Tab | Next / previous non-empty workspace |
| SUPER + Ctrl + Tab | Previous workspace (back and forth) |
| SUPER + − / = | Shrink / grow width. These are the two keys right of 0: `+` and `´` on Finnish. |
| SUPER + Shift + − / = | Shrink / grow height |
| SUPER + drag / right-drag | Move / resize window |

## Configuration

`~/.config/ikkunointi/ikkunointi.conf` is created on first launch, with your terminal and default browser filled in. Errors and warnings show up in the menu bar item, which displays a `!` while there are errors.

```ini
input {
    super_key = capslock      # capslock, rcmd, ropt, rctrl, cmd, alt, ctrl, ctrl+alt
}
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
}
decoration { rounding = 12 }
dwindle { default_split_ratio = 1.0 }
binds { workspace_back_and_forth = false }

$terminal = com.mitchellh.ghostty
bindd = SUPER, RETURN, Terminal, newwindow, $terminal
bind  = SUPER SHIFT, N, exec, open -a Notes
binde = SUPER, EQUAL, resizeactive, 100 0            # binde repeats while held
bindm = SUPER, mouse:272, movewindow

windowrule = float, class:^(com\.apple\.calculator)$  # class: bundle id or app name
windowrule = workspace 3 silent, class:^(Slack)$
windowrule = float, title:^Picture in Picture$

exec-once = open -a Raycast
source = ~/.config/ikkunointi/extra.conf
```

**Keys:** letters resolve through your current keyboard layout. Digits and the named keys `RETURN TAB SPACE ESCAPE BACKSPACE DELETE LEFT RIGHT UP DOWN HOME END PAGEUP PAGEDOWN F1–F20 MINUS EQUAL COMMA PERIOD SLASH SEMICOLON APOSTROPHE BRACKETLEFT BRACKETRIGHT BACKSLASH GRAVE` are physical positions. `code:N` takes a raw macOS key code.

**Modifiers:** `SUPER SHIFT CTRL ALT CMD`. Hyprland spellings such as `SUPER_SHIFT` and `MOD4` work too.

**Dispatchers**

| Dispatcher | Arguments |
|---|---|
| `exec` | shell command (Homebrew paths are on `PATH`) |
| `newwindow` | bundle id or app name: sends ⌘N to the running app, or launches it |
| `killactive` | |
| `togglefloating`, `togglesplit`, `pseudo`, `centerwindow` | |
| `fullscreen` | `0` covers the screen, `1` maximizes inside the gaps |
| `movefocus`, `swapwindow` (alias `movewindow`), `focusmonitor` | `l` `r` `u` `d` |
| `workspace` | `N`, `+1`/`-1`, `e+1`/`e-1` (non-empty only), `previous` |
| `movetoworkspace`, `movetoworkspacesilent` | same targets as `workspace` |
| `resizeactive` | `dx dy` in points |
| `cyclenext` | optional `prev` |
| `showkeys`, `reload`, `exit` | |

## ikkunointictl

```sh
ikkunointictl clients                 # windows: id, workspace, frame, state
ikkunointictl -j workspaces           # JSON
ikkunointictl dispatch workspace 3
ikkunointictl dispatch movetoworkspacesilent 4
ikkunointictl reload
```

## How it works

- **Accessibility API.** Ikkunointi watches every regular app with an `AXObserver`. Window frames are set through AX. Focus goes through the same SkyLight calls yabai and AltTab use, so a specific window gets focus without disabling SIP.
- **Event tap.** A session event tap runs on its own thread for key bindings and SUPER + mouse. A slow app can therefore never lag your keyboard.
- **Caps Lock.** `hidutil` maps Caps Lock to F18 while the app runs. Other key mappings you have are preserved and restored.
- **Workspaces.** macOS gives apps no API for Spaces. Hidden workspaces park their windows in a bottom corner of the screen with a 1 pt sliver showing, which is the AeroSpace approach. If you ⌘Tab or click the Dock into a window on a hidden workspace, Ikkunointi switches to that workspace.
- **Shutdown.** Quitting (menu, `exit`, SIGTERM) brings every parked window back on screen and restores Caps Lock. After a crash, relaunch: off-screen windows are recovered and the Caps Lock mapping is cleaned up.

## Limitations

- When an app turns on **Secure Keyboard Entry**, for example password prompts or Terminal's secure-input option, macOS stops delivering keys to event taps. Hotkeys pause, and the menu bar item shows `!`.
- Windows with a minimum size larger than their tile overflow it.
- There are no animations. Native fullscreen windows (green button) live in their own Space and are skipped by the tiler.
- Only the dwindle layout exists. There are no special workspaces, groups or pinning.

## Development

```sh
swift test                 # unit tests for the layout tree, workspace model, config parser
swift build                # debug build of all targets
```

`Sources/IkkunointiCore` is pure logic and fully unit-tested: the dwindle tree, the workspace and focus model, and the config parser. `Sources/Ikkunointi` is the AppKit/Accessibility shell. `Sources/ikkunointictl` is the CLI.

## Uninstall

Quit Ikkunointi and delete the app. Remove "Ikkunointi Local Signing" in Keychain Access, then delete `~/.config/ikkunointi`.
