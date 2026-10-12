<img width="128" height="128" alt="icon" src="https://github.com/user-attachments/assets/59340729-e5dd-4516-b5e2-145ab2dfc825" />

# NotchTint

Makes the MacBook notch dissolve into your app. When the frontmost window is
fullscreen, NotchTint paints the empty menu-bar area around the notch with the
exact colors of the app's top edge — no more black void framing the camera.

![demo](demo.gif)

## Features

- **Exact colors** — samples the real pixels of the window's top edge. The left
  and right halves are sampled separately, so an app with a darker sidebar gets
  both colors, blended into a gradient across the middle
- **Median, not average** — traffic lights and toolbar buttons don't skew the color
- **Scan animation** — while a new window is sampled, a halo breathes around the
  notch; the color then floods out from under it
- **Manual override** — pick any color for an app with the system eyedropper
- **Stays out of the way** — fades out when your cursor enters the menu-bar
  zone, so menus are never covered; hides on the desktop and in Mission Control
- **Per-Space strips** — every fullscreen Space keeps its own strip, so it
  slides along with the app when you swipe between Spaces
- **Cached** — a color is captured once per window and reused; re-sampled on
  resize and on light/dark theme change. No constant screen capture
- **Single Swift file, no dependencies**

## Install

Requires Apple Silicon and macOS 14 or later.

```sh
brew install --cask tedytag/tap/notchtint
```

Or download `NotchTint.zip` from [Releases](https://github.com/tedytag/notchtint/releases)
and move the app to `/Applications`.

**First launch.** NotchTint isn't notarized (no paid Apple Developer account),
so macOS blocks it. Allow it in *System Settings → Privacy & Security → Open
Anyway*, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/NotchTint.app
```

macOS then asks for **Screen Recording** permission, which is needed to read
the window's edge pixels. Grant it in *System Settings → Privacy & Security →
Screen Recording* and relaunch.

## Menu

Everything is controlled from the menu-bar item.

| Item | What it does |
|---|---|
| Enabled | master switch |
| Exclude / Include *App* | never tint for the frontmost app, or tint it again |
| Pick Color for *App*… | system eyedropper; overrides sampling for this app |
| Reset Color for *App* | drop the picked color and go back to sampling |
| Refresh Color | re-sample the current window (e.g. a website changed its theme); asks before replacing a picked color |
| Settings | window with the same switches, the excluded-apps list and picked colors |
| Start at Login | launch NotchTint when you log in |

## How it works

A borderless, click-through window sits above the menu bar on each fullscreen
Space. A lightweight geometry check (no screen capture) decides when to show
it. Colors are captured via ScreenCaptureKit only when a new window appears or
changes size, so the screen-recording indicator shows up at that moment only —
not continuously.

## Limitations

- macOS briefly shows the screen-recording indicator when a color is sampled.
  That's a system privacy feature; no public API reads another app's pixels
  without it. (A picked color avoids it entirely.)
- Colors update when the window changes, not continuously while you scroll —
  use Refresh Color if an app repaints its toolbar.

## Build from source

```sh
git clone https://github.com/tedytag/notchtint.git
cd notchtint
make app
open NotchTint.app
```

- `make build && ./notchtint` runs it as a bare binary — handy for development,
  but the Screen Recording permission resets on every rebuild. A self-signed
  code-signing certificate named "NotchTint Signing" in your keychain keeps the
  permission across `make app` rebuilds (see the Makefile).
- To change the app icon, put a 1024×1024 `icon.png` in the repo root and run
  `make icon && make app`.

## License

MIT
