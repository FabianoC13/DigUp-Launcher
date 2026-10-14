import AppKit
import ApplicationServices
import DigUpKit

extension WindowsFeature {
    /// An Accessibility element (a window, a menu item, an app) that can be handed between threads: the AX API may be
    /// called from any thread, and its calls into other apps are best kept off the main one.
    nonisolated struct Element: @unchecked Sendable, Hashable {
        let ref: AXUIElement

        static func == (a: Element, b: Element) -> Bool { CFEqual(a.ref, b.ref) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(ref)) }
    }

    /// The Accessibility API calls the window commands, Switch Windows and Search Menu Items make. Each one is a
    /// message to another app, so they run off the main thread, with a short timeout for apps that hang.
    nonisolated enum AX {
        /// How long a call waits for an app before giving up (the system's default is 6 s).
        static let timeout: Float = 1.0

        static func application(_ pid: pid_t) -> Element {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, timeout)
            return Element(ref: app)
        }

        static func value(_ element: Element, _ attribute: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element.ref, attribute as CFString, &value) == .success else { return nil }
            return value
        }

        static func string(_ element: Element, _ attribute: String) -> String? {
            value(element, attribute) as? String
        }

        static func bool(_ element: Element, _ attribute: String) -> Bool? {
            (value(element, attribute) as? NSNumber)?.boolValue
        }

        static func int(_ element: Element, _ attribute: String) -> Int? {
            (value(element, attribute) as? NSNumber)?.intValue
        }

        static func element(_ element: Element, _ attribute: String) -> Element? {
            guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return Element(ref: unsafeDowncast(value, to: AXUIElement.self))
        }

        static func elements(_ element: Element, _ attribute: String) -> [Element] {
            elements(in: value(element, attribute))
        }

        /// Several attributes in one message to the app (much faster than one at a time when walking menus); nil for
        /// each one the element doesn't have.
        static func values(_ element: Element, _ attributes: [String]) -> [CFTypeRef?] {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element.ref, attributes as CFArray,
                                                         AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let array = values as? [AnyObject], array.count == attributes.count
            else { return Array(repeating: nil, count: attributes.count) }
            return array.map { value -> CFTypeRef? in
                if value is NSNull { return nil }
                // A missing attribute comes back as an AXValue holding the error.
                if CFGetTypeID(value) == AXValueGetTypeID(),
                   AXValueGetType(unsafeDowncast(value, to: AXValue.self)) == .axError { return nil }
                return value
            }
        }

        static func elements(in value: CFTypeRef?) -> [Element] {
            guard let array = value as? [AnyObject] else { return [] }
            return array.compactMap { item in
                CFGetTypeID(item) == AXUIElementGetTypeID() ? Element(ref: unsafeDowncast(item, to: AXUIElement.self)) : nil
            }
        }

        @discardableResult
        static func set(_ element: Element, _ attribute: String, _ value: CFTypeRef) -> Bool {
            AXUIElementSetAttributeValue(element.ref, attribute as CFString, value) == .success
        }

        @discardableResult
        static func perform(_ element: Element, _ action: String) -> AXError {
            AXUIElementPerformAction(element.ref, action as CFString)
        }

        // MARK: Windows

        /// The window an app has in front: its focused window, else its main one, else its first standard one.
        static func frontWindow(of pid: pid_t) -> Element? {
            let app = application(pid)
            if let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) {
                return window
            }
            return elements(app, kAXWindowsAttribute).first { string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
        }

        /// Where a window is, in Accessibility coordinates (top left of the main display, y down).
        static func frame(of window: Element) -> LauncherWindowRect? {
            guard let positionValue = value(window, kAXPositionAttribute), let sizeValue = value(window, kAXSizeAttribute),
                  CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
            else { return nil }
            var position = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
                  AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
            return LauncherWindowRect(x: position.x, y: position.y, width: size.width, height: size.height)
        }

        @discardableResult
        static func setPosition(_ window: Element, x: Double, y: Double) -> Bool {
            var point = CGPoint(x: x, y: y)
            guard let value = AXValueCreate(.cgPoint, &point) else { return false }
            return set(window, kAXPositionAttribute, value)
        }

        @discardableResult
        static func setSize(_ window: Element, width: Double, height: Double) -> Bool {
            var size = CGSize(width: width, height: height)
            guard let value = AXValueCreate(.cgSize, &size) else { return false }
            return set(window, kAXSizeAttribute, value)
        }

        /// Moves and resizes a window: position, then size, then position again, since an app may clamp the size to
        /// the display it was on, or move the window while it resizes. Apps that animate their own frame changes
        /// (Chromium and Electron with "enhanced user interface" on) get it turned off meanwhile, or they'd fight it.
        /// Returns where the window ended up.
        static func setFrame(_ window: Element, to rect: LauncherWindowRect, pid: pid_t) -> LauncherWindowRect? {
            let app = application(pid)
            let enhanced = bool(app, "AXEnhancedUserInterface") == true
            if enhanced { set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
            defer { if enhanced { set(app, "AXEnhancedUserInterface", kCFBooleanTrue) } }
            setPosition(window, x: rect.x, y: rect.y)
            setSize(window, width: rect.width, height: rect.height)
            setPosition(window, x: rect.x, y: rect.y)
            return frame(of: window)
        }

        static func isFullScreen(_ window: Element) -> Bool {
            bool(window, "AXFullScreen") == true
        }

        static func isMinimized(_ window: Element) -> Bool {
            bool(window, kAXMinimizedAttribute) == true
        }

        /// The window server's id of a window: stable while the window lives. Private (`_AXUIElementGetWindow`), so
        /// nil if it ever goes.
        static func windowID(_ window: Element) -> CGWindowID? {
            guard let getWindow = getWindowFunction else { return nil }
            var id: CGWindowID = 0
            return getWindow(window.ref, &id) == .success && id != 0 ? id : nil
        }

        private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        private static let getWindowFunction: GetWindow? = {
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
            return unsafeBitCast(symbol, to: GetWindow.self)
        }()

        /// Brings a window forward in its app, out of the Dock if it was minimized, and makes it the app's main one.
        static func raise(_ window: Element, pid: pid_t) {
            if isMinimized(window) { set(window, kAXMinimizedAttribute, kCFBooleanFalse) }
            perform(window, kAXRaiseAction)
            set(window, kAXMainAttribute, kCFBooleanTrue)
            set(window, kAXFocusedAttribute, kCFBooleanTrue)
            // The app in front, too (activating from DigUp can be refused once DigUp isn't the active app).
            set(application(pid), kAXFrontmostAttribute, kCFBooleanTrue)
        }
    }

    /// The displays, in Accessibility coordinates: their whole frame and the part windows may use (no menu bar, no
    /// Dock).
    struct Display: Sendable {
        let frame: LauncherWindowRect
        let visible: LauncherWindowRect

        static func all() -> [Display] {
            let screens = NSScreen.screens
            // The main display (with the menu bar) is the first, at AppKit's origin; AX's y runs down from its top.
            guard let mainHeight = screens.first?.frame.height else { return [] }
            return screens.map { screen in
                Display(frame: LauncherWindowGeometry.flipped(rect(screen.frame), mainHeight: mainHeight),
                        visible: LauncherWindowGeometry.flipped(rect(screen.visibleFrame), mainHeight: mainHeight))
            }
        }

        private static func rect(_ rect: NSRect) -> LauncherWindowRect {
            LauncherWindowRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }
    }
}
