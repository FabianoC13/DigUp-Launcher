import AppKit
import DigUpKit

/// `digup://` links (`QuicklinksDeeplink`), from a browser, a script (`open "digup://…"`), Shortcuts or another app:
/// run an item, search, ask AI, open a quicklink. A `run` link asks first, since any web page can open one, unless you
/// told it not to ask again for that item.
final class QuicklinksDeeplinks: NSObject {
    static let shared = QuicklinksDeeplinks()

    private weak var launcher: Launcher?
    private var store: QuicklinksStore?

    private override init() {}

    func start(launcher: Launcher, store: QuicklinksStore) {
        self.launcher = launcher
        self.store = store
        // Nothing else in DigUp takes URLs (no application(_:open:)), so this handler is the one for "Get URL".
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else {
            log("deeplink: an Apple event without a URL")
            return
        }
        Task { await open(url) }
    }

    /// Carries out a `digup://` link.
    func open(_ url: URL) async {
        guard let launcher, let store, let panel = launcher.panel else {
            log("deeplink: arrived before the launcher was ready")
            return
        }
        guard let link = QuicklinksDeeplink(url) else {
            log("deeplink: can't read a \(url.scheme ?? "") link")
            QuicklinksAlert.inform("DigUp can't open this link",
                                   detail: "Links look like digup://run/<id>, digup://search?q=…, digup://ai?q=… "
                                       + "or digup://quicklink/<name>?q=….")
            return
        }
        let context = LauncherContext(panel: panel)
        switch link {
        case .show:
            context.show()
        case .search(let query):
            context.show()
            context.popToRoot()
            context.query = query
        case .ai(let prompt):
            context.show()
            context.popToRoot()
            QuickAIFeature.ask(prompt.trimmingCharacters(in: .whitespacesAndNewlines), context: context)
        case .quicklink(let name, let argument):
            guard let record = store.record(named: name) else {
                log("deeplink: no quicklink by that name")
                QuicklinksAlert.inform("There's no quicklink “\(name)”",
                                       detail: "A quicklink link names one by its name or its keyword.")
                return
            }
            let template = store.template(for: record)
            var values: [String: String] = [:]
            if let argument, let key = QuicklinksItems.typedKey(template) { values[key] = argument }
            if let item = await launcher.item(id: "ql:\(record.id)") { launcher.recordUse(item, query: nil) }
            QuicklinksArguments.proceed(record, values: values, askOptional: argument == nil, store: store,
                                        context: context)
        case .run(let id):
            guard let item = await launcher.item(id: id) else {
                log("deeplink: nothing to run for that id")
                QuicklinksAlert.inform("Nothing in the launcher has this link",
                                       detail: "It may have been deleted, or come from another Mac.")
                return
            }
            guard trusted(item) else { return }
            await launcher.run(itemID: id)
        }
    }

    /// May the link run `item`? Yes when you said so before for it; otherwise asks, with a box to stop asking.
    private func trusted(_ item: LauncherItem) -> Bool {
        guard let store else { return false }
        if store.settings.trustedDeeplinks.contains(item.id) { return true }
        let alert = NSAlert()
        alert.messageText = "Run “\(item.title)”?"
        alert.informativeText = "A digup:// link asks to run it. Links can come from web pages and other apps."
        let run = alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        if item.actions.first?.style == .destructive { run.hasDestructiveAction = true }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again for “\(item.title)”"
        let front = NSWorkspace.shared.frontmostApplication
        bringAppToFront()
        let answer = alert.runModal()
        // The app the link came from gets the keyboard back (an item may act on the frontmost window).
        QuicklinksAlert.returnFocus(to: front)
        guard answer == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            store.updateSettings { $0.trustedDeeplinks.append(item.id) }
        }
        return true
    }
}
