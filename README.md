# NotchTint

Makes the MacBook notch dissolve into your app. When the frontmost window is
fullscreen, NotchTint paints the empty menu-bar area around the notch with the
exact color of the app's top edge — no more black void framing the camera.

- **Exact color** — samples the real pixels of the window's top edge (median of
  the zones flanking the notch, so toolbar buttons don't skew it)
- **Stays out of the way** — fades out the moment your cursor enters the
  menu-bar zone, so menus are never covered; hides on the desktop and in
  Mission Control
- **Live** — re-samples on app switch, Space change, window resize and
  light/dark theme change; no constant screen capture
- **Menu-bar controls** — enable/disable, per-app exclusions, Start at Login, quit
- Single Swift file, no dependencies

## Install

```sh
git clone https://github.com/YOURNAME/notchtint.git
cd notchtint
make
./notchtint
```

On first launch macOS asks for **Screen Recording** permission (needed to read
the window's edge pixels). Grant it in *System Settings → Privacy & Security →
Screen Recording*, then relaunch. Everything else is controlled from the
🖌 menu-bar item, including **Start at Login**.

> Rebuilding the binary changes its code signature, so macOS will ask for the
> Screen Recording permission again after `make`.

## How it works

A borderless, click-through window sits above the menu bar, sized to the
menu-bar strip of the built-in display. A lightweight geometry check (no screen
capture) decides when to show it; the color is captured via ScreenCaptureKit
only when the fullscreen window actually changes, so the orange recording
indicator appears only at that moment — not continuously.

## Limitations

- macOS shows the screen-recording indicator briefly whenever the color is
  re-sampled. That's a system privacy feature; there is no public API to read
  another app's pixels without it.
- The color updates when the window changes, not continuously while you scroll.

## License

MIT
