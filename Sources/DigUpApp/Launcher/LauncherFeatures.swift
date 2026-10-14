import Foundation

/// Every launcher feature, in the order their providers are asked. Each lives in its own folder under Launcher/.
enum LauncherFeatures {
    static let all: [any LauncherFeature.Type] = [
        AppsFeature.self,          // Apps/: applications, System Settings panes, running apps, files by name
        CalculatorFeature.self,    // Calculator/: math, units, currency, time zones, dates, definitions
        SystemFeature.self,        // System/: lock, sleep, dark mode, trash, volume…
        WindowsFeature.self,       // Windows/: window layouts, switch windows, menu bar items
        ClipboardFeature.self,     // Clipboard/: clipboard history
        SnippetsFeature.self,      // Snippets/: snippets and text expansion
        QuicklinksFeature.self,    // Quicklinks/: quicklinks, fallbacks, aliases/hotkeys/favorites, deeplinks, hyper key
        QuickAIFeature.self,       // AI/: Quick AI (Tab)
        ScheduleFeature.self,      // Schedule/: My Schedule (calendar)
        NotesFeature.self,         // Notes/: floating notes
        FocusFeature.self,         // Focus/: distraction blocking
        ScriptsFeature.self,       // Scripts/: script commands
    ]
}
