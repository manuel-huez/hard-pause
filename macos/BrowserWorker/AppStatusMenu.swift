import AppKit

@MainActor
final class AppStatusMenu: NSObject {
    private var item: NSStatusItem?
    private let protectionItem = NSMenuItem(title: "Checking protection…", action: nil, keyEquivalent: "")
    private let plansItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func update(snapshot: ProtectedServiceSnapshot?, ownsMenu: Bool) {
        guard ownsMenu else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let menu = NSMenu()
            menu.addItem(protectionItem)
            menu.addItem(plansItem)
            menu.addItem(.separator())
            let open = NSMenuItem(title: "Open Hard Pause", action: #selector(openApp), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Version \(ReleaseVersion.description)", action: nil, keyEquivalent: ""))
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.menu = menu
            self.item = item
        }
        let activeCount = snapshot?.blocks.filter { $0.phase != .inactive }.count ?? 0
        let image = NSImage(named: activeCount == 0 ? "MenuBarInactive" : "MenuBarActive")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        item?.button?.image = image
        item?.button?.toolTip = "Hard Pause"
        item?.button?.setAccessibilityLabel(
            activeCount == 0 ? "Hard Pause: no active plans" : "Hard Pause: plan active")
        protectionItem.title =
            snapshot?.protection.isEnforcing == true && snapshot?.protection.issues.isEmpty == true
            ? "Protection service running" : "Protection needs attention"
        plansItem.title =
            snapshot == nil
            ? "Plan status unavailable"
            : activeCount == 0 ? "No active plans" : activeCount == 1 ? "1 active plan" : "\(activeCount) active plans"
    }

    @objc private func openApp() { open(nil) }
    @objc private func checkForUpdates() { open(URL(string: "hardpause://check-for-updates")) }

    private func open(_ url: URL?) {
        let app = URL(fileURLWithPath: "/Applications/HardPause.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Task {
            if let url {
                _ = try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
            } else {
                _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            }
        }
    }
}
