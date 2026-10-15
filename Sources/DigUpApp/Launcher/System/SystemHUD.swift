import AppKit
import SwiftUI

/// A short message in a bubble near the bottom of the screen ("Volume 50%", "Ejected USB Drive"), like Raycast's HUD:
/// what a command says once it has run with the panel gone. It never takes the keyboard or the mouse.
enum SystemHUD {
    static let duration: TimeInterval = 1.6

    private static var window: NSPanel?
    private static var hideTask: Task<Void, Never>?

    /// In the panel's footer while the panel is up, else in the HUD.
    static func report(_ text: String, symbol: String? = nil, context: LauncherContext) {
        if context.isPanelVisible {
            context.flash(text)
        } else {
            show(text, symbol: symbol)
        }
    }

    static func show(_ text: String, symbol: String? = nil) {
        let panel = window ?? makeWindow()
        window = panel
        let hosting = NSHostingView(rootView: Bubble(text: text, symbol: symbol))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + area.height * 0.12,
                              width: size.width, height: size.height), display: true)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    if panel.alphaValue == 0 { panel.orderOut(nil) }
                }
            }
        }
    }

    private static func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Closing the launcher hides DigUp (`NSApp.hide`), which would take the bubble with it.
        panel.canHide = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private struct Bubble: View {
        let text: String
        let symbol: String?

        var body: some View {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: 460)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .padding(10)   // room for the shadow
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .accessibilityElement(children: .combine)
        }
    }
}
