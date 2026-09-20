import AppKit

// MARK: - View Menu

extension VPhoneMenuController {
    /// The same View menu iPhone Mirroring carries, on the same shortcuts:
    /// ⌘1/⌘2/⌘3 for the guest actions, ⌘+/⌘- to step through three fixed sizes
    /// one at a time, ⌘0 straight to Actual Size. The sizes are fixed, not a
    /// continuous zoom: Larger draws the guest panel 1:1, Actual Size and
    /// Smaller match iPhone Mirroring's own two smaller windows, 316x696 and
    /// 212x471 with chrome, as a fraction of this guest's panel.
    /// applyPanelSize shrinks any of them to fit the screen the window is on.
    ///
    /// The main menu gets key equivalents before the key window's responder
    /// chain, so these six chords never reach the guest keyboard.
    func buildViewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        for (title, key, action) in [
            ("Home Screen", "1", #selector(viewHomeScreen)),
            ("App Switcher", "2", #selector(viewAppSwitcher)),
            ("Spotlight", "3", #selector(viewSpotlight)),
        ] {
            let keyItem = makeItem(title, action: action)
            keyItem.keyEquivalent = key
            menu.addItem(keyItem)
        }
        menu.addItem(NSMenuItem.separator())

        viewSizeItems = [:]
        for (title, key, scale, action) in [
            ("Larger", "+", VPhoneMenuController.largerScale, #selector(viewLarger)),
            ("Actual Size", "0", VPhoneMenuController.actualScale, #selector(viewActualSize)),
            ("Smaller", "-", VPhoneMenuController.smallerScale, #selector(viewSmaller)),
        ] {
            let sizeItem = makeItem(title, action: action)
            sizeItem.keyEquivalent = key
            viewSizeItems[scale] = sizeItem
            menu.addItem(sizeItem)
        }
        menu.delegate = self
        item.submenu = menu
        return item
    }

    // MARK: - Sizes

    static let smallerScale: CGFloat = 0.474
    static let actualScale: CGFloat = 0.706
    static let largerScale: CGFloat = 1

    /// Smallest first, so Larger and Smaller are a step along this list.
    static let sizeScales: [CGFloat] = [smallerScale, actualScale, largerScale]

    @objc func viewLarger() { stepViewSize(1) }
    @objc func viewActualSize() { windowController?.setPanelScale(VPhoneMenuController.actualScale) }
    @objc func viewSmaller() { stepViewSize(-1) }

    /// One fixed size up or down. At either end nothing moves — the item is
    /// dimmed there.
    private func stepViewSize(_ direction: Int) {
        let scales = VPhoneMenuController.sizeScales
        let index = currentSizeIndex + direction
        guard scales.indices.contains(index) else { return }
        windowController?.setPanelScale(scales[index])
    }

    /// Index into sizeScales of the size the window is at, nearest match so a
    /// screen-clamped window still resolves to the size that was picked.
    private var currentSizeIndex: Int {
        let current = windowController?.currentPanelScale ?? VPhoneMenuController.largerScale
        let scales = VPhoneMenuController.sizeScales
        return scales.enumerated().min { abs($0.element - current) < abs($1.element - current) }?.offset ?? scales.count - 1
    }

    /// An item dims when picking it would do nothing: Larger at the biggest
    /// size, Smaller at the smallest, Actual Size when already there. That is
    /// the size indicator as well as the guard.
    func isDeadViewSizeItem(_ item: NSMenuItem) -> Bool {
        let scales = VPhoneMenuController.sizeScales
        let index = currentSizeIndex
        if item === viewSizeItems[VPhoneMenuController.largerScale] {
            return index == scales.count - 1
        }
        if item === viewSizeItems[VPhoneMenuController.smallerScale] {
            return index == 0
        }
        if item === viewSizeItems[VPhoneMenuController.actualScale] {
            return scales[index] == VPhoneMenuController.actualScale
        }
        return false
    }

    // MARK: - Guest Actions

    @objc func viewHomeScreen() { keyHelper.sendHome() }
    @objc func viewAppSwitcher() { keyHelper.sendAppSwitcher() }
    @objc func viewSpotlight() { keyHelper.sendSpotlight() }
}

// MARK: - Menu Delegate

extension VPhoneMenuController: NSMenuDelegate, NSMenuItemValidation {
    /// Every other item stays enabled; only a size step that goes nowhere dims.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        !isDeadViewSizeItem(item)
    }

    /// AppKit appends its own Enter Full Screen item to any menu titled View.
    /// The window refuses full screen, so the item is dead weight — drop it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(NSWindow.toggleFullScreen(_:)) {
            menu.removeItem(item)
        }
    }
}
