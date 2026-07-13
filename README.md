# NotchTint

Makes the MacBook notch dissolve into your app. When the frontmost window is
fullscreen, NotchTint paints the empty menu-bar area around the notch with the
exact colors of the app's top edge — no more black void framing the camera.

<!-- demo: record a Space swipe between two fullscreen apps (Cmd+Shift+5 or Kap),
     save as demo.gif and it shows up here -->
![demo](demo.gif)

- **Exact colors** — samples the real pixels of the window's top edge; the left
  and right zones are sampled separately, so apps with a darker sidebar get a
  matching two-tone gradient (the blend hides behind the notch)
- **Median, not average** — traffic lights and toolbar buttons don't skew the color
- **Manual override** — pick any color for an app with the system eyedropper
- **Stays out of the way** — fades out when your cursor enters the menu-bar
  zone, so menus are never covered; hides on the desktop and in Mission Control
- **Per-Space strips** — every fullscreen Space keeps its own strip; swiping
  between Spaces the strip slides along with the app
- **Cached** — the color is captured once per window and reused; re-sampled on
  resize and light/dark theme change; no constant screen capture
- **Menu-bar controls** — enable/disable, per-app exclusions, color picker,
  Start at Login, quit
- Single Swift file, no dependencies

## Install

```sh
git clone https://github.com/YOURNAME/notchtint.git
cd notchtint
make app
open NotchTint.app
```

On first launch macOS asks for **Screen Recording** permission (needed to read
the window's edge pixels). Grant it in *System Settings → Privacy & Security →
Screen Recording*, then relaunch. Everything else is controlled from the
menu-bar item, including **Start at Login**.

`make build && ./notchtint` runs it as a bare binary instead — handy for
development, but the Screen Recording permission resets on every rebuild.

## Menu

| Item | What it does |
|---|---|
| Enabled | master switch |
| Exclude *App* | never tint for this app |
| Pick Color for *App*… | system eyedropper; overrides sampling for this app |
| Refresh Color | re-sample (e.g. a website changed its theme) |
| Start at Login | via SMAppService (app bundle) or LaunchAgent (bare binary) |

## App icon

Put a 1024×1024 `icon.png` in the repo root and run `make icon && make app`.

## How it works

A borderless, click-through window sits above the menu bar on each fullscreen
Space. A lightweight geometry check (no screen capture) decides when to show
it; colors are captured via ScreenCaptureKit only when a new window appears or
changes size, so the orange recording indicator appears only at that moment —
not continuously.

## Limitations

- macOS briefly shows the screen-recording indicator when a color is sampled.
  That's a system privacy feature; no public API reads another app's pixels
  without it. (The eyedropper override avoids it entirely.)
- Colors update when the window changes, not continuously while you scroll —
  use Refresh Color if an app repaints its toolbar.

## License

MIT
