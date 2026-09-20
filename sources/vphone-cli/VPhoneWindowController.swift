import AppKit
import Foundation
import Virtualization

@MainActor
class VPhoneWindowController: NSObject {
    private var windowController: NSWindowController?
    private var statusTimer: Timer?
    private weak var control: VPhoneControl?
    private weak var virtualMachineView: VPhoneVirtualMachineView?
    private(set) var touchIDMonitor: VPhoneTouchIDMonitor?
    private var ecid: String?
    // The VM bundle's directory name, which is what `vm list` calls this guest.
    private var name = "VPHONE"
    private var cornerObserver: NSObjectProtocol?
    private var clipboardObservers: [NSObjectProtocol] = []
    private var lastHostClipboardChange = NSPasteboard.general.changeCount
    private var lastGuestClipboardChange = 0
    // Handset corner radius as a fraction of panel width, so a resized window
    // keeps the shape. 43.25 pt on a 390 pt-wide panel, matched against the
    // iPhone Mirroring window: both bodies are 780x1688 px at 2x, and with
    // .continuous corners the topmost opaque row is inset 106 px there.
    // Verify by capturing both windows with `screencapture -l <id>` and
    // comparing that inset — the alpha channel gives the shape, luminance does
    // not (the guest's own wallpaper is black at the corners).
    private var cornerRadiusFraction: CGFloat = 0
    private var screenObserver: NSObjectProtocol?
    // The guest panel at its own point size, the View menu's Larger. Every
    // other View size is this multiplied by panelScale.
    private var basePanelSize: NSSize = .zero
    private var panelScale: CGFloat = 1

    var captureView: VPhoneVirtualMachineView? {
        virtualMachineView
    }

    func showWindow(
        for vm: VZVirtualMachine, screenWidth: Int, screenHeight: Int, screenScale: Double,
        keyHelper: VPhoneKeyHelper, control: VPhoneControl, ecid: String?, name: String
    ) {
        self.control = control
        self.ecid = ecid
        self.name = name

        let view = VPhoneVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.keyHelper = keyHelper
        view.control = control
        virtualMachineView = view
        let vmView: NSView = view

        // 1:1 with the guest panel's points, which is what iPhone Mirroring draws
        // for the same handset: a 1170x2532 panel at scale 3 is 390x844 pt in both.
        let scale = CGFloat(screenScale)
        let windowSize = NSSize(
            width: CGFloat(screenWidth) / scale, height: CGFloat(screenHeight) / scale
        )

        // iPhone Mirroring's window is 406x890 around the same 390x844 body: 8 pt
        // at the sides, 36 pt above, 10 pt below, all transparent. Matching it
        // keeps the panel in the same place when a tiling WM pins the window to
        // the top of a node, and leaves the top strip free for a hover toolbar.
        let contentSize = NSSize(
            width: windowSize.width + 16, height: windowSize.height + 46
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.isReleasedWhenClosed = false
        window.contentAspectRatio = contentSize
        window.title = "\(name) [loading]"
        window.subtitle = makeSubtitle(ip: nil)

        let panelContainer = NSView(frame: NSRect(origin: .zero, size: contentSize))
        vmView.frame = NSRect(
            x: 8, y: 10, width: windowSize.width, height: windowSize.height
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
        window.minSize = contentSize
        window.maxSize = contentSize
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        // The window is locked to one of the View sizes; full screen would
        // stretch the guest panel, so the Window menu must not offer it.
        window.collectionBehavior.insert(.fullScreenNone)
        cornerRadiusFraction = 43.25 / windowSize.width
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
        if let ecid {
            if !window.setFrameAutosaveName("vphone-\(ecid)") {
                window.center()
            }
        } else {
            window.center()
        }

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        windowController = controller

        keyHelper.window = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        observeClipboard(window: window)

        let monitor = VPhoneTouchIDMonitor()
        monitor.start(control: control, window: window)
        touchIDMonitor = monitor

        // Poll vphoned status for title indicator
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, let control = self.control else { return }
                window.title =
                    control.isConnected ? "\(self.name) [connected]" : "\(self.name) [disconnected]"
                window.subtitle = self.makeSubtitle(ip: control.isConnected ? control.guestIP : nil)
            }
        }
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
        view.layer?.cornerRadius = view.bounds.width * cornerRadiusFraction
    }

    /// The scale the View menu last applied, which is what its check mark shows.
    var currentPanelScale: CGFloat { panelScale }

    /// Panel scale from the View menu. 1 is the guest panel drawn 1:1.
    func setPanelScale(_ factor: CGFloat) {
        panelScale = factor
        guard let window = windowController?.window, let panel = virtualMachineView else { return }
        applyPanelSize(to: window, panel: panel)
    }

    /// Resize the locked window to the current scale, shrunk to fit the screen it
    /// sits on. minSize and maxSize are equal, so both have to move before
    /// setContentSize takes.
    private func applyPanelSize(to window: NSWindow, panel: NSView) {
        var panelSize = NSSize(
            width: basePanelSize.width * panelScale, height: basePanelSize.height * panelScale
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
        window.contentAspectRatio = contentSize
        window.setContentSize(contentSize)
        cornerRadiusFraction = 43.25 / panelSize.width
        applyCornerRadius(to: panel)
    }

    private func makeSubtitle(ip: String?) -> String {
        switch (ecid, ip) {
        case let (ecid?, ip?): "\(ecid) — \(ip)"
        case let (ecid?, nil): ecid
        case let (nil, ip?): ip
        case (nil, nil): ""
        }
    }

}
