# StatBar

Lightweight macOS menu bar system monitor (Swift/SwiftUI, no dependencies, ~800 KB).

## Build
    ./build.sh                 # -> build/StatBar.app, build/StatBar.dmg
    ARCH=universal ./build.sh  # arm64 + x86_64

Requires Xcode Command Line Tools. macOS 13+.

## Layout
- `Sources/` – Swift app (samplers, monitor model, SwiftUI views)
- `Bridge/smc.c` – SMC reader/writer (temperatures, fans, power)
- `Helper/fan.c` – root helper for fan modes, launched with an admin prompt, restores Auto when StatBar exits
- `scripts/make_icon.swift` – generates the app icon
- `scripts/make_dmg_background.swift` – DMG window background (drag-to-Applications arrow + first-launch hint)
- `Resources/Install.html` – install guide shipped in the DMG; button opens System Settings › Privacy & Security directly

Debug: `build/StatBar.app/Contents/MacOS/StatBar --snapshot /tmp/s.png` renders the popover to PNG.
