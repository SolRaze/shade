import AppKit
import Dynamic
import Foundation
import Virtualization
import VPhoneCore

class VPhoneVirtualMachineView: VZVirtualMachineView {
    var keyHelper: VPhoneKeyHelper?
    weak var control: VPhoneControl?

    private var currentTouchSwipeAim: Int = 0
    /// Where the pressed mouse last was, nil when no button is down. Only set so
    /// an interrupted drag can be lifted.
    private var activeMousePoint: NSPoint?
    /// Live pinch or rotate. Both host gestures drive one pair of fingers.
    private var pinch: VPhoneTwoFingerGesture?
    /// Where the finger a host scroll drives currently sits, nil when no scroll
    /// is in flight.
    private var scrollPoint: NSPoint?
    private var scrollLift: DispatchWorkItem?
    private var contextTouchStart: TimeInterval?
    private var contextLift: DispatchWorkItem?
    /// Longer than `UILongPressGestureRecognizer`'s 0.5 s default, which is
    /// what a context menu waits for.
    private static let contextHold: TimeInterval = 0.6
    private var resignKeyObserver: NSObjectProtocol?
    private var heldModifiers: Set<UInt16> = []
    /// Left and right Shift, Control, Option, Command, plus Caps Lock and Fn.
    private static let modifierKeyCodes: Set<UInt16> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]
    private var isDragHighlightVisible = false

    /// Touch phases, numbered as `UITouch.Phase` is — `_VZTouch` and vphoned's
    /// digitizer injection both take these values directly.
    private enum Phase {
        static let down = 0, moved = 1, ended = 3, cancelled = 4
    }

    /// One finger of a synthetic multi-touch event, positioned in view-local
    /// points. `index` is the finger's identity and must stay the same for the
    /// life of a gesture.
    private struct Finger {
        var index: Int
        var phase: Int
        var location: NSPoint
    }

    // MARK: - Private API Accessors

    /// https://github.com/wh1te4ever/super-tart-vphone-writeup/blob/main/contents/ScreenSharingVNC.swift
    ///
    /// Resolved once. The VM's device set is fixed by its configuration, so the
    /// array cannot change while this view has a VM, and a drag asks for the
    /// device on every touch event.
    private var multiTouchDevice: AnyObject? {
        if let cachedMultiTouchDevice { return cachedMultiTouchDevice }
        guard let vm = virtualMachine else { return nil }
        guard let devices = Dynamic(vm)._multiTouchDevices.asObject as? NSArray,
              devices.count > 0
        else {
            return nil
        }
        let device = devices.object(at: 0) as AnyObject
        cachedMultiTouchDevice = device
        return device
    }

    private var cachedMultiTouchDevice: AnyObject?

    var recordingGraphicsDisplay: VZGraphicsDisplay? {
        if let display = Dynamic(self)._graphicsDisplay.asObject as? VZGraphicsDisplay {
            return display
        }
        return virtualMachine?.graphicsDevices.first?.displays.first
    }

    // MARK: - Event Handling

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ensure keyboard events route to VM view right after window attach.
        window?.makeFirstResponder(self)
        registerForDraggedTypes([.fileURL])

        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        // A drag that ends outside the window never delivers its mouse-up here.
        guard let window else { return }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelActiveTouches() }
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking the VM display should always restore keyboard focus.
        window?.makeFirstResponder(self)
        liftContextTouch()
        let localPoint = convert(event.locationInWindow, from: nil)
        currentTouchSwipeAim = hitTestEdge(at: localPoint)
        activeMousePoint = localPoint
        if sendTouchEvent(phase: Phase.down, localPoint: localPoint, timestamp: event.timestamp) { return }
        activeMousePoint = nil
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if activeMousePoint != nil { activeMousePoint = localPoint }
        if sendTouchEvent(phase: Phase.moved, localPoint: localPoint, timestamp: event.timestamp) { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        activeMousePoint = nil
        if !sendTouchEvent(phase: Phase.ended, localPoint: localPoint, timestamp: event.timestamp) {
            super.mouseUp(with: event)
        }
        currentTouchSwipeAim = 0
    }

    /// Right-click is touch-and-hold, as in iPhone Mirroring: it opens the
    /// context menu under the pointer. The finger stays down at least
    /// `contextHold`, so a quick click still crosses the guest's long-press
    /// threshold, and dragging while held moves it, which picks up an icon.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        liftContextTouch()
        let localPoint = convert(event.locationInWindow, from: nil)
        currentTouchSwipeAim = 0
        guard sendTouchEvent(phase: Phase.down, localPoint: localPoint, timestamp: event.timestamp) else {
            super.rightMouseDown(with: event)
            return
        }
        activeMousePoint = localPoint
        contextTouchStart = event.timestamp
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard contextTouchStart != nil else {
            super.rightMouseDragged(with: event)
            return
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        activeMousePoint = localPoint
        sendTouchEvent(phase: Phase.moved, localPoint: localPoint, timestamp: event.timestamp)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let start = contextTouchStart else {
            super.rightMouseUp(with: event)
            return
        }
        contextTouchStart = nil
        let lift = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endContextTouch() }
        }
        contextLift = lift
        let remaining = Self.contextHold - (event.timestamp - start)
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: lift)
        } else {
            lift.perform()
        }
    }

    private func endContextTouch() {
        contextLift = nil
        guard let point = activeMousePoint else { return }
        activeMousePoint = nil
        sendTouchEvent(phase: Phase.ended, localPoint: point, timestamp: ProcessInfo.processInfo.systemUptime)
    }

    /// Ends a held right-click now rather than when its hold runs out, so the
    /// next touch does not land while the guest still has that finger down.
    private func liftContextTouch() {
        guard let lift = contextLift else { return }
        // Cancel after, not before: a cancelled item skips perform() too.
        lift.perform()
        lift.cancel()
    }

    /// Mouse side buttons: 3 is back, 4 is forward. iOS has no back key, so
    /// both drive the interactive edge-swipe gesture the system already owns.
    override func otherMouseDown(with event: NSEvent) {
        let w = Double(bounds.width)
        let h = Double(bounds.height)
        guard w > 0, h > 0 else { return }
        // Start inside hitTestEdge's 32pt band so the touch carries a left or
        // right swipeAim; without it the guest reads a plain drag.
        switch event.buttonNumber {
        case 3:
            injectSwipe(fromX: 2, fromY: h / 2, toX: w * 0.6, toY: h / 2,
                        screenWidth: Int(w), screenHeight: Int(h), durationMs: 180)
        case 4:
            injectSwipe(fromX: w - 2, fromY: h / 2, toX: w * 0.4, toY: h / 2,
                        screenWidth: Int(w), screenHeight: Int(h), durationMs: 180)
        default:
            super.otherMouseDown(with: event)
        }
    }

    // MARK: - Host Gestures

    /// Host scrolling drives one finger, because a touchscreen guest has no
    /// scroll wheel and `UIScrollView` only follows a drag.
    ///
    /// Momentum events are dropped: the guest derives its own deceleration from
    /// the drag it saw, so replaying the host's would compound it.
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }

        // Precise deltas are already points; a notched wheel reports lines.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        if scrollPoint == nil {
            let start = convert(event.locationInWindow, from: nil)
            guard bounds.contains(start),
                  sendTouchEvent(phase: Phase.down, localPoint: start, timestamp: event.timestamp)
            else {
                super.scrollWheel(with: event)
                return
            }
            scrollPoint = start
        }

        // Positive deltas are a fingers-down, fingers-right swipe. The view is
        // y-up, so the vertical one inverts.
        var point = scrollPoint ?? .zero
        point.x += event.scrollingDeltaX * scale
        point.y -= event.scrollingDeltaY * scale
        point.x = max(0, min(bounds.width, point.x))
        point.y = max(0, min(bounds.height, point.y))
        scrollPoint = point
        sendTouchEvent(phase: Phase.moved, localPoint: point, timestamp: event.timestamp)

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            endScroll(phase: event.phase.contains(.cancelled) ? Phase.cancelled : Phase.ended)
        } else if event.phase.isEmpty {
            // A notched wheel never reports an end, so idle time is the only
            // signal that the gesture is over.
            scheduleScrollLift()
        }
    }

    override func magnify(with event: NSEvent) {
        if !updatePinch(with: event, scale: 1 + event.magnification, radians: 0) {
            super.magnify(with: event)
        }
    }

    override func rotate(with event: NSEvent) {
        // NSEvent.rotation is degrees, counter-clockwise positive.
        if !updatePinch(with: event, scale: 1, radians: CGFloat(event.rotation) * .pi / 180) {
            super.rotate(with: event)
        }
    }

    /// Advances the two-finger pair a pinch or rotate event describes. Returns
    /// false when the guest could not take it.
    private func updatePinch(with event: NSEvent, scale: CGFloat, radians: CGFloat) -> Bool {
        switch event.phase {
        case .began:
            let gesture = VPhoneTwoFingerGesture(
                centre: convert(event.locationInWindow, from: nil), bounds: bounds.size
            )
            guard sendPinch(gesture, phase: Phase.down, timestamp: event.timestamp) else { return false }
            pinch = gesture
            return true
        case .changed:
            guard var gesture = pinch else { return false }
            gesture.apply(scale: scale, radians: radians, bounds: bounds.size)
            pinch = gesture
            return sendPinch(gesture, phase: Phase.moved, timestamp: event.timestamp)
        case .ended, .cancelled:
            guard let gesture = pinch else { return false }
            pinch = nil
            return sendPinch(
                gesture, phase: event.phase == .cancelled ? Phase.cancelled : Phase.ended,
                timestamp: event.timestamp
            )
        default:
            return false
        }
    }

    @discardableResult
    private func sendPinch(
        _ gesture: VPhoneTwoFingerGesture, phase: Int, timestamp: TimeInterval
    ) -> Bool {
        let fingers = gesture.points.enumerated().map {
            Finger(index: $0.offset, phase: phase, location: $0.element)
        }
        return sendTouchEvent(fingers: fingers, timestamp: timestamp)
    }

    private func scheduleScrollLift() {
        scrollLift?.cancel()
        let lift = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endScroll(phase: Phase.ended) }
        }
        scrollLift = lift
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: lift)
    }

    private func endScroll(phase: Int) {
        scrollLift?.cancel()
        scrollLift = nil
        guard let point = scrollPoint else { return }
        scrollPoint = nil
        sendTouchEvent(phase: phase, localPoint: point, timestamp: ProcessInfo.processInfo.systemUptime)
    }

    /// Lifts everything the guest still believes is on the screen.
    ///
    /// A drag whose mouse-up lands in another window, or one cut short by the
    /// guest dropping the control connection, otherwise leaves a finger down and
    /// the guest stuck mid-gesture.
    func cancelActiveTouches() {
        let timestamp = ProcessInfo.processInfo.systemUptime
        endScroll(phase: Phase.cancelled)
        contextLift?.cancel()
        contextLift = nil
        contextTouchStart = nil
        if let gesture = pinch {
            pinch = nil
            sendPinch(gesture, phase: Phase.cancelled, timestamp: timestamp)
        }
        if let point = activeMousePoint {
            activeMousePoint = nil
            sendTouchEvent(phase: Phase.cancelled, localPoint: point, timestamp: timestamp)
            currentTouchSwipeAim = 0
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "h"
        {
            keyHelper?.sendHome()
            return true
        }
        // Cmd+Shift+V pastes the host pasteboard by typing it, so plain Cmd+V
        // stays available as the guest's own paste.
        if event.modifierFlags.contains(.command),
           event.modifierFlags.contains(.shift),
           event.charactersIgnoringModifiers?.lowercased() == "v"
        {
            keyHelper?.typeFromClipboard()
            return true
        }
        // The main menu keeps its own chords: ⌘1/⌘2/⌘3 for Home, App Switcher
        // and Spotlight, the View sizes, ⌘W and ⌘Q.
        if event.modifierFlags.contains(.command),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        {
            return true
        }
        // AppKit routes Cmd chords here instead of keyDown, so the guest would
        // never get Cmd+C, Cmd+V or Cmd+A without this.
        if event.modifierFlags.contains(.command), let keyHelper, window?.firstResponder === self {
            keyHelper.sendRawKey(keyCode: event.keyCode, down: true)
            keyHelper.sendRawKey(keyCode: event.keyCode, down: false)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The whole keyboard is forwarded as raw Apple virtual key codes, which is
    /// the only way the guest sees modifier state: the base class translates
    /// characters and drops Shift, Cmd, Ctrl and Option, so uppercase and the
    /// guest's own Cmd+C/Cmd+V never arrive.
    override func keyDown(with event: NSEvent) {
        guard let keyHelper else {
            super.keyDown(with: event)
            return
        }
        // Holding a key gives repeated keyDowns with no keyUp between them. The
        // guest counts transitions, so a second down on an already-down key is
        // dropped and the hold produces one character. Each repeat is sent as a
        // fresh release-press pair, which puts the guest on the host's own
        // repeat rate.
        if event.isARepeat {
            keyHelper.sendRawKey(keyCode: event.keyCode, down: false)
        }
        keyHelper.sendRawKey(keyCode: event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let keyHelper else {
            super.keyUp(with: event)
            return
        }
        keyHelper.sendRawKey(keyCode: event.keyCode, down: false)
    }

    /// Forward each physical modifier key as its own down/up pair.
    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        guard Self.modifierKeyCodes.contains(code) else {
            super.flagsChanged(with: event)
            return
        }
        if heldModifiers.remove(code) != nil {
            keyHelper?.sendRawKey(keyCode: code, down: false)
        } else {
            heldModifiers.insert(code)
            keyHelper?.sendRawKey(keyCode: code, down: true)
        }
    }

    override func resignFirstResponder() -> Bool {
        releaseHeldModifiers()
        return super.resignFirstResponder()
    }

    /// Nothing else releases a modifier the guest still thinks is down once the
    /// window loses focus mid-chord.
    func releaseHeldModifiers() {
        for code in heldModifiers {
            keyHelper?.sendRawKey(keyCode: code, down: false)
        }
        heldModifiers.removeAll()
    }

    // MARK: - Drag and Drop Install

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !droppedFileURLs(from: sender).isEmpty else { return [] }
        updateDragHighlight(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        _ = sender
        updateDragHighlight(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !droppedFileURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        updateDragHighlight(false)
        let urls = droppedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }

        let documents = urls.filter { !VPhoneInstallPackage.isSupportedFile($0) }
        if !documents.isEmpty { copyIntoFilesApp(documents) }

        guard let url = urls.first(where: VPhoneInstallPackage.isSupportedFile) else { return true }

        Task { @MainActor in
            guard let control else {
                showAlert(title: "Install App Package", message: "Guest is not connected.", style: .warning)
                return
            }
            guard control.isConnected else {
                showAlert(title: "Install App Package", message: "Guest is not connected.", style: .warning)
                return
            }

            do {
                let result = try await control.installIPA(localURL: url)
                print("[install] \(result)")
                showAlert(
                    title: "Install App Package",
                    message: VPhoneInstallPackage.successMessage(
                        for: url.lastPathComponent,
                        detail: result
                    ),
                    style: .informational
                )
            } catch {
                showAlert(title: "Install App Package", message: "\(error)", style: .warning)
            }
        }
        return true
    }

    private func droppedFileURLs(from sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls ?? []
    }

    /// Anything that is not an installable package lands in the guest's Files
    /// app, under On My iPhone. Written 666 because vphoned runs as root and
    /// the Files app reads and deletes as mobile.
    private func copyIntoFilesApp(_ urls: [URL]) {
        Task { @MainActor in
            guard let control, control.isConnected else {
                showAlert(title: "Copy to Files", message: "Guest is not connected.", style: .warning)
                return
            }
            do {
                let root = try await control.filesAppStorageRoot()
                for url in urls {
                    let data = try Data(contentsOf: url)
                    let remote = "\(root)/\(url.lastPathComponent)"
                    try await control.uploadFile(path: remote, data: data, permissions: "666")
                    print("[files] copied \(url.lastPathComponent) to \(remote)")
                }
                showAlert(
                    title: "Copy to Files",
                    message: urls.count == 1
                        ? "\(urls[0].lastPathComponent) is in Files under On My iPhone."
                        : "\(urls.count) files are in Files under On My iPhone.",
                    style: .informational
                )
            } catch {
                showAlert(title: "Copy to Files", message: "\(error)", style: .warning)
            }
        }
    }

    private func updateDragHighlight(_ visible: Bool) {
        guard isDragHighlightVisible != visible else { return }
        isDragHighlightVisible = visible
        wantsLayer = true
        layer?.borderWidth = visible ? 4 : 0
        layer?.borderColor = visible ? NSColor.systemGreen.cgColor : NSColor.clear.cgColor
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Programmatic Touch (for automation)

    /// Convert screenshot pixel coordinates to NSView local coordinates.
    private func pixelToLocal(pixelX: Double, pixelY: Double, screenWidth: Int, screenHeight: Int) -> NSPoint {
        let w = bounds.width
        let h = bounds.height
        let localX = pixelX / Double(screenWidth) * w
        // Screenshot y=0 is top, NSView y=0 is bottom (non-flipped)
        let localY = (1.0 - pixelY / Double(screenHeight)) * h
        return NSPoint(x: localX, y: localY)
    }

    /// Synthesize an NSEvent at a given window point.
    private func synthesizeMouseEvent(type: NSEvent.EventType, at windowPoint: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: type == .leftMouseUp ? 0 : 1,
            pressure: type == .leftMouseUp ? 0.0 : 1.0
        )
    }

    /// Inject a tap at pixel coordinates (matching screenshot image dimensions).
    func injectTap(pixelX: Double, pixelY: Double, screenWidth: Int, screenHeight: Int) {
        let localPoint = pixelToLocal(pixelX: pixelX, pixelY: pixelY, screenWidth: screenWidth, screenHeight: screenHeight)
        let windowPoint = convert(localPoint, to: nil)

        if let downEvent = synthesizeMouseEvent(type: .leftMouseDown, at: windowPoint) {
            mouseDown(with: downEvent)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            if let upEvent = self.synthesizeMouseEvent(type: .leftMouseUp, at: windowPoint) {
                self.mouseUp(with: upEvent)
            }
        }
    }

    /// Inject a swipe from one pixel coordinate to another.
    func injectSwipe(
        fromX: Double, fromY: Double, toX: Double, toY: Double,
        screenWidth: Int, screenHeight: Int, durationMs: Int = 300
    ) {
        let startLocal = pixelToLocal(pixelX: fromX, pixelY: fromY, screenWidth: screenWidth, screenHeight: screenHeight)
        let endLocal = pixelToLocal(pixelX: toX, pixelY: toY, screenWidth: screenWidth, screenHeight: screenHeight)
        let startWindow = convert(startLocal, to: nil)
        let endWindow = convert(endLocal, to: nil)

        let steps = max(10, durationMs / 16)
        let stepInterval = Double(durationMs) / Double(steps) / 1000.0

        if let downEvent = synthesizeMouseEvent(type: .leftMouseDown, at: startWindow) {
            mouseDown(with: downEvent)
        }

        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let x = startWindow.x + (endWindow.x - startWindow.x) * t
            let y = startWindow.y + (endWindow.y - startWindow.y) * t
            let pt = NSPoint(x: x, y: y)
            let delay = stepInterval * Double(i)

            if i < steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    if let dragEvent = self.synthesizeMouseEvent(type: .leftMouseDragged, at: pt) {
                        self.mouseDragged(with: dragEvent)
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    if let upEvent = self.synthesizeMouseEvent(type: .leftMouseUp, at: pt) {
                        self.mouseUp(with: upEvent)
                    }
                }
            }
        }
    }

    // MARK: - Legacy Touch Injection (macOS 15)

    @discardableResult
    private func sendTouchEvent(phase: Int, localPoint: NSPoint, timestamp: TimeInterval) -> Bool {
        sendTouchEvent(
            fingers: [Finger(index: 0, phase: phase, location: localPoint)], timestamp: timestamp
        )
    }

    /// Delivers one multi-touch event to the guest. Returns false when no path
    /// took it, so the caller can hand the host event back to AppKit.
    @discardableResult
    private func sendTouchEvent(fingers: [Finger], timestamp: TimeInterval) -> Bool {
        guard !fingers.isEmpty else { return false }

        // iOS 18 bases: the VZ USB touchscreen dext emits no digitizer events on
        // the 26.x kernel, so route touches through vphoned's guest-side HID
        // injection. 26.x bases fall through to the native VZ multitouch path.
        if let control, control.useGuestTouchInjection {
            let normalized = fingers.map { finger -> (phase: Int, x: Double, y: Double) in
                let point = normalizeCoordinate(finger.location)
                return (phase: finger.phase, x: Double(point.x), y: Double(point.y))
            }
            if let only = normalized.first, normalized.count == 1 {
                control.sendTouch(phase: only.phase, x: only.x, y: only.y)
                return true
            }
            // A daemon too old to carry several fingers would read the first one
            // as a plain drag, which scrolls instead of pinching. Drop it.
            guard control.supportsGuestMultiTouch else { return false }
            control.sendTouches(normalized)
            return true
        }

        guard let device = multiTouchDevice,
              virtualMachine != nil
        else { return false }

        var touches: [AnyObject] = []
        for finger in fingers {
            let touch = Dynamic._VZTouch(
                view: self,
                index: finger.index,
                phase: finger.phase,
                location: normalizeCoordinate(finger.location),
                swipeAim: currentTouchSwipeAim,
                timestamp: timestamp
            )
            guard let touchObj = touch.asObject else {
                print("[vphone] Error: Failed to create _VZTouch")
                return false
            }
            touches.append(touchObj)
        }

        let touchEvent = Dynamic._VZMultiTouchEvent(touches: touches)
        guard let eventObj = touchEvent.asObject else { return false }

        Dynamic(device).sendMultiTouchEvents([eventObj] as NSArray)
        return true
    }

    // MARK: - Coordinate Helpers

    private func normalizeCoordinate(_ localPoint: NSPoint) -> CGPoint {
        let w = bounds.width
        let h = bounds.height

        guard w > 0, h > 0 else { return .zero }

        var nx = Double(localPoint.x / w)
        var ny = Double(localPoint.y / h)

        // Clamp
        nx = max(0.0, min(1.0, nx))
        ny = max(0.0, min(1.0, ny))

        if !isFlipped {
            ny = 1.0 - ny
        }

        return CGPoint(x: nx, y: ny)
    }

    private func hitTestEdge(at point: CGPoint) -> Int {
        let w = bounds.width
        let h = bounds.height

        let edgeThreshold: CGFloat = 32.0

        let distLeft = point.x
        let distRight = w - point.x
        let distTop = isFlipped ? point.y : (h - point.y)
        let distBottom = isFlipped ? (h - point.y) : point.y

        var minDist = distLeft
        var edgeCode = 8 // Left

        if distRight < minDist {
            minDist = distRight
            edgeCode = 4 // Right
        }

        if distBottom < minDist {
            minDist = distBottom
            edgeCode = 2 // Bottom (Home bar swipe up)
        }

        if distTop < minDist {
            minDist = distTop
            edgeCode = 1 // Top (Notification Center)
        }

        return minDist < edgeThreshold ? edgeCode : 0
    }
}
