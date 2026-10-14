import Foundation

/// One-step prompts on the selected text, like Raycast's AI Commands: rewrite it (and paste the result over the
/// selection), translate it, summarize or explain it, review code.
public enum AICommand: String, CaseIterable, Sendable {
    case fixSpelling = "fix-spelling"
    case improveWriting = "improve-writing"
    case summarize
    case explain
    case translateToEnglish = "translate-english"
    case translateToSpanish = "translate-spanish"
    case makeShorter = "make-shorter"
    case makeLonger = "make-longer"
    case professionalTone = "tone-professional"
    case friendlyTone = "tone-friendly"
    case findBugs = "find-bugs"

    public var title: String {
        switch self {
        case .fixSpelling: "Fix Spelling and Grammar"
        case .improveWriting: "Improve Writing"
        case .summarize: "Summarize"
        case .explain: "Explain This"
        case .translateToEnglish: "Translate to English"
        case .translateToSpanish: "Translate to Spanish"
        case .makeShorter: "Make Shorter"
        case .makeLonger: "Make Longer"
        case .professionalTone: "Change Tone to Professional"
        case .friendlyTone: "Change Tone to Friendly"
        case .findBugs: "Find Bugs in Code"
        }
    }

    /// What it does, for the list.
    public var subtitle: String {
        switch self {
        case .fixSpelling: "Corrects spelling, grammar and punctuation in the selected text"
        case .improveWriting: "Rewrites the selected text so it reads more clearly"
        case .summarize: "Sums up the selected text in a few points"
        case .explain: "Explains the selected text in simple terms"
        case .translateToEnglish: "Translates the selected text into English"
        case .translateToSpanish: "Translates the selected text into Spanish"
        case .makeShorter: "Rewrites the selected text at about half the length"
        case .makeLonger: "Expands the selected text with more detail"
        case .professionalTone: "Rewrites the selected text in a polished, professional tone"
        case .friendlyTone: "Rewrites the selected text in a warm, casual tone"
        case .findBugs: "Reviews the selected code and points out bugs"
        }
    }

    /// An SF Symbol.
    public var symbol: String {
        switch self {
        case .fixSpelling: "textformat.abc.dottedunderline"
        case .improveWriting: "wand.and.stars"
        case .summarize: "list.bullet.rectangle"
        case .explain: "lightbulb"
        case .translateToEnglish, .translateToSpanish: "character.bubble"
        case .makeShorter: "arrow.down.right.and.arrow.up.left"
        case .makeLonger: "arrow.up.left.and.arrow.down.right"
        case .professionalTone: "briefcase"
        case .friendlyTone: "face.smiling"
        case .findBugs: "ladybug"
        }
    }

    /// Other words it's found by.
    public var keywords: [String] {
        switch self {
        case .fixSpelling: ["spell check", "grammar", "proofread", "correct", "typos"]
        case .improveWriting: ["rewrite", "rephrase", "polish", "edit"]
        case .summarize: ["summary", "tldr", "tl;dr", "key points"]
        case .explain: ["explain", "simple terms", "what does this mean"]
        case .translateToEnglish: ["translate", "english", "translation"]
        case .translateToSpanish: ["translate", "spanish", "español", "traducir"]
        case .makeShorter: ["shorten", "shorter", "condense", "concise"]
        case .makeLonger: ["expand", "longer", "elaborate"]
        case .professionalTone: ["formal", "professional", "tone", "business"]
        case .friendlyTone: ["casual", "friendly", "tone", "informal"]
        case .findBugs: ["code review", "debug", "bugs", "review code"]
        }
    }

    /// The answer is the text itself, rewritten or translated: ↩ pastes it over the selection.
    public var replacesSelection: Bool {
        switch self {
        case .summarize, .explain, .findBugs: false
        default: true
        }
    }

    /// The system prompt.
    public var instructions: String {
        let rewrite = "Reply with only the resulting text: no introduction, no explanation, and no quotes or code "
            + "fences around it. Keep the formatting (line breaks, lists, Markdown) and any names, numbers and links."
        let sameLanguage = "Keep the text's language."
        switch self {
        case .fixSpelling:
            return "Fix the spelling, grammar and punctuation of the text. Change as little as possible: keep the "
                + "wording, tone and style. If there's nothing to fix, return the text unchanged. \(sameLanguage) \(rewrite)"
        case .improveWriting:
            return "Improve the writing of the text: make it clearer and let it flow better, with better word choice, "
                + "keeping its meaning, tone and roughly its length. \(sameLanguage) \(rewrite)"
        case .makeShorter:
            return "Make the text about half as long, keeping its key points and tone. \(sameLanguage) \(rewrite)"
        case .makeLonger:
            return "Make the text about twice as long by expanding on what's there, with more detail and explanation, "
                + "without inventing facts. Keep its tone. \(sameLanguage) \(rewrite)"
        case .professionalTone:
            return "Rewrite the text in a polished, professional tone suitable for work, keeping its meaning. "
                + "\(sameLanguage) \(rewrite)"
        case .friendlyTone:
            return "Rewrite the text in a warm, friendly, casual tone, keeping its meaning. \(sameLanguage) \(rewrite)"
        case .translateToEnglish:
            return "Translate the text into natural English. If it's already English, return it unchanged. \(rewrite)"
        case .translateToSpanish:
            return "Translate the text into natural Spanish. If it's already Spanish, return it unchanged. \(rewrite)"
        case .summarize:
            return "Summarize the text: one sentence with the gist, then the key points as a short bulleted list. "
                + "Use Markdown, and write in the text's language."
        case .explain:
            return "Explain the text in simple terms, as to a smart person who is new to the topic: what it means, any "
                + "jargon, and why it matters. Be concise, use Markdown, and write in the text's language."
        case .findBugs:
            return "Review the code for bugs: logic errors, unhandled edge cases, crashes, races and security problems. "
                + "For each, say where it is, why it's wrong and how to fix it (with a short code snippet when it "
                + "helps). If you find none, say so. Use Markdown."
        }
    }

    /// The user message: the text set apart in triple quotes, so instructions inside it are read as text.
    public func message(for text: String) -> String {
        let what = self == .findBugs ? "Code" : "Text"
        return "\(what):\n\"\"\"\n\(text)\n\"\"\""
    }
}
