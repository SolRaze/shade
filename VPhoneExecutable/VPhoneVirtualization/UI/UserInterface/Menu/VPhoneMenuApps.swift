import AppKit
import Foundation
import VPhoneCoreKit

// MARK: - Apps Menu

extension VPhoneMenuController {
    func buildAppsMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Apps")
        menu.autoenablesItems = false

        let browse = makeItem(
            "App Browser",
            action: #selector(openAppBrowser),
            keyEquivalent: "a",
            modifiers: [.command, .shift],
            symbol: "square.grid.2x2",
        )
        browse.isEnabled = false
        appsListItem = browse
        menu.addItem(browse)

        menu.addItem(NSMenuItem.separator())

        let openURL = makeItem("Open URL…", action: #selector(openURL), symbol: "link")
        openURL.isEnabled = false
        appsOpenURLItem = openURL
        menu.addItem(openURL)

        menu.addItem(NSMenuItem.separator())

        let install = makeItem(
            "Install App Package…",
            action: #selector(installIPAFromDisk),
            symbol: "square.and.arrow.down",
        )
        install.isEnabled = false
        installPackageItem = install
        menu.addItem(install)

        let installLC = makeItem(
            "Install IPA into LiveContainer…",
            action: #selector(installIPAIntoLiveContainer),
            symbol: "shippingbox",
        )
        installLC.isEnabled = false
        installLiveContainerItem = installLC
        menu.addItem(installLC)

        item.submenu = menu
        return item
    }

    func updateAppsAvailability(available: Bool) {
        appsListItem?.isEnabled = available
    }

    func updateURLAvailability(available: Bool) {
        appsOpenURLItem?.isEnabled = available
    }

    func updateInstallAvailability(available: Bool, liveContainer: Bool = false) {
        installPackageItem?.isEnabled = available
        installLiveContainerItem?.isEnabled = liveContainer
    }

    @objc func openAppBrowser() {
        onAppsPressed?()
    }

    @objc func installIPAFromDisk() {
        chooseInstallPackage { [weak self] url in self?.installIPA(from: url) }
    }

    @objc func installIPAIntoLiveContainer() {
        chooseInstallPackage { [weak self] url in
            guard let self else { return }
            Task {
                do {
                    let result = try await self.control.installIntoLiveContainer(localURL: url)
                    VPhoneAlert.present(title: "Install into LiveContainer", message: result, style: .informational)
                } catch {
                    VPhoneAlert.present(title: "Install into LiveContainer", message: "\(error)", style: .warning)
                }
            }
        }
    }

    private func chooseInstallPackage(_ install: @escaping (URL) -> Void) {
        guard control.isConnected else {
            VPhoneAlert.present(
                title: "Install App Package", message: "The guest is not connected. Start a VM, then try again.",
                style: .warning,
            )
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = VPhoneInstallPackage.allowedContentTypes
        panel.prompt = VPhoneLocalization.text("Install")
        panel.message = VPhoneLocalization.text("Choose an IPA or TIPA package to install in the guest.")

        VPhoneAlert.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            install(url)
        }
    }

    private func installIPA(from url: URL) {
        Task {
            do {
                let result = try await control.installIPA(localURL: url)
                print("[install] \(result)")
                VPhoneAlert.present(
                    title: "Install App Package",
                    message: VPhoneLocalization.installedMessage(
                        for: url.lastPathComponent,
                        detail: result,
                    ),
                    style: .informational,
                )
            } catch {
                VPhoneAlert.present(
                    title: "Install App Package",
                    message: "Unable to install the app package. Check the file and guest connection, then try again.",
                    style: .warning,
                )
            }
        }
    }

    @objc func openURL() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://example.com"
        field.setAccessibilityLabel(VPhoneLocalization.text("URL to open on the guest"))

        let alert = NSAlert()
        alert.messageText = VPhoneLocalization.text("Open URL")
        alert.informativeText = VPhoneLocalization.text("Enter a URL to open on the guest.")
        alert.accessoryView = field
        alert.addButton(withTitle: VPhoneLocalization.text("Open"))
        alert.addButton(withTitle: VPhoneLocalization.text("Cancel"))
        alert.window.initialFirstResponder = field

        VPhoneAlert.present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            self?.openOnGuest(field.stringValue)
        }
    }

    private func openOnGuest(_ url: String) {
        Task {
            do {
                try await control.openURL(url)
                VPhoneAlert.present(
                    title: "Open URL", message: VPhoneLocalization.format("Opened %@", url), style: .informational,
                )
            } catch {
                VPhoneAlert.present(
                    title: "Open URL",
                    message: "Unable to open the URL on the guest. Check the URL and guest connection, then try again.",
                    style: .warning,
                )
            }
        }
    }
}
