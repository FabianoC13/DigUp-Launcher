import AppKit
import DigUpKit
import SwiftUI

/// Quicklinks, fallback commands, per-item aliases/hotkeys/favorites, deeplinks (digup://) and the Hyper Key.
enum QuicklinksFeature: LauncherFeature {}

/// Actions every item that `tracksUsage` gets in its action panel (⌘K), after its own: favorites, alias, hotkey.
enum Personalization {
    static func actions(for item: LauncherItem, context: LauncherContext) -> [LauncherAction] { [] }
}
