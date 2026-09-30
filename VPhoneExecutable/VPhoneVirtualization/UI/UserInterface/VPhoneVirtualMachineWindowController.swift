import AppKit
import Foundation
import Virtualization
import VPhoneCoreKit

@MainActor
class VPhoneVirtualMachineWindowController: NSObject {
    private var windowController: NSWindowController?
    private weak var control: VPhoneGuestControl?
    private weak var virtualMachineView: VPhoneVirtualMachineView?
    private weak var keySender: VPhoneVirtualMachineKeySender?
    private(set) var touchIDMonitor: VPhoneTouchIDMonitor?
    private var ecid: String?
    // The VM bundle's directory name, which is what `vm list` calls this guest.
    private var name = "VPHONE"
    private var cornerObserver: NSObjectProtocol?
    private var clipboardObservers: [NSObjectProtocol] = []
    private var lastHostClipboardChange = NSPasteboard.general.changeCount
    private var lastGuestClipboardChange = 0
    // Handset corner radius as a fraction of panel width, so a resized window
    // keeps the shape. 48 pt on a 390 pt-wide panel, .continuous, fitted to
    // the iPhone Mirroring window: both bodies are 780x1688 px at 2x.
    // Verify by capturing both windows unhovered with `screencapture -l <id>`
    // and comparing the per-row alpha edge down each corner — the alpha
    // channel gives the shape, luminance does not (the guest's own wallpaper
    // is black at the corners).
    private var cornerRadiusFraction: CGFloat = 0
    private var screenObserver: NSObjectProtocol?
    private weak var chromeBacking: VPhoneChromeBacking?
    // The guest panel at its own point size, the View menu's Larger. Every
    // other View size is this scaled by panelScale across and heightScale(for:) down.
    private var basePanelSize: NSSize = .zero
    private var panelScale: CGFloat = 1
    private var menuKeyMonitor: Any?

    var captureView: VPhoneVirtualMachineView? {
        virtualMachineView
    }

    func showWindow(
        for vm: VZVirtualMachine,
        screenWidth: Int,
        screenHeight: Int,
        screenScale: Double,
        keySender: VPhoneVirtualMachineKeySender,
        control: VPhoneGuestControl,
        ecid: String?,
        sceneIdentifier: String,
        name: String,
    ) {
        self.control = control
        self.keySender = keySender
        self.ecid = ecid
        self.name = name

        let view = VPhoneVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.keySender = keySender
        view.control = control
        view.clipboardSync = VPhoneClipboardSync(control: control)
        virtualMachineView = view
        let vmView: NSView = view

        // 1:1 with the guest panel's points, which is what iPhone Mirroring draws
        // for the same handset: a 1170x2532 panel at scale 3 is 390x844 pt in both.
        let scale = CGFloat(screenScale)
        let windowSize = NSSize(
            width: CGFloat(screenWidth) / scale,
            height: CGFloat(screenHeight) / scale,
        )

        // iPhone Mirroring's window is 406x890 around the same 390x844 body: 8 pt
        // at the sides and below, 38 pt above, all transparent. Matching it
        // keeps the panel in the same place when a tiling WM pins the window to
        // the top of a node, and leaves the top strip free for a hover toolbar.
        let contentSize = NSSize(
            width: windowSize.width + 16, height: windowSize.height + 46
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )

        window.isReleasedWhenClosed = false
        VPhoneAlert.hostWindow = window
        window.title = "\(name) [loading]"
        window.subtitle = makeSubtitle(ip: nil)

        let panelContainer = NSView(frame: NSRect(origin: .zero, size: contentSize))
        vmView.frame = NSRect(
            x: 8, y: 8, width: windowSize.width, height: windowSize.height
        )
        vmView.autoresizingMask = [.width, .height]
        panelContainer.addSubview(vmView)
        window.contentView = panelContainer

        // Handset chrome: the guest screen is the whole window, with the device's
        // own corner radius clipped into it. `.titled` stays in the mask because a
        // borderless window cannot become key without an NSWindow subclass, and
        // key status is what feeds the guest its keyboard. The bar is hidden, not
        // removed: title and subtitle still carry VM state to accessibility
        // clients and to the window menu.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Not movable by background: the content view is the guest's touchscreen,
        // and a background drag would move the window on every press-and-hold.
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        // Locked to the handset size. A tiling window manager resizes through
        // Accessibility, which AppKit clamps to these bounds, so the window keeps
        // its shape in a tile instead of stretching to the node.
        installHoverChrome(in: window, over: panelContainer)
        window.minSize = contentSize
        window.maxSize = contentSize
        // The window is locked to one of the View sizes; full screen would
        // stretch the guest panel, so the Window menu must not offer it.
        window.collectionBehavior.insert(.fullScreenNone)
        cornerRadiusFraction = 48 / windowSize.width
        vmView.wantsLayer = true
        vmView.layer?.masksToBounds = true
        vmView.layer?.cornerCurve = .continuous
        applyCornerRadius(to: vmView)
        cornerObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyCornerRadius(to: vmView) }
        }
        basePanelSize = windowSize
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPanelSize(to: window, panel: vmView) }
        }
        // Every VM directory keeps its own window frame; a new VM opens centred.
        let sceneName = "vphone-scene-\(sceneIdentifier)"
        window.identifier = NSUserInterfaceItemIdentifier(sceneName)
        if !window.setFrameUsingName(sceneName) {
            window.center()
        }
        window.setFrameAutosaveName(sceneName)
        tileAwayFromOtherGuests(window)

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        windowController = controller

        // capturesSystemKeys lets the VM view take every shortcut before the menu
        // bar sees it. Offer each key press to the menu first; the guest gets
        // only what no enabled menu item handles.
        menuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            let handledByMenu = MainActor.assumeIsolated {
                guard let window, event.window === window else { return false }
                return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
            }
            return handledByMenu ? nil : event
        }

        keySender.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        observeClipboard(window: window)

        let monitor = VPhoneTouchIDMonitor()
        monitor.start(control: control, window: window)
        touchIDMonitor = monitor

        refreshTitle()
    }

    /// Writes the guest's connection state into the titlebar.
    ///
    /// `VPhoneGuestControl` sets `isConnected` and `guestIPAddress` before it calls
    /// `onConnect`, and clears both before `onDisconnect`, so those two
    /// callbacks are the only moments this can change.
    func refreshTitle() {
        guard let window = windowController?.window, let control else { return }
        // Assigning either one dirties the titlebar and relayouts it, so only
        // write on an actual change.
        let title = control.isConnected ? "\(name) [connected]" : "\(name) [disconnected]"
        let subtitle = makeSubtitle(ip: control.isConnected ? control.guestIPAddress : nil)
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
    }

    // Clipboard follows focus, the way iPhone Mirroring shares one: whatever was
    // copied on the Mac is on the guest pasteboard when the window takes focus,
    // and whatever the guest copied is on the Mac's when it gives focus back.
    // Change counts on both sides stop the two from overwriting each other.
    private func observeClipboard(window _: NSWindow) {
        let center = NotificationCenter.default
        clipboardObservers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pushHostClipboard() }
            })
        clipboardObservers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pullGuestClipboard() }
            })
    }

    private func pushHostClipboard() {
        guard let control, control.isConnected else {
            print("[clipboard] push skipped: guest not connected")
            return
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastHostClipboardChange,
              let text = pasteboard.string(forType: .string)
        else { return }
        lastHostClipboardChange = pasteboard.changeCount
        print("[clipboard] pushing \(text.count) characters to the guest")
        Task {
            do { try await control.clipboardSet(text: text) } catch {
                print("[clipboard] push to guest failed: \(error)")
            }
        }
    }

    private func pullGuestClipboard() {
        guard let control, control.isConnected else { return }
        // Something copied on the Mac since the last sync outranks the guest's
        // pasteboard: it is what the user will paste next, here or in the guest.
        guard NSPasteboard.general.changeCount == lastHostClipboardChange else { return }
        Task { @MainActor in
            guard let content = try? await control.clipboardGet(),
                  content.changeCount != lastGuestClipboardChange,
                  let text = content.text, !text.isEmpty
            else { return }
            lastGuestClipboardChange = content.changeCount
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            lastHostClipboardChange = pasteboard.changeCount
        }
    }

    private func applyCornerRadius(to view: NSView) {
        let radius = view.bounds.width * cornerRadiusFraction
        view.layer?.cornerRadius = radius
        chromeBacking?.bottomRadius = radius * 51.5 / 48
    }

    /// The scale the View menu last applied, which is what its check mark shows.
    var currentPanelScale: CGFloat { panelScale }

    /// Panel scale from the View menu. 1 is the guest panel drawn 1:1.
    func setPanelScale(_ factor: CGFloat) {
        panelScale = factor
        guard let window = windowController?.window, let panel = virtualMachineView else { return }
        applyPanelSize(to: window, panel: panel)
    }

    // MARK: - Tiling

    /// Move `window` clear of guest windows belonging to other vphone-cli
    /// processes, so booting a second guest tiles beside the first instead of
    /// landing exactly on top of it.
    ///
    /// Only this window moves. Reaching into another process's windows needs the
    /// Accessibility API and the permission prompt that comes with it, and the
    /// window server is enough to see where they are.
    private func tileAwayFromOtherGuests(_ window: NSWindow) {
        let occupied = Self.otherGuestWindowFrames()
        guard !occupied.isEmpty,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        let origin = VPhoneWindowTiling.origin(
            for: window.frame.size, occupied: occupied, visibleFrame: visible)
        window.setFrameOrigin(origin)
    }

    /// On-screen window frames owned by other processes running this same
    /// executable, in AppKit screen coordinates.
    ///
    /// `kCGWindowBounds` is top-left origin measured down from the primary
    /// display's top edge, which is not what NSWindow frames use.
    private static func otherGuestWindowFrames() -> [NSRect] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownName = ProcessInfo.processInfo.processName
        guard let primaryTop = NSScreen.screens.first?.frame.maxY,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
              as? [[String: Any]]
        else { return [] }

        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerName as String] as? String == ownName,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"]
            else { return nil }
            return NSRect(x: x, y: primaryTop - y - h, width: w, height: h)
        }
    }

    /// Resize the locked window to the current scale, shrunk to fit the screen it
    /// sits on. minSize and maxSize are equal, so both have to move before
    /// setContentSize takes.
    private func applyPanelSize(to window: NSWindow, panel: NSView) {
        var panelSize = NSSize(
            width: (basePanelSize.width * panelScale).rounded(),
            height: (basePanelSize.height * VPhoneMenuController.heightScale(for: panelScale)).rounded()
        )
        if let visible = window.screen?.visibleFrame.size {
            let fit = min(
                1, min((visible.width - 16) / panelSize.width, (visible.height - 46) / panelSize.height)
            )
            if fit < 1 {
                panelSize = NSSize(width: panelSize.width * fit, height: panelSize.height * fit)
            }
        }

        let contentSize = NSSize(width: panelSize.width + 16, height: panelSize.height + 46)
        guard abs(contentSize.width - window.minSize.width) > 0.5 else { return }

        window.minSize = contentSize
        window.maxSize = contentSize
        window.setContentSize(contentSize)
        // Autoresizing leaves the VZ view at its old size on a shrink, so the
        // panel is placed outright, 8 pt in from the left and bottom.
        panel.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: panelSize)
        cornerRadiusFraction = 48 / panelSize.width
        applyCornerRadius(to: panel)
    }

    // MARK: - Hover chrome

    /// iPhone Mirroring's hover chrome, measured off `screencapture -l` of its
    /// window at 2x: a grey backing, traffic lights centred 18.75 pt down on a
    /// 23 pt pitch from 15.75 pt in, Home Screen and App Switcher centred 75.75
    /// and 28.5 pt in from the right. The sRGB greys set here read back from a
    /// capture as iPhone Mirroring's own: backing #353535, glyphs #adadad. All of
    /// it sits at alpha 0 until the pointer is over the 38 pt strip.
    ///
    /// The lights draw 14 pt with a ring only when the binary is stamped SDK 26+
    /// (xcodebuild stamps the build SDK); otherwise AppKit draws legacy 12 pt ones.
    /// AppKit owns the titlebar's own lights' layout, so those stay hidden and
    /// free-standing ones sit on the measured centres.
    private func installHoverChrome(in window: NSWindow, over content: NSView) {
        var lights: [NSButton] = []
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            window.standardWindowButton(type)?.isHidden = true
            guard let light = NSWindow.standardWindowButton(type, for: window.styleMask) else { continue }
            light.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(light)
            NSLayoutConstraint.activate([
                light.centerXAnchor.constraint(
                    equalTo: content.leadingAnchor, constant: 15.75 + 23 * CGFloat(index)),
                light.centerYAnchor.constraint(equalTo: content.topAnchor, constant: 18.75),
            ])
            lights.append(light)
        }
        // Size is locked, so zoom has nothing to do.
        lights.last?.isEnabled = false
        // Tooltips show on hover whichever app is active, as in iPhone Mirroring.
        window.allowsToolTipsWhenApplicationIsInactive = true

        let backing = VPhoneChromeBacking(frame: content.bounds)
        backing.autoresizingMask = [.width, .height]
        content.addSubview(backing, positioned: .below, relativeTo: nil)
        chromeBacking = backing

        let home = makeChromeButton("Home Screen", image: Self.homeScreenGlyph, action: #selector(chromeHome))
        let switcher = makeChromeButton(
            "App Switcher",
            image: NSImage(systemSymbolName: "iphone.app.switcher", accessibilityDescription: "App Switcher")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)),
            action: #selector(chromeAppSwitcher)
        )
        // Centres and hover pills, measured off iPhone Mirroring's at 2x.
        let placements: [(NSButton, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)] = [
            (home, 75.75, 18.75, 38, 21), (switcher, 28.5, 19, 40.5, 24),
        ]
        for (button, x, y, width, height) in placements {
            content.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: content.trailingAnchor, constant: -x),
                button.centerYAnchor.constraint(equalTo: content.topAnchor, constant: y),
                button.widthAnchor.constraint(equalToConstant: width),
                button.heightAnchor.constraint(equalToConstant: height),
            ])
        }

        let chrome = [backing, home, switcher] + lights
        chrome.forEach { $0.alphaValue = 0 }
        let strip = VPhoneHoverStrip(
            frame: NSRect(x: 0, y: content.bounds.height - 38, width: content.bounds.width, height: 38)
        )
        strip.autoresizingMask = [.width, .minYMargin]
        strip.onHover = { [weak window] inside in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                chrome.forEach { $0.animator().alphaValue = inside ? 1 : 0 }
            } completionHandler: {
                // The shadow is cut from the window's alpha; the backing changes it.
                window?.invalidateShadow()
            }
        }
        content.addSubview(strip)
    }

    private func makeChromeButton(_ label: String, image: NSImage?, action: Selector) -> NSButton {
        let button = VPhoneChromeButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = NSColor(srgbGray: 0x9E)
        button.toolTip = label
        button.wantsLayer = true
        // The press look is VPhoneChromeButton's, not the cell's brightened glyph.
        (button.cell as? NSButtonCell)?.highlightsBy = []
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        // The guest view keeps first responder; it is what feeds the keyboard.
        button.refusesFirstResponder = true
        return button
    }

    /// iPhone Mirroring's Home Screen glyph is its own `app.grid.3x3`, not a
    /// public symbol: 2.9 pt tiles on a 4 pt pitch. The canvas is a point taller
    /// than the grid, empty at the top, so centring it drops the grid onto
    /// iPhone Mirroring's pixel rows.
    private static let homeScreenGlyph: NSImage = {
        let image = NSImage(size: NSSize(width: 11, height: 12), flipped: false) { _ in
            NSColor.black.setFill()
            for row in 0..<3 {
                for column in 0..<3 {
                    let tile = NSRect(x: CGFloat(column) * 4, y: CGFloat(row) * 4, width: 2.9, height: 2.9)
                    NSBezierPath(roundedRect: tile, xRadius: 0.75, yRadius: 0.75).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Home Screen"
        return image
    }()

    @objc private func chromeHome() { keySender?.sendHome() }
    @objc private func chromeAppSwitcher() { keySender?.sendAppSwitcher() }

    private func makeSubtitle(ip: String?) -> String {
        switch (ecid, ip) {
        case let (ecid?, ip?): "\(ecid) — \(ip)"
        case (let ecid?, nil): ecid
        case (nil, let ip?): ip
        case (nil, nil): ""
        }
    }

}

/// The hover chrome's backing: continuous corners, 19.75 pt at the top and
/// 51.5 pt at the bottom around the 48 pt panel, and a 1 pt top edge in two
/// half-point bands, lighter above. The mask is two halves because one layer
/// takes one corner radius.
private final class VPhoneChromeBacking: NSView {
    private let upper = CALayer()
    private let lower = CALayer()
    private let edgeLight = CALayer()
    private let edgeDark = CALayer()

    var bottomRadius: CGFloat = 51.5 {
        didSet { reshape() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbGray: 0x28).cgColor
        let mask = CALayer()
        for (half, corners) in [(upper, CACornerMask([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])),
                                (lower, CACornerMask([.layerMinXMinYCorner, .layerMaxXMinYCorner]))] {
            half.backgroundColor = .black
            half.cornerCurve = .continuous
            half.maskedCorners = corners
            mask.addSublayer(half)
        }
        upper.cornerRadius = 19.75
        layer?.mask = mask
        edgeLight.backgroundColor = NSColor(srgbGray: 0x53).cgColor
        edgeDark.backgroundColor = NSColor(srgbGray: 0x3F).cgColor
        layer?.addSublayer(edgeLight)
        layer?.addSublayer(edgeDark)
        reshape()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reshape()
    }

    private func reshape() {
        let w = bounds.width, h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.mask?.frame = bounds
        upper.frame = CGRect(x: 0, y: h / 2 - 1, width: w, height: h / 2 + 1)
        lower.frame = CGRect(x: 0, y: 0, width: w, height: h / 2 + 1)
        lower.cornerRadius = bottomRadius
        edgeLight.frame = CGRect(x: 0, y: h - 0.5, width: w, height: 0.5)
        edgeDark.frame = CGRect(x: 0, y: h - 1, width: w, height: 0.5)
        CATransaction.commit()
    }
}

/// Reports the pointer entering and leaving the top strip. Never takes a click:
/// the titlebar above it and the guest below it own those.
private final class VPhoneHoverStrip: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with _: NSEvent) { onHover?(true) }
    override func mouseExited(with _: NSEvent) { onHover?(false) }
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// iPhone Mirroring's hover: a pill of white at 7.5% behind the glyph, which
/// brightens from #9e to #e1. The pill is the button's own bounds. A press
/// doubles the pill's white and leaves the glyph lit until the button lets go.
private final class VPhoneChromeButton: NSButton {
    // A symbol image gives the button alignment insets, and constraints size the
    // alignment rect: the frame, and the pill with it, would stand taller than set.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// Only this one is swapped on update: the tooltip rides on AppKit's own area.
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        area.map(removeTrackingArea)
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        self.area = area
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func mouseEntered(with _: NSEvent) { hover(true) }
    override func mouseExited(with _: NSEvent) { hover(false) }

    /// `NSButton.mouseDown` tracks the press until the button is let go.
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.15).cgColor
        contentTintColor = NSColor(srgbGray: 0xE1)
        super.mouseDown(with: event)
        guard let window else { return }
        hover(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    private func hover(_ inside: Bool) {
        layer?.backgroundColor = inside ? NSColor(white: 1, alpha: 0.075).cgColor : nil
        contentTintColor = NSColor(srgbGray: inside ? 0xE1 : 0x9E)
    }
}

private extension NSColor {
    /// A grey from its 0-255 sRGB channel value.
    convenience init(srgbGray value: Int) {
        let v = CGFloat(value) / 255
        self.init(srgbRed: v, green: v, blue: v, alpha: 1)
    }
}
