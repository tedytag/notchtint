// NotchTint — paints the empty menu-bar area around the MacBook notch with the
// top-edge color of the frontmost fullscreen app, so the notch "dissolves" into the UI.
//
// Build:  make            (or: swiftc -O notchtint.swift -o notchtint && codesign -f -s - notchtint)
// Run:    ./notchtint     First launch asks for Screen Recording permission — grant and relaunch.
// A menu-bar item provides Enable/Disable, per-app exclusions, Start at Login and Quit.
import Cocoa
import CoreImage
import ScreenCaptureKit
import ServiceManagement

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

// Average color of an icon (fallback when window capture is unavailable).
func averageColor(_ image: NSImage) -> NSColor {
    guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return .black }
    let params = [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]
    guard let out = CIFilter(name: "CIAreaAverage", parameters: params)?.outputImage else { return .black }
    var px = [UInt8](repeating: 0, count: 4)
    CIContext(options: [.workingColorSpace: NSNull()]).render(
        out, toBitmap: &px, rowBytes: 4,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    return NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                   blue: CGFloat(px[2]) / 255, alpha: 1)
}

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
    var lastKey = ""                 // window id + size of the currently applied color
    var colorCache: [String: (left: NSColor, right: NSColor)] = [:]   // window+size → edge colors; cleared on theme change
    var pendingHide = 0              // consecutive failed checks; hide only after 2 (survives Space swipes)
    var shouldShow = false           // frontmost window is fullscreen
    var mouseAtTop = false           // cursor in menu-bar zone → yield to the real menu bar
    var enabled = true
    var lastApp: NSRunningApplication?

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
        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]   // joins the Space it's ordered onto and stays there
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isOpaque = true
        w.alphaValue = 0
        // horizontal gradient: solid at the sides, blend hidden behind the notch in the middle
        let g = CAGradientLayer()
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        g.locations = [0, 0.35, 0.65, 1]
        w.contentView?.layer = g
        w.contentView?.wantsLayer = true
        return w
    }

    func setColors(_ w: NSWindow?, _ c: (left: NSColor, right: NSColor)) {
        (w?.contentView?.layer as? CAGradientLayer)?.colors =
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
            MainActor.assumeIsolated { self?.evaluate(fromTimer: true) }
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
        menuBarH = 24            // new display geometry — let makeStrip re-measure from scratch
        lastKey = ""
        evaluate()
    }

    func updateHover() {
        let p = NSEvent.mouseLocation
        let atTop = p.y >= screen.frame.maxY - menuBarH && p.x >= screen.frame.minX && p.x <= screen.frame.maxX
        if atTop != mouseAtTop { mouseAtTop = atTop; applyVisibility() }
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
        updateHover()
        if let arr = customColors[app.bundleIdentifier ?? ""], arr.count == 3 {
            let c = NSColor(red: arr[0], green: arr[1], blue: arr[2], alpha: 1)
            setColors(s, (c, c))                 // user-picked color overrides sampling
            lastKey = ""
            applyVisibility(animated: !isNew)
            return
        }
        let key = "\(wid)-\(Int(W))x\(Int(H))"
        if let cached = colorCache[key] {        // known window — instant, no capture
            setColors(s, cached)                 // color BEFORE showing: no black flash
            lastKey = key
            // returning to a known window: appear instantly, as if the strip never left
            applyVisibility(animated: !isNew)
            return
        }
        applyVisibility()
        guard key != lastKey else { return }     // capture already in flight
        if colorCache.count > 200 { colorCache.removeAll() }   // window resizes mint new keys forever
        lastKey = key
        let icon = app.icon.map(averageColor) ?? .black
        Task { @MainActor in
            let c = await topEdgeColors(pid: pid) ?? (icon, icon)
            self.colorCache[key] = c
            self.setColors(self.strip, c)
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
        applyVisibility()
        if force {   // disable/exclude must also clear strips resting on other Spaces
            strips.forEach { $0.alphaValue = 0 }
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

    @objc func refreshColor() {
        colorCache.removeAll()
        lastKey = ""
        evaluate()
    }

    @objc func toggleExclude(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        var ex = excluded
        if ex.contains(bid) { ex.remove(bid) } else { ex.insert(bid) }
        excluded = ex
        if excluded.contains(bid) { hide(force: true) } else { evaluate() }
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

// MARK: - Self-check (runs on every launch, fails loudly if sampling breaks)

func selfCheck() {
    let img = NSImage(size: NSSize(width: 8, height: 8))
    img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); img.unlockFocus()
    let a = averageColor(img).usingColorSpace(.deviceRGB)!
    assert(a.redComponent > 0.7 && a.redComponent > a.greenComponent + 0.4
           && a.redComponent > a.blueComponent + 0.4, "averageColor broken")

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
    assert(l.greenComponent > 0.7 && l.blueComponent < 0.3, "edgeColors left broken")
    assert(r.blueComponent > 0.7 && r.greenComponent < 0.3, "edgeColors right broken")
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
