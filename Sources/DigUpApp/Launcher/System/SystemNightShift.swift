import AppKit
import DigUpKit

// Low Power Mode (pmset, as an administrator) and Night Shift (CoreBrightness, what Control Center's switch uses).
extension SystemFeature {
    // MARK: Low Power Mode

    /// Low Power Mode the other way round. `pmset` changes it only as root, so macOS asks for an administrator's
    /// password (osascript's `with administrator privileges`).
    static func toggleLowPowerMode(_ context: LauncherContext) async {
        let settings = await runTool("/usr/bin/pmset", ["-g"])
        guard let mode = LauncherSystemOutput.pmsetSetting("lowpowermode", in: settings.output) else {
            SystemHUD.report("This Mac has no Low Power Mode", symbol: "leaf", context: context)
            return
        }
        let on = mode == 0
        let result = await appleScript(
            ["do shell script \"/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)\" with administrator privileges"],
            timeout: 180)
        if result.succeeded {
            SystemHUD.report(on ? "Low Power Mode on" : "Low Power Mode off", symbol: on ? "leaf.fill" : "leaf",
                             context: context)
        } else if result.errorCode != LauncherSystemOutput.userCancelled {
            log("system: pmset lowpowermode failed: \(result.errorCode.map(String.init) ?? "no code")")
            SystemHUD.report("Couldn't change Low Power Mode", symbol: "exclamationmark.triangle", context: context)
        }
    }

    // MARK: Night Shift

    /// Night Shift on if it's off, off if it's on: until the next scheduled change, like Control Center's switch.
    static func toggleNightShift(_ context: LauncherContext) {
        guard let client = NightShift.client(), let enabled = NightShift.isEnabled(client) else {
            SystemHUD.report("Night Shift isn't available on this Mac", symbol: "moon.circle", context: context)
            return
        }
        guard NightShift.setEnabled(!enabled, client) else {
            log("system: CBBlueLightClient setEnabled: refused")
            SystemHUD.report("Couldn't change Night Shift", symbol: "exclamationmark.triangle", context: context)
            return
        }
        SystemHUD.report(enabled ? "Night Shift off" : "Night Shift on",
                         symbol: enabled ? "sun.max.fill" : "moon.circle.fill", context: context)
    }

    /// CoreBrightness's `CBBlueLightClient`, a private class: looked up at run time, so that a macOS without it only
    /// loses the command.
    private enum NightShift {
        private static let getStatus = NSSelectorFromString("getBlueLightStatus:")
        private static let setEnabledSelector = NSSelectorFromString("setEnabled:")

        static func client() -> NSObject? {
            guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
                  let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type
            else { return nil }
            let client = type.init()
            guard client.responds(to: getStatus), client.responds(to: setEnabledSelector) else { return nil }
            return client
        }

        /// Whether it's on now. The status is a C struct that begins `BOOL active; BOOL enabled; …` (about 40
        /// bytes); it's read into a larger zeroed buffer so that a struct grown in a later macOS still fits.
        static func isEnabled(_ client: NSObject) -> Bool? {
            typealias Get = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
            let get = unsafeBitCast(client.method(for: getStatus), to: Get.self)
            let status = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 16)
            defer { status.deallocate() }
            status.initializeMemory(as: UInt8.self, repeating: 0, count: 256)
            guard get(client, getStatus, status) else { return nil }
            return status.load(fromByteOffset: 1, as: UInt8.self) != 0
        }

        static func setEnabled(_ enabled: Bool, _ client: NSObject) -> Bool {
            typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Bool
            let set = unsafeBitCast(client.method(for: setEnabledSelector), to: SetEnabled.self)
            return set(client, setEnabledSelector, enabled)
        }
    }
}
