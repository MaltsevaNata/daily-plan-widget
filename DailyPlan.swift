// DailyPlan — a menu bar widget showing today's plan as a vertical timeline.
// Reads ~/.daily-plan/plan.json (written each weekday by a Claude scheduled task)
// and redraws every 30s so the "now" line and the next-meeting countdown stay current.
//
// Build: swiftc -O DailyPlan.swift -o DailyPlan
// Lives in the menu bar (next meeting as title): left-click opens the plan in a popover,
// right-click menu can pin it as a floating panel; closing the panel folds it back.

import AppKit

struct PlanEvent: Codable {
    let start: String      // "HH:mm" local
    let end: String
    let title: String
    let url: String?
    let kind: String?      // nil = meeting; "lunch" = personal block (not a meeting)

    var isMeeting: Bool { kind == nil }
}

struct PlanTask: Codable {
    let title: String
    let ref: String?       // e.g. Jira key
    let url: String?
}

struct Plan: Codable {
    let date: String       // "yyyy-MM-dd"
    let generatedAt: String?
    let events: [PlanEvent]
    let priorities: [PlanTask]
    let notes: [String]?
}

let planURL = ProcessInfo.processInfo.environment["DAILY_PLAN_FILE"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".daily-plan/plan.json")
let doneURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".daily-plan/done.json")

func minutes(_ hhmm: String) -> Int {
    let p = hhmm.split(separator: ":").compactMap { Int($0) }
    return p.count == 2 ? p[0] * 60 + p[1] : 0
}

func today() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
}

func nowMinutes() -> Int {
    let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}

// "[DISC] Daily Scrum" -> "Daily Scrum"
func shortTitle(_ t: String) -> String {
    t.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
}

func duration(_ m: Int) -> String {
    m >= 60 ? (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h\(m % 60)m") : "\(m)m"
}

// MARK: - Timeline view

final class TimelineView: NSView {
    var plan: Plan?
    var doneTitles: Set<String> = []
    var onToggle: ((String) -> Void)?

    private var hits: [(rect: NSRect, action: () -> Void)] = []
    private let pxPerHour: CGFloat = 36
    private let pad: CGFloat = 12
    private let gutter: CGFloat = 40
    private let minFocus = 60   // free gaps shorter than this aren't shown as focus

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func requiredHeight() -> CGFloat { paint(draw: false) }

    override func draw(_ dirtyRect: NSRect) { _ = paint(draw: true) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hits.first { $0.rect.contains(p) }?.action()
    }

    override func resetCursorRects() {
        for h in hits { addCursorRect(h.rect, cursor: .pointingHand) }
    }

    // Lays out (and, when draw is true, paints) the whole view; returns the content height.
    private func paint(draw: Bool) -> CGFloat {
        hits = []
        let W = bounds.width
        var y: CGFloat = 10

        let df = DateFormatter(); df.dateFormat = "EEEE, d MMMM"
        y += text(df.string(from: Date()), x: pad, y: y, width: W - 2 * pad,
                  font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor, draw: draw) + 6

        guard let plan else {
            y += text("No plan yet. It's generated weekdays at 09:00 into ~/.daily-plan/plan.json",
                      x: pad, y: y, width: W - 2 * pad, font: .systemFont(ofSize: 12),
                      color: .secondaryLabelColor, draw: draw)
            return y + 12
        }
        let isToday = plan.date == today()
        if !isToday {
            y += text("Plan is from \(plan.date)", x: pad, y: y, width: W - 2 * pad,
                      font: .systemFont(ofSize: 11, weight: .medium), color: .systemRed, draw: draw) + 4
        }

        // --- Timeline grid
        let events = plan.events.sorted { minutes($0.start) < minutes($1.start) }
        let startH = min(10, events.map { minutes($0.start) / 60 }.min() ?? 10)
        let endH = max(19, events.map { (minutes($0.end) + 59) / 60 }.max() ?? 19)
        let top = y + 6
        func yFor(_ m: Int) -> CGFloat { top + CGFloat(m - startH * 60) / 60 * pxPerHour }
        let x0 = pad + gutter, x1 = W - pad
        let nowM = nowMinutes()

        // Blocks are collected first so the grid can be drawn around them:
        // they're translucent, and lines showing through read as strikethroughs.
        var blocks: [(rect: NSRect, paint: () -> Void)] = []
        func addBlock(_ r: NSRect, tint: NSColor, title: String, subtitle: String?, past: Bool, url: String?) {
            blocks.append((r.insetBy(dx: 1, dy: 1), { [unowned self] in
                self.block(r, tint: tint, title: title, subtitle: subtitle, past: past, url: url, draw: draw)
            }))
        }

        // --- Focus blocks: free gaps between meetings inside the visible range
        var cursor = startH * 60
        var gaps: [(Int, Int)] = []
        for e in events {
            let s = minutes(e.start), en = minutes(e.end)
            if s - cursor >= minFocus { gaps.append((cursor, s)) }
            cursor = max(cursor, en)
        }
        if endH * 60 - cursor >= minFocus { gaps.append((cursor, endH * 60)) }
        for (s, e) in gaps {
            let past = isToday && e <= nowM
            addBlock(NSRect(x: x0 + 3, y: yFor(s), width: x1 - x0 - 3, height: yFor(e) - yFor(s)),
                     tint: .systemGreen, title: "Focus \(duration(e - s))", subtitle: nil,
                     past: past, url: nil)
        }

        // --- Meetings, overlapping ones split into side-by-side lanes
        var i = 0
        while i < events.count {
            var cluster = [events[i]]
            var clusterEnd = minutes(events[i].end)
            var j = i + 1
            while j < events.count && minutes(events[j].start) < clusterEnd {
                cluster.append(events[j]); clusterEnd = max(clusterEnd, minutes(events[j].end)); j += 1
            }
            var laneEnds: [Int] = []
            var lanes: [Int] = []
            for e in cluster {
                if let l = laneEnds.firstIndex(where: { $0 <= minutes(e.start) }) {
                    laneEnds[l] = minutes(e.end); lanes.append(l)
                } else {
                    laneEnds.append(minutes(e.end)); lanes.append(laneEnds.count - 1)
                }
            }
            let laneW = (x1 - x0 - 3) / CGFloat(laneEnds.count)
            for (k, e) in cluster.enumerated() {
                let s = minutes(e.start), en = minutes(e.end)
                addBlock(NSRect(x: x0 + 3 + CGFloat(lanes[k]) * laneW, y: yFor(s), width: laneW, height: yFor(en) - yFor(s)),
                         tint: e.isMeeting ? .systemBlue : .systemOrange, title: shortTitle(e.title), subtitle: "\(e.start)–\(e.end)",
                         past: isToday && en <= nowM, url: e.url)
            }
            i = j
        }

        // --- Grid (hour labels + lines, clipped out under blocks), then the blocks on top
        if draw {
            let mono = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            for h in startH...endH {
                _ = text(String(format: "%02d:00", h), x: pad, y: yFor(h * 60) - 6, width: gutter,
                         font: mono, color: .tertiaryLabelColor, draw: true)
            }
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: bounds)
            for b in blocks { clip.append(NSBezierPath(roundedRect: b.rect, xRadius: 5, yRadius: 5)) }
            clip.windingRule = .evenOdd
            clip.addClip()
            NSColor.separatorColor.setFill()
            for h in startH...endH { NSRect(x: x0, y: yFor(h * 60), width: x1 - x0, height: 0.5).fill() }
            NSRect(x: x0, y: top, width: 0.5, height: yFor(endH * 60) - top).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        for b in blocks { b.paint() }

        // --- Now line
        if draw && isToday && nowM >= startH * 60 && nowM <= endH * 60 {
            let ny = yFor(nowM)
            NSColor.systemRed.setFill()
            NSRect(x: x0 - 2, y: ny - 0.75, width: x1 - x0 + 2, height: 1.5).fill()
            NSBezierPath(ovalIn: NSRect(x: x0 - 4, y: ny - 3.5, width: 7, height: 7)).fill()
        }

        y = yFor(endH * 60) + 14

        // --- Priorities
        y += text("Priorities", x: pad, y: y, width: W - 2 * pad,
                  font: .systemFont(ofSize: 11, weight: .bold), color: .secondaryLabelColor, draw: draw) + 4
        for t in plan.priorities {
            let isDone = doneTitles.contains(t.title)
            let fg: NSColor = isDone ? .tertiaryLabelColor : .labelColor
            _ = text(isDone ? "☑︎" : "☐", x: pad, y: y - 1, width: 18,
                     font: .systemFont(ofSize: 14), color: fg, draw: draw)
            hits.append((NSRect(x: pad - 2, y: y - 2, width: 20, height: 20), { [weak self] in self?.onToggle?(t.title) }))
            var x = pad + 20
            if let ref = t.ref {
                let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
                let w = (ref as NSString).size(withAttributes: [.font: font]).width
                _ = text(ref, x: x, y: y, width: w + 2, font: font,
                         color: isDone ? .tertiaryLabelColor : .systemBlue, draw: draw)
                if let s = t.url, let url = URL(string: s) {
                    hits.append((NSRect(x: x, y: y, width: w, height: 16), { NSWorkspace.shared.open(url) }))
                }
                x += w + 5
            }
            let h = text(t.title, x: x, y: y, width: W - pad - x, font: .systemFont(ofSize: 12),
                         color: fg, strike: isDone, draw: draw)
            y += max(18, h) + 3
        }

        // --- Notes (focus blocks are already visible on the timeline)
        let notes = (plan.notes ?? []).filter { !$0.lowercased().hasPrefix("focus block") }
        if !notes.isEmpty {
            y += 6
            for n in notes {
                _ = text("•", x: pad, y: y, width: 10, font: .systemFont(ofSize: 11),
                         color: .secondaryLabelColor, draw: draw)
                y += text(n, x: pad + 10, y: y, width: W - 2 * pad - 10, font: .systemFont(ofSize: 11),
                          color: .secondaryLabelColor, draw: draw) + 2
            }
        }
        return y + 10
    }

    private func block(_ r: NSRect, tint: NSColor, title: String, subtitle: String?,
                       past: Bool, url: String?, draw: Bool) {
        let rect = r.insetBy(dx: 1, dy: 1)
        if let s = url, let u = URL(string: s) {
            hits.append((rect, { NSWorkspace.shared.open(u) }))
        }
        guard draw else { return }
        tint.withAlphaComponent(past ? 0.07 : 0.2).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let fg = tint.withAlphaComponent(past ? 0.45 : 1)
        let inner = rect.insetBy(dx: 6, dy: 2)
        if rect.height >= 30, let subtitle {
            _ = text(title, x: inner.minX, y: inner.minY, width: inner.width, maxHeight: 14,
                     font: .systemFont(ofSize: 11, weight: .semibold), color: fg, draw: true)
            _ = text(subtitle, x: inner.minX, y: inner.minY + 13, width: inner.width, maxHeight: 14,
                     font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular), color: fg, draw: true)
        } else {
            _ = text(title, x: inner.minX, y: inner.minY, width: inner.width, maxHeight: inner.height + 2,
                     font: .systemFont(ofSize: 11, weight: .semibold), color: fg, draw: true)
        }
    }

    // Draws wrapped (or, with maxHeight, truncated) text; returns its height.
    @discardableResult
    private func text(_ s: String, x: CGFloat, y: CGFloat, width: CGFloat, maxHeight: CGFloat? = nil,
                      font: NSFont, color: NSColor, strike: Bool = false, draw: Bool) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = maxHeight == nil ? .byWordWrapping : .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let str = NSAttributedString(string: s, attributes: attrs)
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        var h = ceil(str.boundingRect(with: NSSize(width: max(width, 1), height: 10_000), options: opts).height)
        if let maxHeight { h = min(h, maxHeight) }
        if draw { str.draw(with: NSRect(x: x, y: y, width: width, height: h), options: opts) }
        return h
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var panelView: TimelineView!
    var popover: NSPopover!
    var popoverView: TimelineView!
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var pinItem: NSMenuItem!
    var onTopItem: NSMenuItem!
    var timer: Timer?
    var lastModified: Date?
    var plan: Plan?
    var done: [String: [String]] = [:]   // date -> done task titles

    let width: CGFloat = 320

    // Folded (menu bar only) by default; "pinned" shows the floating panel too.
    var pinned: Bool {
        get { UserDefaults.standard.bool(forKey: "pinned") }
        set { UserDefaults.standard.set(newValue, forKey: "pinned") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        buildPopover()
        buildPanel()
        loadDone()
        reload(force: true)
        if pinned { panel.orderFrontRegardless() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.reload(force: false)
        }
    }

    // MARK: UI

    func makeScroll(_ view: TimelineView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        view.autoresizingMask = [.width]
        view.onToggle = { [weak self] title in self?.toggleDone(title) }
        scroll.documentView = view
        return scroll
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "📋"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        menu = NSMenu()
        pinItem = menu.addItem(withTitle: "Pin as Floating Panel", action: #selector(togglePinned), keyEquivalent: "")
        onTopItem = menu.addItem(withTitle: "Panel Always on Top", action: #selector(toggleOnTop), keyEquivalent: "")
        menu.addItem(withTitle: "Reload", action: #selector(forceReload), keyEquivalent: "r")
        menu.addItem(withTitle: "Open plan.json", action: #selector(openPlanFile), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    func buildPopover() {
        popoverView = TimelineView()
        let vc = NSViewController()
        vc.view = makeScroll(popoverView)
        popover = NSPopover()
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: width, height: 480)
        popover.behavior = .transient
    }

    func buildPanel() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: width, height: 560)
        let origin = NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16)
        panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = UserDefaults.standard.object(forKey: "onTop") as? Bool == false ? .normal : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setFrameAutosaveName("DailyPlanPanel")

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        panel.contentView = blur

        panelView = TimelineView()
        let scroll = makeScroll(panelView)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: blur.topAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -4),
        ])
    }

    // Closing the panel folds it back into the menu bar.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        pinned = false
        panel.orderOut(nil)
        return false
    }

    func windowDidResize(_ notification: Notification) { render() }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            pinItem.state = pinned ? .on : .off
            onTopItem.state = panel.level == .floating ? .on : .off
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil   // keep left-click for the popover
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            render()
            let h = min(popoverView.requiredHeight(), (NSScreen.main?.visibleFrame.height ?? 800) - 60)
            popover.contentSize = NSSize(width: width, height: h)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func togglePinned() {
        pinned.toggle()
        if pinned { popover.performClose(nil); panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    @objc func toggleOnTop() {
        let on = panel.level != .floating
        panel.level = on ? .floating : .normal
        UserDefaults.standard.set(on, forKey: "onTop")
    }

    @objc func forceReload() { reload(force: true) }

    @objc func openPlanFile() { NSWorkspace.shared.open(planURL) }

    // MARK: Data

    func reload(force: Bool) {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: planURL.path))?[.modificationDate] as? Date
        if force || mtime != lastModified {
            lastModified = mtime
            if let data = try? Data(contentsOf: planURL) {
                plan = try? JSONDecoder().decode(Plan.self, from: data)
            } else {
                plan = nil
            }
        }
        render()   // always re-render: "now" moves even if the file didn't change
    }

    func loadDone() {
        if let data = try? Data(contentsOf: doneURL),
           let d = try? JSONDecoder().decode([String: [String]].self, from: data) {
            done = d
        }
    }

    func toggleDone(_ title: String) {
        let day = today()
        var list = done[day] ?? []
        if let i = list.firstIndex(of: title) { list.remove(at: i) } else { list.append(title) }
        done = [day: list]   // keep only today's state
        if let data = try? JSONEncoder().encode(done) { try? data.write(to: doneURL) }
        render()
    }

    // MARK: Rendering

    func render() {
        let doneToday = Set(done[today()] ?? [])
        for v in [panelView, popoverView].compactMap({ $0 }) {
            v.plan = plan
            v.doneTitles = doneToday
            if let w = v.enclosingScrollView?.contentSize.width, w > 0 { v.setFrameSize(NSSize(width: w, height: v.frame.height)) }
            v.setFrameSize(NSSize(width: v.frame.width, height: v.requiredHeight()))
            v.needsDisplay = true
            v.window?.invalidateCursorRects(for: v)
        }
        let upcoming = (plan?.date == today() ? plan?.events ?? [] : [])
            .filter { $0.isMeeting && minutes($0.end) > nowMinutes() }
            .sorted { minutes($0.start) < minutes($1.start) }
        statusItem.button?.title = statusTitle(upcoming.first)
    }

    // Menu bar text: "● Daily Scrum" while running, "25m Daily Scrum" within the hour, "13:45 Daily Scrum" later.
    func statusTitle(_ next: PlanEvent?) -> String {
        guard let next else { return "📋" }
        var name = shortTitle(next.title)
        if name.count > 20 { name = String(name.prefix(19)) + "…" }
        let startsIn = minutes(next.start) - nowMinutes()
        if startsIn <= 0 { return "● \(name)" }
        if startsIn < 60 { return "\(startsIn)m \(name)" }
        return "\(next.start) \(name)"
    }
}

// `DailyPlan --snapshot out.png [dark]` renders the current plan to a PNG and exits (for previews).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let dark = CommandLine.arguments.contains("dark")
    let v = TimelineView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
    v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    if let data = try? Data(contentsOf: planURL) { v.plan = try? JSONDecoder().decode(Plan.self, from: data) }
    v.setFrameSize(NSSize(width: 320, height: v.requiredHeight()))
    let out = NSImage(size: v.bounds.size, flipped: true) { rect in
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        rect.fill()
        v.draw(rect)
        return true
    }
    var tiff: Data?
    v.appearance!.performAsCurrentDrawingAppearance { tiff = out.tiffRepresentation }
    let png = NSBitmapImageRep(data: tiff!)!.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
