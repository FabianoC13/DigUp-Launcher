import AppKit
import DigUpKit
import SwiftUI

/// What the conversation's buttons do: copy text, retry, open Settings (the mode supplies them).
struct QuickAIViewActions {
    var copy: (String, String) -> Void
    var retry: () -> Void
    var openSettings: () -> Void
}

/// The Quick AI chat in the panel: each question, then its answer streaming in as Markdown, following the stream to
/// the bottom unless you've scrolled up to read.
struct QuickAIConversationView: View {
    let chat: QuickAIChat
    let scroller: QuickAIScroller
    let actions: QuickAIViewActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if chat.turns.isEmpty {
                    QuickAIEmptyState(chat: chat)
                }
                ForEach(chat.turns) { turn in
                    QuickAITurnView(turn: turn, command: chat.command, source: chat.source,
                                    isLast: turn === chat.turns.last, actions: actions)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QuickAIScrollFinder(scroller: scroller))
        }
        .onChange(of: chat.tick) { _, _ in
            scroller.follow()
        }
    }
}

/// Nothing asked yet: what to do, and which model answers.
private struct QuickAIEmptyState: View {
    let chat: QuickAIChat

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: chat.command?.symbol ?? "sparkles")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Brand.gradient)
            if let notice = chat.notice {
                Text(notice)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            } else {
                Text("Ask anything").font(.system(size: 16, weight: .semibold))
                let preferences = QuickAIPreferences.shared
                Text("\(preferences.provider.name) answers with \(preferences.displayName(chat.model)). Type a "
                     + "question and press ↩.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !QuickAIHistory.shared.chats.isEmpty {
                    Text("⌘[ opens your last chat · ⌘K for more")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}

/// A question and its answer.
private struct QuickAITurnView: View {
    let turn: QuickAITurn
    let command: AICommand?
    let source: String?
    let isLast: Bool
    let actions: QuickAIViewActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuickAIQuestionView(text: turn.shown ?? turn.question,
                                label: turn.label ?? (turn.shown != nil
                                    ? command.map { "\($0.title) · \(source ?? "selected text")" } : nil))
            header
            if !turn.reasoning.isEmpty {
                QuickAIThinkingView(reasoning: turn.reasoning, thinking: turn.phase == .thinking,
                                    time: turn.thinkingTime)
            }
            if turn.showsChanges, let original = turn.original, turn.phase == .done,
               let runs = AIWordDiff.runs(from: original, to: AICommand.cleanRewrite(turn.answer)) {
                QuickAIChangesView(runs: runs)
            } else if !turn.answer.isEmpty {
                QuickAIMarkdownView(markdown: turn.answer, copy: actions.copy)
            }
            if let note = turn.note {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if let failure = turn.failure {
                QuickAIErrorView(failure: failure, showsRetry: isLast, actions: actions)
            }
        }
    }

    /// The model, what it's doing, and Copy.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.gradient)
            Text(QuickAIPreferences.shared.displayName(turn.model))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            if turn.isBusy {
                ProgressView().controlSize(.mini)
                Text(status)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            } else if turn.phase == .stopped {
                Text("Stopped").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            } else if let time = turn.answerTime, turn.phase == .done {
                Text(String(format: "%.1f s", time.quickAISeconds))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if turn.original != nil, turn.phase == .done {
                Button(turn.showsChanges ? "Hide Changes" : "Show Changes") { turn.showsChanges.toggle() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
                    .help("What the rewrite changed (⌘D)")
            }
            if !turn.answer.isEmpty, !turn.isBusy {
                Button {
                    actions.copy(command?.replacesSelection == true ? AICommand.cleanRewrite(turn.answer) : turn.answer,
                                 "Copied the answer")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy this answer")
            }
        }
    }

    private var status: String {
        switch turn.phase {
        case .readingKey: "Reading the API key…"
        case .waiting: "Waiting for the answer…"
        case .thinking: "Thinking…"
        default: "Answering…"
        }
    }
}

/// Your question, folded to a few lines when it's long (Show More unfolds it).
private struct QuickAIQuestionView: View {
    let text: String
    /// "Fix Spelling and Grammar · selected text" above an AI command's text.
    let label: String?
    @State private var expanded = false

    static let foldedLines = 6

    private var isLong: Bool {
        text.count > 420 || text.split(separator: "\n", omittingEmptySubsequences: false).count > Self.foldedLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            Text(text)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(isLong && !expanded ? Self.foldedLines : nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isLong {
                Button(expanded ? "Show Less" : "Show More") { expanded.toggle() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// The model's reasoning, folded under "Thinking…" / "Thought for 4.2 s"; never part of the answer.
private struct QuickAIThinkingView: View {
    let reasoning: String
    let thinking: Bool
    let time: Duration?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(reasoning)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text(thinking ? "Thinking…" : time.map { String(format: "Thought for %.1f s", $0.quickAISeconds) }
                ?? "Thoughts")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// A failed answer: why, in plain words, with Retry and (when the fix is there) Settings.
private struct QuickAIErrorView: View {
    let failure: AIFailure
    let showsRetry: Bool
    let actions: QuickAIViewActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(failure.message)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if showsRetry {
                    Button("Retry  ⌘R") { actions.retry() }
                }
                if failure.needsSettings {
                    Button("Open Quick AI Settings") { actions.openSettings() }
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.1)))
    }
}

/// A rewrite as its changes: removed words struck through in red, added ones in green.
private struct QuickAIChangesView: View {
    let runs: [AIWordDiff.Run]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !AIWordDiff.changed(runs) {
                Label("Nothing changed", systemImage: "checkmark.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Text(attributed)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var attributed: AttributedString {
        var text = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            switch run.kind {
            case .same:
                break
            case .added:
                part.foregroundColor = .green
                part.backgroundColor = Color.green.opacity(0.14)
            case .removed:
                part.foregroundColor = .red
                part.strikethroughStyle = .single
                part.backgroundColor = Color.red.opacity(0.1)
            }
            text += part
        }
        return text
    }
}

// MARK: Markdown

/// An answer's Markdown: headings, paragraphs, lists, quotes, tables and code blocks (with the language, Copy and a
/// line-wrap switch), inline formatting through `AttributedString`.
struct QuickAIMarkdownView: View {
    let markdown: String
    let copy: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(AIMarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                QuickAIBlockView(block: block, copy: copy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline Markdown (bold, italic, `code`, links), line breaks kept.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct QuickAIBlockView: View, Equatable {
    let block: AIMarkdownBlock
    let copy: (String, String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.block == rhs.block }

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(QuickAIMarkdownView.inline(text))
                .font(.system(size: level == 1 ? 17 : level == 2 ? 15 : 13.5, weight: .semibold))
                .padding(.top, 4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(QuickAIMarkdownView.inline(text))
                .font(.system(size: 13.5))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: 13.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(QuickAIMarkdownView.inline(text))
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Text(QuickAIMarkdownView.inline(text))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider().padding(.vertical, 2)
        case .table(let rows, let header):
            QuickAITableView(rows: rows, header: header)
        case .code(let code, let language):
            QuickAICodeBlock(code: code, language: language, copy: copy)
        }
    }
}

private struct QuickAITableView: View {
    let rows: [[String]]
    let header: Bool

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(QuickAIMarkdownView.inline(column < row.count ? row[column] : ""))
                                .font(.system(size: 12.5, weight: header && index == 0 ? .semibold : .regular))
                                .textSelection(.enabled)
                        }
                    }
                    if header && index == 0 { Divider() }
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

/// A fenced code block: its language, Copy, and long lines scrolling sideways or wrapped.
private struct QuickAICodeBlock: View {
    let code: String
    let language: String
    let copy: (String, String) -> Void
    @State private var wraps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(wraps ? "No Wrap" : "Wrap") { wraps.toggle() }
                    .help(wraps ? "Scroll long lines sideways" : "Wrap long lines")
                Button {
                    copy(code, "Copied the code")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy this code")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider().opacity(0.5)
            Group {
                if wraps {
                    Text(code)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal) {
                        Text(code).fixedSize()
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: Scrolling

/// The conversation's scroll view, found through AppKit: the arrow keys scroll it, and the stream is followed to the
/// bottom while you're there (scroll up to read, and it stays put).
final class QuickAIScroller {
    weak var scrollView: NSScrollView? {
        didSet {
            guard scrollView !== oldValue else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let clip = scrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsChanged() }
            }
        }
    }
    /// At (or near) the bottom: new text scrolls into view.
    private(set) var followsStream = true
    /// Removed in deinit, which runs off the main actor (removing an observer is thread-safe).
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var scrolling = false

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private var maxOffset: CGFloat {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        return max(0, document.frame.height - scrollView.contentView.bounds.height)
    }

    /// From the top (the document view is flipped in SwiftUI's scroll views; handled either way).
    private var offset: CGFloat {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        let y = scrollView.contentView.bounds.origin.y
        return document.isFlipped ? y : maxOffset - y
    }

    private func boundsChanged() {
        guard !scrolling else { return }
        followsStream = maxOffset - offset < 40
    }

    /// New text arrived: keep the bottom in view, if that's where you are.
    func follow() {
        guard followsStream else { return }
        // After SwiftUI has laid out the new text.
        DispatchQueue.main.async { [weak self] in self?.scroll(to: .greatestFiniteMagnitude) }
    }

    /// A question was sent: back to following.
    func resume() {
        followsStream = true
        follow()
    }

    func scroll(by delta: CGFloat) {
        scroll(to: offset + delta)
        followsStream = maxOffset - offset < 40
    }

    func page(_ direction: CGFloat) {
        let height = scrollView?.contentView.bounds.height ?? 300
        scroll(by: direction * max(60, height - 50))
    }

    func scrollToTop() { scroll(by: -.greatestFiniteMagnitude) }
    func scrollToBottom() {
        followsStream = true
        scroll(to: .greatestFiniteMagnitude)
    }

    private func scroll(to target: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let top = min(max(0, target), maxOffset)
        let y = document.isFlipped ? top : maxOffset - top
        scrolling = true
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrolling = false
    }
}

/// An invisible view inside the scroll view's content that hands the scroll view to `QuickAIScroller`.
private struct QuickAIScrollFinder: NSViewRepresentable {
    let scroller: QuickAIScroller

    func makeNSView(context: Context) -> FinderView {
        let view = FinderView()
        view.scroller = scroller
        return view
    }

    func updateNSView(_ view: FinderView, context: Context) {
        view.scroller = scroller
        if scroller.scrollView == nil { scroller.scrollView = view.enclosingScrollView }
    }

    final class FinderView: NSView {
        weak var scroller: QuickAIScroller?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, let scrollView = enclosingScrollView { scroller?.scrollView = scrollView }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
