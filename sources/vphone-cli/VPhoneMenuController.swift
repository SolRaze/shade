import AppKit
import Foundation

// MARK: - Menu Controller

@MainActor
class VPhoneMenuController: NSObject {
    let keyHelper: VPhoneKeyHelper
    let control: VPhoneControl
    weak var vm: VPhoneVirtualMachine?

    var onFilesPressed: (() -> Void)?
    var onKeychainPressed: (() -> Void)?
    var onAppsPressed: (() -> Void)?
    var connectFileBrowserItem: NSMenuItem?
    var connectKeychainBrowserItem: NSMenuItem?
    var connectDevModeStatusItem: NSMenuItem?
    var connectPingItem: NSMenuItem?
    var connectGuestVersionItem: NSMenuItem?
    var installPackageItem: NSMenuItem?
    var installLiveContainerItem: NSMenuItem?
    var clipboardGetItem: NSMenuItem?
    var clipboardSetItem: NSMenuItem?
    var appsListItem: NSMenuItem?
    var appsOpenURLItem: NSMenuItem?
    var settingsGetItem: NSMenuItem?
    var settingsSetItem: NSMenuItem?
    var touchIDMonitor: VPhoneTouchIDMonitor? {
        didSet { touchIDMonitor?.isEnabled = touchIDMenuItem?.state == .on }
    }
    var touchIDMenuItem: NSMenuItem?
    var locationProvider: VPhoneLocationProvider?
    var locationMenuItem: NSMenuItem?
    var locationPresetMenuItem: NSMenuItem?
    var locationReplayStartItem: NSMenuItem?
    var locationReplayStopItem: NSMenuItem?
    var screenRecorder: VPhoneScreenRecorder?
    var recordingItem: NSMenuItem?
    var cameraServer: VPhoneCameraServer?
    var cameraStatusItem: NSMenuItem?
    var cameraSourceOffItem: NSMenuItem?
    var cameraSourceTestPatternItem: NSMenuItem?
    var cameraSourceVideoFileItem: NSMenuItem?
    var cameraStartStopItem: NSMenuItem?
    weak var captureView: VPhoneVirtualMachineView?
    weak var windowController: VPhoneWindowController?
    /// View-menu size items, keyed by the panel scale each one applies.
    var viewSizeItems: [CGFloat: NSMenuItem] = [:]
    var batterySyncEnabled = false
    var batterySyncStatusItem: NSMenuItem?
    var batteryLevelMenuItems: [NSMenuItem] = []
    var batteryConnectivityMenuItems: [NSMenuItem] = []
    var powerSourceRunLoopSource: CFRunLoopSource?
    var powerSourceRetainedPtr: UnsafeMutableRawPointer?
    var lowPowerObserver: (any NSObjectProtocol)?

    init(keyHelper: VPhoneKeyHelper, control: VPhoneControl) {
        self.keyHelper = keyHelper
        self.control = control
        super.init()
        setupMenuBar()
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "vphone")
        #if canImport(VPhoneBuildInfo)
            let buildItem = NSMenuItem(
                title: "Build: \(VPhoneBuildInfo.commitHash)", action: nil, keyEquivalent: ""
            )
        #else
            let buildItem = NSMenuItem(title: "Build: unknown", action: nil, keyEquivalent: "")
        #endif
        buildItem.isEnabled = false
        appMenu.addItem(buildItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit vphone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        mainMenu.addItem(buildConnectMenu())
        mainMenu.addItem(buildKeysMenu())
        mainMenu.addItem(buildViewMenu())
        mainMenu.addItem(buildAppsMenu())
        mainMenu.addItem(buildRecordMenu())

        // Window menu — provides Cmd+W (close) and Cmd+M (minimize) for any key window
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = VPhoneMenuController.symbol(for: title)
        return item
    }

    /// SF Symbol per menu title. Items whose title changes at runtime carry
    /// both titles here; setting the title again does not refresh the image, so
    /// the code that flips a title sets `image` from this table too.
    static let menuSymbols: [String: String] = [
        "Home Screen": "iphone",
        "App Switcher": "square.on.square",
        "Spotlight": "magnifyingglass",
        "Spotlight (Cmd+Space)": "magnifyingglass",
        "Power": "power",
        "Volume Up": "speaker.wave.3",
        "Volume Down": "speaker.wave.1",
        "Type ASCII from Clipboard": "keyboard",
        "Touch ID Home Forwarding": "touchid",
        "File Browser": "folder",
        "Keychain Browser": "key",
        "Developer Mode Status": "hammer",
        "Ping": "wave.3.right",
        "Guest Version": "info.circle",
        "Get Clipboard": "doc.on.clipboard",
        "Set Clipboard Text...": "clipboard",
        "Read Setting...": "gearshape",
        "Write Setting...": "gearshape.fill",
        "App Browser": "square.grid.2x2",
        "Open URL...": "safari",
        "Install IPA/TIPA...": "arrow.down.app",
        "Start Recording": "record.circle",
        "Stop Recording": "stop.circle",
        "Copy Screenshot to Clipboard": "camera.on.rectangle",
        "Save Screenshot to File": "square.and.arrow.down",
        "Sync Host Location": "location",
        "Start Route Replay": "play.circle",
        "Stop Route Replay": "stop.circle",
        "Sync with Host": "arrow.triangle.2.circlepath",
        "Charging": "battery.100.bolt",
        "Disconnected": "battery.50",
        "Source: Off": "video.slash",
        "Source: Test Pattern": "square.grid.3x3",
        "Source: Video File…": "film",
        "Start Streaming": "video",
        "Stop Streaming": "video.slash",
        "Larger": "arrow.up.left.and.arrow.down.right",
        "Actual Size": "rectangle",
        "Smaller": "arrow.down.right.and.arrow.up.left",
    ]

    static func symbol(for title: String) -> NSImage? {
        guard let name = menuSymbols[title] else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: title)
    }
}
