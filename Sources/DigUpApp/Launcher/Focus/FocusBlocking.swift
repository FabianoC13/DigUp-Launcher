import AppKit
import DigUpKit

/// Websites: the front browser's tab is read every 2 seconds; a blocked page is swapped for DigUp's block page (or
/// the tab is closed when that fails), and given back when the session ends.
extension FocusController {
    func checkFrontBrowser() async {
        guard let session, !session.timer.isPaused, !blockList.domains.isEmpty,
              let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
              let browser = FocusBrowser.known[bundleID], !refusedBrowsers.contains(bundleID) else { return }
        let read = await ProductivityAppleScript.run(FocusBrowser.readScript(bundleID: bundleID, dialect: browser.dialect),
                                                     timeout: 5)
        guard !Task.isCancelled, self.session != nil else { return }
        guard let address = read.value else {
            failed(read, browser: browser.name, bundleID: bundleID)
            return
        }
        guard let host = FocusDomains.host(ofPage: address),
              let domain = FocusDomains.match(host: host, domains: blockList.domains) else { return }
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let target = FocusBrowser.blockPageAddress(page: Self.blockPage, token: token, host: domain)
        if !FileManager.default.fileExists(atPath: Self.blockPage.path) { writeBlockPage(goal: session.goal) }
        let redirect = await ProductivityAppleScript.run(
            FocusBrowser.redirectScript(bundleID: bundleID, dialect: browser.dialect), arguments: [target, host],
            timeout: 5)
        guard !Task.isCancelled, self.session != nil else { return }
        switch redirect.value {
        case "blocked":
            self.session?.blockedTabs[bundleID, default: [:]][token] = address
        case "moved", "gone":
            return   // the tab left the page before it could be blocked
        default:
            // The browser wouldn't load a local page: close the tab instead.
            let close = await ProductivityAppleScript.run(
                FocusBrowser.closeScript(bundleID: bundleID, dialect: browser.dialect), timeout: 5)
            if close.value == nil { failed(close, browser: browser.name, bundleID: bundleID) }
        }
        markBlocked(domain)
    }

    private func markBlocked(_ domain: String) {
        guard var current = session else { return }
        current.blocks += 1
        session = current
        saveSession()
        ProductivityHUD.show("\(domain) is blocked while you focus", symbol: "hand.raised")
    }

    /// A browser that won't answer: without Automation permission DigUp says so once per session.
    private func failed(_ reply: ProductivityAppleScript.Reply, browser: String, bundleID: String) {
        if reply.errorNumber == ProductivityAppleScript.notAllowed {
            refusedBrowsers.insert(bundleID)
            log("focus: no Automation permission for \(browser)")
            ProductivityHUD.show("DigUp needs Automation permission for \(browser) to block websites: System Settings → "
                                 + "Privacy & Security → Automation", symbol: "lock", seconds: 6)
        } else if reply.errorNumber != -1712 {   // -1712: the permission question is still on screen
            log("focus: \(browser) didn't answer (\(reply.message))")
        }
    }

    /// The page blocked tabs show: what was blocked (from the address's `#h=`), and the session's goal.
    func writeBlockPage(goal: String) {
        let goalLine = goal.isEmpty ? "" : "<p class=\"goal\">Back to: \(Self.escapeHTML(goal))</p>"
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Blocked while you focus</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; --bg: #f6f7f4; --fg: #1d2420; --muted: #66706a; --accent: #3f8f5a; }
        @media (prefers-color-scheme: dark) { :root { --bg: #161a17; --fg: #e8ece9; --muted: #98a29c; } }
        body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--fg);
               font: 16px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
        main { text-align: center; padding: 32px; max-width: 520px; }
        .mark { font-size: 56px; color: var(--accent); line-height: 1; }
        h1 { font-size: 26px; margin: 16px 0 8px; font-weight: 650; }
        p { margin: 4px 0; color: var(--muted); }
        .goal { margin-top: 18px; color: var(--fg); font-weight: 500; }
        </style></head>
        <body><main>
        <div class="mark">◎</div>
        <h1 id="site">This site is blocked</h1>
        <p>DigUp is keeping it away until your focus session ends.</p>
        \(goalLine)
        </main>
        <script>
        const params = new URLSearchParams(location.hash.slice(1));
        const host = params.get("h");
        if (host) document.getElementById("site").textContent = host + " is blocked";
        </script>
        </body></html>
        """
        ProductivityFiles.write(Data(html.utf8), to: Self.blockPage)
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Gives blocked tabs their pages back (in browsers still running).
    func restoreTabs(_ tabs: [String: [String: String]]) {
        for (bundleID, blocked) in tabs where !blocked.isEmpty {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { continue }
            let arguments = blocked.flatMap { [$0.key, $0.value] }
            Task {
                let reply = await ProductivityAppleScript.run(FocusBrowser.restoreScript(bundleID: bundleID),
                                                              arguments: arguments, timeout: 10)
                if reply.value == nil { log("focus: couldn't give blocked tabs back (\(reply.message))") }
            }
        }
    }
}

// MARK: Menu bar

extension FocusController {
    func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.toolTip = "Focus session"
        statusItem = item
        rebuildMenu()
    }

    func rebuildMenu() {
        guard let statusItem, let session else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let goal = NSMenuItem(title: session.goal.isEmpty ? "Focus session" : session.goal, action: nil,
                              keyEquivalent: "")
        goal.isEnabled = false
        menu.addItem(goal)
        let line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        line.isEnabled = false
        menu.addItem(line)
        statusLine = line
        menu.addItem(.separator())
        if session.timer.isPaused {
            menu.addItem(focusMenuItem("Resume", symbol: "play") { [weak self] in self?.resume() })
        } else {
            menu.addItem(focusMenuItem("Pause", symbol: "pause") { [weak self] in self?.pause() })
        }
        if session.timer.duration != nil {
            menu.addItem(focusMenuItem("Add 10 Minutes", symbol: "plus") { [weak self] in self?.extend(by: 600) })
        }
        menu.addItem(focusMenuItem("Complete Session", symbol: "checkmark.circle") { [weak self] in self?.complete() })
        menu.addItem(.separator())
        menu.addItem(focusMenuItem("Edit Block List…", symbol: "slider.horizontal.3") { [weak self] in
            self?.openSettings()
        })
        statusItem.menu = menu
    }

    /// Settings → Launcher, where the Focus section is.
    func openSettings() {
        guard let app = launcher?.panel?.context.app else { return }
        app.settingsWindow.show(.launcher)
    }
}

/// A menu item that runs a closure: its target (kept alive as the item's represented object) calls it.
private func focusMenuItem(_ title: String, symbol: String, handler: @escaping () -> Void) -> NSMenuItem {
    let target = FocusMenuTarget(handler: handler)
    let item = NSMenuItem(title: title, action: #selector(FocusMenuTarget.fire), keyEquivalent: "")
    item.target = target
    item.representedObject = target
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    return item
}

private final class FocusMenuTarget: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() {
        handler()
    }
}
