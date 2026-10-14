import AppKit
import DigUpKit
import SwiftUI

/// Quick AI: type a question, press Tab, and the answer streams in from your API (DeepSeek).
enum QuickAIFeature: LauncherFeature {
    /// Tab in the root search: asks `prompt` (or opens Quick AI empty).
    static func ask(_ prompt: String, context: LauncherContext) {
        context.flash("Quick AI isn't set up yet")
    }
}
