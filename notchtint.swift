// NotchTint — paints the empty menu-bar area around the MacBook notch with the
// top-edge color of the frontmost fullscreen app, so the notch "dissolves" into the UI.
//
// Build:  make            (or: swiftc -O notchtint.swift -o notchtint && codesign -f -s - notchtint)
// Run:    ./notchtint     First launch asks for Screen Recording permission — grant and relaunch.
// A menu-bar item provides Enable/Disable, per-app exclusions, Start at Login and Quit.
import Cocoa
import CoreImage
import ScreenCaptureKit

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

// Per-channel median of the window's top edge, sampled only in the zones left and
// right of the notch. Median ignores outliers (traffic lights, toolbar buttons).
func edgeMedianColor(_ cg: CGImage) -> NSColor? {
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

    var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
    for y in 0..<H {
        for x in 0..<W {
            let fx = Double(x) / Double(W)
            // zones flanking the notch; skip rounded corners and the notch itself
            guard (fx > 0.06 && fx < 0.36) || (fx > 0.64 && fx < 0.94) else { continue }
            let i = (y * W + x) * 4
            rs.append(buf[i]); gs.append(buf[i + 1]); bs.append(buf[i + 2])
        }
    }
    guard !rs.isEmpty else { return nil }
    func med(_ a: [UInt8]) -> CGFloat { let s = a.sorted(); return CGFloat(s[s.count / 2]) / 255 }
    return NSColor(red: med(rs), green: med(gs), blue: med(bs), alpha: 1)
}

// Capture the app's biggest window (its pixels only — neighbours excluded) and
// sample the top edge. Requires Screen Recording permission.
func topEdgeColor(pid: pid_t) async -> NSColor? {
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
    return edgeMedianColor(cg)
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
    var colorCache: [String: NSColor] = [:]   // window+size → sampled color; cleared on theme change
    var pendingHide = 0              // consecutive failed checks; hide only after 2 (survives Space swipes)
    var shouldShow = false           // frontmost window is fullscreen
    var mouseAtTop = false           // cursor in menu-bar zone → yield to the real menu bar
    var enabled = true
    var lastApp: NSRunningApplication?

    var excluded: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "excludedBundleIDs") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "excludedBundleIDs") }
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
        menuBarH = max(f.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 24)
        let rect = NSRect(x: f.minX, y: f.maxY - menuBarH, width: f.width, height: menuBarH)
        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]   // joins the Space it's ordered onto and stays there
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isOpaque = true
        w.alphaValue = 0
        return w
    }

    // Strip belonging to the current Space; created on first visit. Extra strips that
    // migrated here (their Space was closed) get removed.
    func activeStrip() -> NSWindow {
        let here = strips.filter { $0.isOnActiveSpace }
        for extra in here.dropFirst() {
            extra.orderOut(nil)
            strips.removeAll { $0 === extra }
        }
        if let w = here.first { return w }
        let w = makeStrip()
        w.orderFront(nil)          // attaches it to the current Space
        strips.append(w)
        return w
    }

    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "paintbrush.fill", accessibilityDescription: "NotchTint")
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
        lastKey = ""
        evaluate()
    }

    func updateHover() {
        let p = NSEvent.mouseLocation
        let atTop = p.y >= screen.frame.maxY - menuBarH && p.x >= screen.frame.minX && p.x <= screen.frame.maxX
        if atTop != mouseAtTop { mouseAtTop = atTop; applyVisibility() }
    }

    func applyVisibility() {
        // only touch the strip whose Space is active — strips resting on other Spaces
        // keep their alpha and color, so returning to them shows no re-appear animation
        guard let strip, strip.isOnActiveSpace else { return }
        let target: CGFloat = (enabled && shouldShow && !mouseAtTop) ? 1 : 0
        guard strip.alphaValue != target else { return }
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
        strip = activeStrip()
        updateHover()
        applyVisibility()
        let key = "\(wid)-\(Int(W))x\(Int(H))"
        if let cached = colorCache[key] {        // known window — instant, no capture
            strip?.backgroundColor = cached
            lastKey = key
            return
        }
        guard key != lastKey else { return }     // capture already in flight
        lastKey = key
        let fallback = app.icon.map(averageColor) ?? .black
        Task { @MainActor in
            let c = await topEdgeColor(pid: pid) ?? fallback
            self.colorCache[key] = c
            self.strip?.backgroundColor = c
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
        lastKey = ""
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let en = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        en.target = self
        en.state = enabled ? .on : .off
        menu.addItem(en)

        if let app = lastApp, let bid = app.bundleIdentifier {
            let isEx = excluded.contains(bid)
            let it = NSMenuItem(title: (isEx ? "Include " : "Exclude ") + (app.localizedName ?? bid),
                                action: #selector(toggleExclude(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = bid
            menu.addItem(it)
        }

        let refresh = NSMenuItem(title: "Refresh Color", action: #selector(refreshColor), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = FileManager.default.fileExists(atPath: agentPlistPath) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchTint",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 8))
    let m = edgeMedianColor(ctx.makeImage()!)!.usingColorSpace(.deviceRGB)!
    assert(m.blueComponent > 0.7 && m.blueComponent > m.redComponent + 0.4, "edgeMedianColor broken")
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
