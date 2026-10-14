import AppKit
import DigUpKit
import SwiftUI

/// An item's icon at a size.
struct LauncherIconView: View {
    let icon: LauncherIcon
    var side: CGFloat = 28

    var body: some View {
        Group {
            switch icon {
            case .file(let url):
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .symbol(let name, let tint):
                ZStack {
                    RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                        .fill((tint ?? Brand.leaf).opacity(0.16))
                    Image(systemName: name)
                        .font(.system(size: side * 0.5, weight: .semibold))
                        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Brand.gradient))
                }
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .glyph(let text):
                ZStack {
                    RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                    Text(text)
                        .font(.system(size: side * 0.55, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            case .color(let color):
                RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                    .fill(color)
                    .overlay(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15)))
            }
        }
        .frame(width: side, height: side)
    }
}

/// A launcher row: icon, title, subtitle, and the accessory tag on the right. An answer gets a big row.
struct LauncherRow: View {
    let item: LauncherItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            LauncherIconView(icon: item.icon, side: item.section == .answer ? 34 : 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: item.section == .answer ? 17 : 13,
                                  weight: item.section == .answer ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if let accessory = item.accessory {
                Text(accessory)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, item.section == .answer ? 8 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.24) : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([item.title, item.subtitle, item.accessory].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The preview pane for a launcher item: what `detail` says, then its metadata and actions.
struct LauncherDetailView: View {
    let item: LauncherItem
    let run: (LauncherAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if !item.metadata.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(item.metadata.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                            Text(entry.value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11.5))
                    }
                }
            }
            if !item.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(item.actions.prefix(3).enumerated()), id: \.element.id) { index, action in
                        Button {
                            run(action)
                        } label: {
                            HStack(spacing: 4) {
                                Text(action.title)
                                Text(index == 0 ? "↩" : index == 1 ? "⌘↩" : action.shortcut?.display ?? "")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.detail {
        case .summary:
            VStack(spacing: 10) {
                Spacer(minLength: 20)
                LauncherIconView(icon: item.icon, side: 72)
                Text(item.title)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity)
        case .answer(let answer, let caption):
            VStack(spacing: 8) {
                Spacer(minLength: 30)
                Text(answer)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.3)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                if let caption {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        case .text(let text, let monospaced):
            ScrollView {
                Text(text)
                    .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .markdown(let markdown):
            ScrollView {
                MarkdownText(markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image(let url):
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("The image is gone").foregroundStyle(.secondary)
            }
        case .file(let url):
            VStack(spacing: 10) {
                ThumbnailView(url: url, side: 180)
                Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(tildePath(url.deletingLastPathComponent().path))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
        case .custom(let view):
            view
        }
    }
}

/// Markdown with paragraphs and code blocks: AttributedString handles inline formatting only, so blocks are split here.
struct MarkdownText: View {
    let markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code, let language):
                    VStack(alignment: .leading, spacing: 2) {
                        if !language.isEmpty {
                            Text(language).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal) {
                            Text(code)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    }
                case .text(let text):
                    Text(Self.inline(text))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    enum Block { case text(String), code(String, language: String) }

    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var text: [String] = []
        var code: [String]?
        var language = ""
        func flushText() {
            let joined = text.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty {
                for paragraph in joined.components(separatedBy: "\n\n") where !paragraph.isEmpty {
                    blocks.append(.text(paragraph))
                }
            }
            text = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n"), language: language))
                    code = nil
                } else {
                    flushText()
                    language = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3))
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else {
                text.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"), language: language)) }
        flushText()
        return blocks
    }

    /// Inline markdown, keeping line breaks; headings and list markers shown plainly.
    static func inline(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var line = line
            while line.hasPrefix("#") { line.removeFirst() }
            return line
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: lines.joined(separator: "\n"), options: options))
            ?? AttributedString(text)
    }
}

/// ⌘K: the selected item's actions, with their shortcuts.
struct ActionPanelView: View {
    let actions: [LauncherAction]
    let selection: Int
    let run: (LauncherAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Actions")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 8) {
                    if let symbol = action.symbol {
                        Image(systemName: symbol).frame(width: 16)
                    }
                    Text(action.title)
                        .foregroundStyle(action.style == .destructive ? Color.red : Color.primary)
                    Spacer(minLength: 12)
                    Text(index == 0 ? "↩" : index == 1 ? "⌘↩" : action.shortcut?.display ?? "")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(index == selection ? Color.accentColor.opacity(0.28) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { run(action) }
            }
        }
        .padding(6)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(radius: 12, y: 4)
    }
}

/// The mode's name before the field ("Clipboard History"), like Raycast's breadcrumb.
struct ModeChip: View {
    let mode: any LauncherMode

    var body: some View {
        HStack(spacing: 5) {
            LauncherIconView(icon: mode.icon, side: 18)
            Text(mode.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .fixedSize()
    }
}

/// Click selects, double-click runs, right-click shows the actions.
struct ItemClickArea: NSViewRepresentable {
    let actions: [LauncherAction]
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    let onAction: (LauncherAction) -> Void

    func makeNSView(context: Context) -> ItemClickView { ItemClickView() }

    func updateNSView(_ view: ItemClickView, context: Context) {
        view.actions = actions
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onAction = onAction
    }
}

final class ItemClickView: NSView {
    var actions: [LauncherAction] = []
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onAction: (LauncherAction) -> Void = { _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick() } else { onClick() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !actions.isEmpty else { return nil }
        onClick()
        let menu = NSMenu()
        for action in actions {
            menu.addItem(ActionMenuItem(action.title) { [onAction] in onAction(action) })
        }
        return menu
    }
}
