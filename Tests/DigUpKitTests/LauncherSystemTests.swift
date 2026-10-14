import Foundation
import Testing
@testable import DigUpKit

@Suite struct LauncherSystemOutputTests {
    @Test func scriptErrorCodes() {
        let denied = "37:76: execution error: Not authorized to send Apple events to System Events. (-1743)\n"
        #expect(LauncherSystemOutput.scriptErrorCode(denied) == LauncherSystemOutput.notAuthorized)
        #expect(LauncherSystemOutput.scriptErrorCode("0:12: execution error: Finder got an error: AppleEvent timed out. (-1712)")
                == -1712)
        #expect(LauncherSystemOutput.scriptErrorCode("syntax error: Expected end of line (-2741)") == -2741)
        #expect(LauncherSystemOutput.scriptErrorCode("something went wrong") == nil)
        #expect(LauncherSystemOutput.scriptErrorCode("") == nil)
    }

    @Test func findsTheWiFiDevice() {
        let ports = """

            Hardware Port: Ethernet Adapter (en3)
            Device: en3
            Ethernet Address: 4e:22:da:a8:ba:80

            Hardware Port: Thunderbolt Bridge
            Device: bridge0
            Ethernet Address: 36:f4:37:82:a6:c0

            Hardware Port: Wi-Fi
            Device: en0
            Ethernet Address: 1c:f6:4c:ae:42:89

            VLAN Configurations
            ===================
            """
        #expect(LauncherSystemOutput.wifiDevice(inHardwarePorts: ports) == "en0")
        #expect(LauncherSystemOutput.wifiDevice(inHardwarePorts: "Hardware Port: AirPort\nDevice: en1\n") == "en1")
        #expect(LauncherSystemOutput.wifiDevice(inHardwarePorts: "Hardware Port: Ethernet\nDevice: en0\n") == nil)
        #expect(LauncherSystemOutput.wifiDevice(inHardwarePorts: "") == nil)
    }

    @Test func readsWiFiPower() {
        #expect(LauncherSystemOutput.wifiPower("Wi-Fi Power (en0): On\n") == true)
        #expect(LauncherSystemOutput.wifiPower("Wi-Fi Power (en0): Off") == false)
        #expect(LauncherSystemOutput.wifiPower("AirPort Power (en1): On") == true)
        #expect(LauncherSystemOutput.wifiPower("en3 is not a Wi-Fi interface.\n** Error: Error obtaining wireless information.")
                == nil)
    }

    @Test func readsDefaultsBooleans() {
        #expect(LauncherSystemOutput.defaultsBool("1\n") == true)
        #expect(LauncherSystemOutput.defaultsBool("YES") == true)
        #expect(LauncherSystemOutput.defaultsBool("true") == true)
        #expect(LauncherSystemOutput.defaultsBool("0") == false)
        #expect(LauncherSystemOutput.defaultsBool("NO") == false)
        #expect(LauncherSystemOutput.defaultsBool("") == nil)
    }

    @Test func listsNames() {
        #expect(LauncherSystemOutput.list([]) == "")
        #expect(LauncherSystemOutput.list(["Safari"]) == "Safari")
        #expect(LauncherSystemOutput.list(["Safari", "Mail"]) == "Safari and Mail")
        #expect(LauncherSystemOutput.list(["Safari", "Mail", "Notes"]) == "Safari, Mail and Notes")
        #expect(LauncherSystemOutput.list(["A", "B", "C", "D", "E"], limit: 3) == "A, B, C and 2 more")
    }
}

@Suite struct LauncherSystemVolumeTests {
    @Test func parsesVolumeSettings() throws {
        let settings = try #require(LauncherVolumeSettings("output volume:50, input volume:42, alert volume:100, output muted:false\n"))
        #expect(settings == LauncherVolumeSettings(output: 50, input: 42, alert: 100, muted: false))
    }

    @Test func anOutputWithoutAVolumeControl() throws {
        let settings = try #require(LauncherVolumeSettings(
            "output volume:missing value, input volume:missing value, alert volume:100, output muted:missing value"))
        #expect(settings.output == nil && settings.muted == nil && settings.alert == 100)
    }

    @Test func mutedAndFractional() throws {
        let settings = try #require(LauncherVolumeSettings("output volume:37.5, output muted:true"))
        #expect(settings.output == 38 && settings.muted == true)
    }

    @Test func notASettingsRecord() {
        #expect(LauncherVolumeSettings("") == nil)
        #expect(LauncherVolumeSettings("execution error: nope (-1)") == nil)
    }

    @Test func stepsStayInRange() {
        #expect(LauncherVolumeSettings.stepped(50, by: 6) == 56)
        #expect(LauncherVolumeSettings.stepped(97, by: 6) == 100)
        #expect(LauncherVolumeSettings.stepped(3, by: -6) == 0)
    }
}

@Suite struct LauncherSystemEjectTests {
    @Test func ejectsWhatFinderWould() {
        #expect(LauncherVolumeInfo(name: "USB", isEjectable: true, isRemovable: true, isInternal: false).shouldEject)
        #expect(LauncherVolumeInfo(name: "Installer", isEjectable: true, isInternal: nil).shouldEject)
        #expect(LauncherVolumeInfo(name: "Share", isLocal: false, isInternal: nil).shouldEject)
        #expect(LauncherVolumeInfo(name: "Backup", isLocal: true, isInternal: false).shouldEject)
    }

    @Test func neverTheStartupDiskOrAnInternalVolume() {
        #expect(!LauncherVolumeInfo(name: "Macintosh HD", isRoot: true, isEjectable: true).shouldEject)
        #expect(!LauncherVolumeInfo(name: "Data", isLocal: true, isInternal: true).shouldEject)
        #expect(!LauncherVolumeInfo(name: "Unknown", isLocal: nil, isInternal: nil).shouldEject)
    }
}
