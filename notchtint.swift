// NotchTint — paints the empty menu-bar area around the MacBook notch with the
// top-edge color of the frontmost fullscreen app, so the notch "dissolves" into the UI.
//
// Build:  make            (or: swiftc -O notchtint.swift -o notchtint && codesign -f -s - notchtint)
// Run:    ./notchtint     First launch asks for Screen Recording permission — grant and relaunch.
// A menu-bar item provides Enable/Disable, per-app exclusions, Start at Login and Quit.
import Cocoa
import ScreenCaptureKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

let agentLabel = "com.notchtint.agent"
var agentPlistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist" }

@discardableResult
func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - Color sampling

// Per-channel median of the window's top edge, sampled separately in the zones left
// and right of the notch — sidebar and content often differ, so the strip gets both.
// Median ignores outliers (traffic lights, toolbar buttons).
func edgeColors(_ cg: CGImage) -> (left: NSColor, right: NSColor)? {
    let W = 128, H = 3
    let stripH = max(1, min(cg.height, 6))
    guard let strip = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: stripH)),
          let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                              bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .low
    ctx.draw(strip, in: CGRect(x: 0, y: 0, width: W, height: H))
    guard let data = ctx.data else { return nil }
    let buf = data.bindMemory(to: UInt8.self, capacity: W * H * 4)

    var L: ([UInt8], [UInt8], [UInt8]) = ([], [], [])
    var R: ([UInt8], [UInt8], [UInt8]) = ([], [], [])
    for y in 0..<H {
        for x in 0..<W {
            let fx = Double(x) / Double(W)
            let i = (y * W + x) * 4
            // zones flanking the notch; skip rounded corners and the notch itself
            if fx > 0.06 && fx < 0.36 {
                L.0.append(buf[i]); L.1.append(buf[i + 1]); L.2.append(buf[i + 2])
            } else if fx > 0.64 && fx < 0.94 {
                R.0.append(buf[i]); R.1.append(buf[i + 1]); R.2.append(buf[i + 2])
            }
        }
    }
    guard !L.0.isEmpty, !R.0.isEmpty else { return nil }
    func med(_ a: [UInt8]) -> CGFloat { let s = a.sorted(); return CGFloat(s[s.count / 2]) / 255 }
    return (NSColor(red: med(L.0), green: med(L.1), blue: med(L.2), alpha: 1),
            NSColor(red: med(R.0), green: med(R.1), blue: med(R.2), alpha: 1))
}

// Capture the app's biggest window (its pixels only — neighbours excluded) and
// sample the top edge. Requires Screen Recording permission.
func topEdgeColors(pid: pid_t) async -> (left: NSColor, right: NSColor)? {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
          let win = content.windows
              .filter({ $0.owningApplication?.processID == pid && $0.frame.width > 40 && $0.frame.height > 40 })
              .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    else { return nil }

    let cfg = SCStreamConfiguration()
    cfg.width = Int(win.frame.width)
    cfg.height = Int(win.frame.height)
    cfg.showsCursor = false
    let filter = SCContentFilter(desktopIndependentWindow: win)
    guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    else { return nil }
    return edgeColors(cg)
}

// MARK: - Window geometry helpers

func winBounds(_ w: [String: Any]) -> [String: CGFloat] { (w[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:] }
func winArea(_ w: [String: Any]) -> CGFloat { let b = winBounds(w); return (b["Width"] ?? 0) * (b["Height"] ?? 0) }

// MARK: - Main controller

@MainActor
final class Tint: NSObject, NSMenuDelegate {
    var screen: NSScreen
    var strips: [NSWindow] = []      // one per visited Space
    var strip: NSWindow?             // the one on the current Space
    var statusItem: NSStatusItem?
    var menuBarH: CGFloat = 24
    var notch = CGRect.zero          // notch span in strip coords, measured in makeStrip
    var lastKey = ""                 // window id + size of the currently applied color
    var colorCache: [String: (left: NSColor, right: NSColor)] = [:]   // window+size → edge colors; cleared on theme change
    var pendingHide = 0              // consecutive failed checks; hide only after 2 (survives Space swipes)
    var shouldShow = false           // frontmost window is fullscreen
    var mouseAtTop = false           // cursor in menu-bar zone → yield to the real menu bar
    var pendingRefresh: (pid: pid_t, wid: CGWindowID, strip: NSWindow?)?   // Refresh Color waiting for a safe cursor
    var safeSince: Date?             // when the cursor last went clear of the menu bar + toolbar
    var lastWID: CGWindowID = 0      // frontmost fullscreen window, as of the last evaluate
    var forceCapture = false         // set around one evaluate(): re-capture the current window despite the cache
    var pulseStart = Date.distantPast    // when the shimmer faded in; enforces a minimum showtime
    var lastApp: NSRunningApplication?
    var settingsWindow: NSWindow?

    var enabled: Bool {              // persisted, so a disable survives relaunch
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }

    var excluded: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "excludedBundleIDs") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "excludedBundleIDs") }
    }

    // bundle id → [r,g,b] set manually with the eyedropper; overrides sampling
    var customColors: [String: [Double]] {
        get { (UserDefaults.standard.dictionary(forKey: "customColors") as? [String: [Double]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "customColors") }
    }

    var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    var loginEnabled: Bool {
        isBundled ? SMAppService.mainApp.status == .enabled
                  : FileManager.default.fileExists(atPath: agentPlistPath)
    }

    init(screen: NSScreen) {
        self.screen = screen
        super.init()
        menuBarH = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 24)
        buildStatusItem()
    }

    // One strip PER Space: each window stays on the Space it was ordered onto and slides
    // away with it during swipes, keeping its color for when the user swipes back.
    func makeStrip() -> NSWindow {
        let f = screen.frame
        // monotonic: inside a fullscreen Space visibleFrame has no menu bar and the
        // fallback is 1px short — never shrink a height we've already seen correctly
        menuBarH = max(f.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, menuBarH)
        let rect = NSRect(x: f.minX, y: f.maxY - menuBarH, width: f.width, height: menuBarH)
        // window reaches `drop` below the menu bar so the halo can spill onto the content;
        // the color fill stays in the menu-bar band on top. Transparent + click-through elsewhere.
        let drop: CGFloat = 60
        let w = NSWindow(contentRect: NSRect(x: f.minX, y: rect.minY - drop, width: f.width, height: menuBarH + drop),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]   // joins the Space it's ordered onto and stays there
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isOpaque = false
        w.backgroundColor = .clear       // outside the revealed fill the real menu bar shows through
        w.alphaValue = 0
        let root = CALayer()
        w.contentView?.layer = root
        w.contentView?.wantsLayer = true
        let bounds = CGRect(x: 0, y: drop, width: rect.width, height: rect.height)   // menu-bar band
        // notch span in strip coords; the auxiliary areas are the menu-bar zones beside it
        notch = CGRect(x: rect.width / 2 - 100, y: drop, width: 200, height: rect.height)
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notch = CGRect(x: l.maxX - f.minX, y: drop, width: r.minX - l.maxX, height: rect.height)
        }
        func horizontal(_ g: CAGradientLayer) {
            g.startPoint = CGPoint(x: 0, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 0.5)
        }
        let clear = NSColor.clear.cgColor, black = NSColor.black.cgColor

        // sampled two-tone color: solid at the sides, blend hidden behind the notch
        let fill = CAGradientLayer()
        fill.name = "fill"
        fill.frame = bounds
        horizontal(fill)
        fill.locations = [0, 0.35, 0.65, 1]
        // feathered mask centered on the notch; its width animates notch → full strip,
        // so the color floods out from under the notch. Open by default: cached colors show instantly.
        let reveal = CAGradientLayer()
        reveal.name = "reveal"
        horizontal(reveal)
        reveal.colors = [clear, black, black, clear]
        reveal.locations = [0, 0.12, 0.88, 1]
        reveal.position = CGPoint(x: notch.midX, y: rect.height / 2)
        reveal.bounds = CGRect(x: 0, y: 0, width: revealWidth(open: true), height: rect.height)
        fill.mask = reveal
        // glints riding the flood's leading edges (one per side)
        for _ in 0..<2 {
            let s = CAGradientLayer()
            s.name = "sheen"
            horizontal(s)
            s.colors = [clear, NSColor.white.withAlphaComponent(0.55).cgColor, clear]
            s.bounds = CGRect(x: 0, y: 0, width: 90, height: rect.height)
            s.position = reveal.position
            s.opacity = 0
            fill.addSublayer(s)
        }

        // violet halo around the notch while a capture is in flight: dark at the top →
        // violet → lavender core at the notch's lower lip → fading out below the menu bar
        let glow = CAGradientLayer()
        glow.name = "glow"
        let H = drop + rect.height, lip = rect.height / H     // lip position, fraction from the top
        glow.anchorPoint = CGPoint(x: 0.5, y: drop / H)        // breathe from the lip
        glow.frame = CGRect(x: notch.minX - 110, y: 0, width: notch.width + 220, height: H)
        glow.startPoint = CGPoint(x: 0.5, y: 1)
        glow.endPoint = CGPoint(x: 0.5, y: 0)
        let violet = NSColor(srgbRed: 0.36, green: 0.12, blue: 0.96, alpha: 1)
        glow.colors = [violet.withAlphaComponent(0), violet.withAlphaComponent(0.95),
                       NSColor(srgbRed: 0.88, green: 0.84, blue: 1, alpha: 1),
                       violet.withAlphaComponent(0.5), violet.withAlphaComponent(0)].map(\.cgColor)
        glow.locations = [0, lip * 0.55, lip, lip + (1 - lip) * 0.35, 1].map { NSNumber(value: Double($0)) }
        let fade = CAGradientLayer()     // side feather so the halo melts into the menu bar
        fade.frame = glow.bounds
        horizontal(fade)
        fade.colors = [clear, black, black, clear]
        fade.locations = [0, 0.3, 0.7, 1]
        glow.mask = fade
        glow.opacity = 0

        root.addSublayer(fill)
        root.addSublayer(glow)
        return w
    }

    // Mask width: collapsed = exactly the notch (color hidden behind it);
    // open = solid part (76% after feathering) reaches the farther screen edge.
    func revealWidth(open: Bool) -> CGFloat {
        open ? 2 * max(notch.midX, screen.frame.width - notch.midX) / 0.76 : notch.width
    }

    func layer(_ w: NSWindow?, _ name: String) -> CALayer? {
        w?.contentView?.layer?.sublayers?.first { $0.name == name }
    }

    // Pulse on = old color retracts behind the notch, halo breathes around it.
    // Off = halo fades, the sampled color floods out from under the notch with edge glints.
    func setPulsing(_ w: NSWindow?, _ on: Bool) {
        guard let glow = layer(w, "glow"), let fill = layer(w, "fill"),
              let reveal = fill.mask else { return }
        if on {
            if glow.animation(forKey: "breathe") == nil {
                let scale = CABasicAnimation(keyPath: "transform.scale.x")
                scale.fromValue = 0.9
                scale.toValue = 1.12
                let rise = CABasicAnimation(keyPath: "transform.scale.y")   // halo swells up and down from the lip
                rise.fromValue = 0.8
                rise.toValue = 1.15
                let g = CAAnimationGroup()
                g.animations = [scale, rise]
                g.duration = 1.1
                g.autoreverses = true
                g.repeatCount = .infinity
                g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glow.add(g, forKey: "breathe")
            }
            if glow.opacity == 0 {
                pulseStart = Date()
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.35)
                reveal.bounds.size.width = revealWidth(open: false)
                CATransaction.commit()
            }
            glow.opacity = 1                     // implicit 0.25s fade-in
        } else if glow.opacity != 0 {
            // captures often finish in <0.5s — without a minimum showtime the halo
            // reads as a blink; the sampled color waits behind the notch until then
            let started = pulseStart
            let remain = max(0, 1.6 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + remain) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pulseStart == started else { return }  // re-armed since
                    let dur = 0.9
                    let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(dur)
                    CATransaction.setAnimationTimingFunction(ease)
                    glow.opacity = 0
                    reveal.bounds.size.width = self.revealWidth(open: true)
                    CATransaction.commit()
                    // glints travel with the solid edge: notch edge → screen edge
                    let sheens = fill.sublayers?.filter { $0.name == "sheen" } ?? []
                    for (s, dir) in zip(sheens, [-1.0, 1.0]) {
                        let move = CABasicAnimation(keyPath: "position.x")
                        move.fromValue = self.notch.midX + dir * self.revealWidth(open: false) * 0.38
                        move.toValue = self.notch.midX + dir * self.revealWidth(open: true) * 0.38
                        move.timingFunction = ease
                        let flash = CAKeyframeAnimation(keyPath: "opacity")
                        flash.values = [0, 1, 0]
                        flash.keyTimes = [0, 0.25, 1]
                        let g = CAAnimationGroup()
                        g.animations = [move, flash]
                        g.duration = dur
                        s.add(g, forKey: "glint")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + dur) {
                        if glow.opacity == 0 { glow.removeAnimation(forKey: "breathe") }
                    }
                }
            }
        }
    }

    func setColors(_ w: NSWindow?, _ c: (left: NSColor, right: NSColor)) {
        (layer(w, "fill") as? CAGradientLayer)?.colors =
            [c.left.cgColor, c.left.cgColor, c.right.cgColor, c.right.cgColor]
    }

    // Strip belonging to the current Space; created on first visit. Extra strips that
    // migrated here (their Space was closed) get removed. Returns whether it's freshly made.
    func activeStrip() -> (NSWindow, isNew: Bool) {
        let here = strips.filter { $0.isOnActiveSpace }
        for extra in here.dropFirst() {
            extra.orderOut(nil)
            strips.removeAll { $0 === extra }
        }
        if let w = here.first { return (w, false) }
        let w = makeStrip()
        w.orderFront(nil)          // attaches it to the current Space
        strips.append(w)
        return (w, true)
    }

    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // custom template icon from the bundle; SF Symbol fallback for the bare binary
        if let path = Bundle.main.path(forResource: "menubar", ofType: "pdf"),
           let img = NSImage(contentsOfFile: path) {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            item.button?.image = img
        } else {
            item.button?.image = NSImage(systemSymbolName: "paintbrush.fill", accessibilityDescription: "NotchTint")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func start() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluate(fromTimer: true)
                self?.runPendingRefresh()
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(stateChanged),
                         name: NSWorkspace.didActivateApplicationNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(stateChanged),
                         name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(themeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        evaluate()
    }

    // app switch / Space change: cached colors apply instantly, no re-capture
    @objc func stateChanged() { evaluate() }

    @objc func themeChanged() {
        colorCache.removeAll()   // light/dark switch repaints every app — cached colors are stale
        lastKey = ""
        evaluate()
    }

    @objc func screensChanged() {
        // displays added/removed — re-pick the notched screen, drop all strips (stale geometry)
        screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screen
        strips.forEach { $0.orderOut(nil) }
        strips = []
        strip = nil
        // re-measure now, not lazily in makeStrip: evaluate's fullscreen check needs it first,
        // and a bare 24 (< notch 32) rejected every fullscreen window → no strip ever again (lid sleep/wake)
        menuBarH = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 24)
        lastKey = ""
        evaluate()
    }

    func updateHover() {
        let p = NSEvent.mouseLocation
        let atTop = p.y >= screen.frame.maxY - menuBarH && p.x >= screen.frame.minX && p.x <= screen.frame.maxX
        guard atTop != mouseAtTop else { return }
        mouseAtTop = atTop
        applyVisibility()
    }

    // Deferred Refresh Color, polled every tick: capture only once the cursor has stayed
    // clear of the slid-down menu bar AND toolbar for 0.8s — else we'd sample the toolbar.
    // Polled, not edge-triggered: the status menu is drawn out of process, so the mouse
    // monitor sees the cursor leave the top before the click ever happens.
    func runPendingRefresh() {
        guard let p = pendingRefresh,
              let front = NSWorkspace.shared.frontmostApplication,
              front != NSRunningApplication.current      // alert just closed, focus still returning
        else { return }
        guard front.processIdentifier == p.pid, lastWID == p.wid else {
            pendingRefresh = nil                         // user moved on — drop it, restore the old color
            safeSince = nil
            setPulsing(p.strip, false)
            return
        }
        // ponytail: 120pt = menu bar + tallest common toolbar; a taller toolbar can still be sampled
        guard NSEvent.mouseLocation.y < screen.frame.maxY - 120 else { safeSince = nil; return }
        let since = safeSince ?? Date()
        safeSince = since
        guard Date().timeIntervalSince(since) >= 0.8 else { return }
        pendingRefresh = nil
        safeSince = nil
        // bypass the cache for the current window only — clearing it all made
        // every other window re-scan on its next visit
        forceCapture = true
        evaluate()
        forceCapture = false
    }

    func applyVisibility(animated: Bool = true) {
        // only touch the strip whose Space is active — strips resting on other Spaces
        // keep their alpha and color, so returning to them shows no re-appear animation
        guard let strip, strip.isOnActiveSpace else { return }
        let target: CGFloat = (enabled && shouldShow && !mouseAtTop) ? 1 : 0
        guard strip.alphaValue != target else { return }
        guard animated else { strip.alphaValue = target; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            strip.animator().alphaValue = target
        }
    }

    func evaluate(fromTimer: Bool = false) {
        let f = screen.frame
        guard enabled,
              let app = NSWorkspace.shared.frontmostApplication,
              app != NSRunningApplication.current,
              !excluded.contains(app.bundleIdentifier ?? ""),
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]]
        else { return hide(counted: fromTimer) }
        lastApp = app
        let pid = app.processIdentifier
        let layer0 = infos.filter {
            ($0[kCGWindowLayer as String] as? Int) == 0 && (winBounds($0)["Width"] ?? 0) > 40
        }
        // desktop / Mission Control: the topmost window doesn't belong to the active app
        guard let top = layer0.first, (top[kCGWindowOwnerPID as String] as? pid_t) == pid,
              // geometry from the app's biggest window, not a thin helper panel
              let win = layer0.filter({ ($0[kCGWindowOwnerPID as String] as? pid_t) == pid })
                              .max(by: { winArea($0) < winArea($1) }),
              let wid = win[kCGWindowNumber as String] as? CGWindowID
        else { return hide(counted: fromTimer) }
        let b = winBounds(win)
        guard let W = b["Width"], let H = b["Height"], let X = b["X"], let Y = b["Y"]
        else { return hide(counted: fromTimer) }

        let onNotched = (X + W / 2) > f.minX && (X + W / 2) < f.maxX
        let fullscreen = W >= f.width * 0.98 && Y <= menuBarH + 4 && H >= f.height * 0.8
        guard onNotched, fullscreen else { return hide(counted: fromTimer) }

        shouldShow = true
        pendingHide = 0
        let (s, isNew) = activeStrip()
        strip = s
        lastWID = wid
        updateHover()
        if let arr = customColors[app.bundleIdentifier ?? ""], arr.count == 3 {
            let c = NSColor(red: arr[0], green: arr[1], blue: arr[2], alpha: 1)
            setColors(s, (c, c))                 // user-picked color overrides sampling
            lastKey = ""
            applyVisibility(animated: !isNew)
            return
        }
        let key = "\(wid)-\(Int(W))x\(Int(H))"
        // drop the stale entry, not just skip it: if this capture fails, the next tick
        // must retry instead of quietly falling back to the old color
        if forceCapture { colorCache[key] = nil }
        if let cached = colorCache[key] {   // known window — instant, no capture
            setColors(s, cached)                 // color BEFORE showing: no black flash
            lastKey = key
            // returning to a known window: appear instantly, as if the strip never left
            applyVisibility(animated: !isNew)
            return
        }
        applyVisibility()
        // skip if a capture is already in flight, or a Refresh is waiting for a safe cursor
        // (its own forced evaluate captures then)
        guard (key != lastKey && pendingRefresh == nil) || forceCapture else { return }
        if colorCache.count > 200 { colorCache.removeAll() }   // window resizes mint new keys forever
        lastKey = key
        setPulsing(s, true)                      // halo until the sampled color lands
        Task { @MainActor in
            defer { self.setPulsing(s, false) }  // s, not self.strip: a Space switch mid-capture must not strand the halo
            if let c = await topEdgeColors(pid: pid) {
                self.colorCache[key] = c
                // apply only if this window is still current — a slow capture must not
                // paint the previous app's color onto the next app's strip
                if self.lastKey == key { self.setColors(self.strip, c) }
            } else if self.lastKey == key {
                self.lastKey = ""                // failure isn't cached; retry next tick
            }
        }
    }

    // Space-swipe animations produce transient "bad" states. Only timer ticks count
    // toward hiding (notification bursts during transitions don't), and two consecutive
    // failed ticks (~1s) are required — so a strip never fades mid-swipe.
    func hide(force: Bool = false, counted: Bool = true) {
        if !force {
            guard counted else { return }
            pendingHide += 1
            guard pendingHide >= 2 else { return }
        }
        shouldShow = false
        // fade every strip on the CURRENT Space, not just `strip` — an orphan whose
        // fullscreen Space was closed migrates to the desktop and must be hidden too
        let targets = force ? strips : strips.filter { $0.isOnActiveSpace }
        for s in targets where s.alphaValue != 0 {
            if force { s.alphaValue = 0 }
            else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    s.animator().alphaValue = 0
                }
            }
        }
        lastKey = ""
    }

    // MARK: menu

    func item(_ title: String, _ symbol: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return it
    }

    // Menu row with a real NSSwitch (Control Center style). Clicking it doesn't close
    // the menu, so both toggles can be flipped in one visit.
    func switchItem(_ title: String, _ symbol: String, isOn: Bool, _ action: Selector) -> NSMenuItem {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        v.autoresizingMask = [.width]

        let icon = NSImageView(frame: NSRect(x: 14, y: 7, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .labelColor
        v.addSubview(icon)

        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 38, y: 6, width: 140, height: 18)
        v.addSubview(label)

        let sw = NSSwitch()
        sw.controlSize = .mini
        sw.sizeToFit()
        sw.state = isOn ? .on : .off
        sw.target = self
        sw.action = action
        sw.setFrameOrigin(NSPoint(x: v.frame.width - sw.frame.width - 14,
                                  y: (v.frame.height - sw.frame.height) / 2))
        sw.autoresizingMask = [.minXMargin]
        v.addSubview(sw)

        let it = NSMenuItem()
        it.view = v
        return it
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(switchItem("Enabled", "power", isOn: enabled, #selector(toggleEnabled)))

        if let app = lastApp, let bid = app.bundleIdentifier {
            let name = app.localizedName ?? bid
            let isEx = excluded.contains(bid)
            let ex = item((isEx ? "Include " : "Exclude ") + name,
                          isEx ? "eye" : "eye.slash", #selector(toggleExclude(_:)))
            ex.representedObject = bid
            menu.addItem(ex)

            let pick = item("Pick Color for \(name)…", "eyedropper", #selector(pickColor(_:)))
            pick.representedObject = bid
            menu.addItem(pick)

            if customColors[bid] != nil {
                let reset = item("Reset Color for \(name)", "eyedropper.halffull", #selector(resetColor(_:)))
                reset.representedObject = bid
                menu.addItem(reset)
            }
        }

        menu.addItem(item("Refresh Color", "arrow.clockwise", #selector(refreshColor), key: "r"))

        menu.addItem(.separator())
        menu.addItem(item("Settings…", "gearshape", #selector(openSettings), key: ","))
        menu.addItem(switchItem("Start at Login", "bolt", isOn: loginEnabled, #selector(toggleLogin)))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchTint",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    // NSColorSampler is the system eyedropper: needs no Screen Recording permission,
    // the user explicitly clicks the pixel they want.
    @objc func pickColor(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        NSColorSampler().show { [weak self] color in
            guard let self, let c = color?.usingColorSpace(.deviceRGB) else { return }
            MainActor.assumeIsolated {
                self.customColors[bid] = [c.redComponent, c.greenComponent, c.blueComponent]
                self.evaluate()
            }
        }
    }

    @objc func resetColor(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        customColors[bid] = nil
        lastKey = ""
        evaluate()
    }

    @objc func toggleEnabled() {
        enabled.toggle()
        if enabled { evaluate() } else { hide(force: true) }
    }

    // Menu is open → cursor is at the top → the fullscreen app's toolbar is slid down
    // and would be sampled. Defer the actual capture until it's safe (runPendingRefresh).
    @objc func refreshColor() {
        guard let app = lastApp else { return }
        // a custom color overrides sampling, so a refresh would silently do nothing —
        // refreshing means replacing it; ask first
        if let bid = app.bundleIdentifier, customColors[bid] != nil {
            let name = app.localizedName ?? bid
            let a = NSAlert()
            a.messageText = "Replace custom color?"
            a.informativeText = "\(name) has a custom color. It will be replaced with a newly sampled one."
            a.addButton(withTitle: "Replace")
            a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            let ok = a.runModal() == .alertFirstButtonReturn
            app.activate()                       // hand focus back to the fullscreen app
            guard ok else { return }
            customColors[bid] = nil
        }
        pendingRefresh = (app.processIdentifier, lastWID, strip)
        safeSince = nil
        setPulsing(strip, true)                  // halo right away: the refresh is accepted, just waiting
    }

    @objc func toggleExclude(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        var ex = excluded
        if ex.contains(bid) { ex.remove(bid) } else { ex.insert(bid) }
        excluded = ex
        if excluded.contains(bid) { hide(force: true) } else { evaluate() }
    }

    // Settings window edited something — re-derive everything from UserDefaults
    func settingsDidChange() {
        lastKey = ""
        if enabled { evaluate() } else { hide(force: true) }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(tint: self)))
            w.title = "NotchTint"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleLogin() {
        if isBundled {              // modern API; shows up in System Settings → Login Items
            let svc = SMAppService.mainApp
            if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
            return
        }
        // bare binary fallback: LaunchAgent plist
        let fm = FileManager.default
        if fm.fileExists(atPath: agentPlistPath) {
            run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
            try? fm.removeItem(atPath: agentPlistPath)
        } else {
            try? fm.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents",
                                    withIntermediateDirectories: true)
            let bin = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist: [String: Any] = ["Label": agentLabel, "ProgramArguments": [bin],
                                        "RunAtLoad": true, "KeepAlive": false]
            (plist as NSDictionary).write(toFile: agentPlistPath, atomically: true)
            run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlistPath])
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    let tint: Tint
    @State private var enabled = true
    @State private var login = false
    @State private var excluded: [String] = []
    @State private var custom: [String: [Double]] = [:]

    func load() {
        enabled = tint.enabled
        login = tint.loginEnabled
        excluded = Array(tint.excluded).sorted { appName($0) < appName($1) }
        custom = tint.customColors
    }

    func appName(_ bid: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return bid }
        return FileManager.default.displayName(atPath: url.path)
    }

    func appIcon(_ bid: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        else { return NSWorkspace.shared.icon(for: .applicationBundle) }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func appLabel(_ bid: String) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: appIcon(bid)).resizable().frame(width: 20, height: 20)
            Text(appName(bid))
        }
    }

    func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle.fill") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
    }

    func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.applicationBundle]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for url in p.urls {
            if let bid = Bundle(url: url)?.bundleIdentifier { tint.excluded.insert(bid) }
        }
        load()
        tint.settingsDidChange()
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $enabled)
                    .onChange(of: enabled) { v in
                        tint.enabled = v
                        tint.settingsDidChange()
                    }
                Toggle("Start at Login", isOn: $login)
                    .onChange(of: login) { v in
                        if v != tint.loginEnabled { tint.toggleLogin() }
                    }
            }
            Section("Excluded Apps") {
                if excluded.isEmpty {
                    Text("No excluded apps").foregroundStyle(.secondary)
                }
                ForEach(excluded, id: \.self) { bid in
                    HStack {
                        appLabel(bid)
                        Spacer()
                        removeButton {
                            tint.excluded.remove(bid)
                            load()
                            tint.settingsDidChange()
                        }
                    }
                }
                Button("Add App…") { addApp() }
            }
            Section("Custom Colors") {
                if custom.isEmpty {
                    Text("None — use “Pick Color” in the menu bar menu").foregroundStyle(.secondary)
                }
                ForEach(custom.keys.sorted { appName($0) < appName($1) }, id: \.self) { bid in
                    HStack {
                        appLabel(bid)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: {
                                let a = custom[bid] ?? [0, 0, 0]
                                return Color(red: a[0], green: a[1], blue: a[2])
                            },
                            set: { c in
                                guard let n = NSColor(c).usingColorSpace(.deviceRGB) else { return }
                                custom[bid] = [n.redComponent, n.greenComponent, n.blueComponent]
                                tint.customColors = custom
                                tint.settingsDidChange()
                            }), supportsOpacity: false)
                            .labelsHidden()
                        removeButton {
                            tint.customColors[bid] = nil
                            load()
                            tint.settingsDidChange()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 440)
        .onAppear { load() }
    }
}

// MARK: - Self-check (runs on every launch, fails loudly if sampling breaks)

func selfCheck() {
    let ctx = CGContext(data: nil, width: 64, height: 8, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // left half green, right half blue — edgeColors must tell them apart
    ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 8))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 32, y: 0, width: 32, height: 8))
    let e = edgeColors(ctx.makeImage()!)!
    let l = e.left.usingColorSpace(.deviceRGB)!, r = e.right.usingColorSpace(.deviceRGB)!
    // precondition, not assert: assert is compiled out by -O and would check nothing
    precondition(l.greenComponent > 0.7 && l.blueComponent < 0.3, "edgeColors left broken")
    precondition(r.blueComponent > 0.7 && r.greenComponent < 0.3, "edgeColors right broken")
}

selfCheck()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let tint = MainActor.assumeIsolated { () -> Tint? in
    guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return nil }
    let t = Tint(screen: screen)
    t.start()
    return t
}
guard tint != nil else { fputs("no screen found\n", stderr); exit(1) }
app.run()
