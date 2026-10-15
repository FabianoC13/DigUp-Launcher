import Foundation

/// One thing you copied, as Clipboard History keeps it: what it is, where it came from, when, and whether it's pinned.
///
/// The text is kept here. An image's PNG, a text's rich flavors (RTF, HTML) and the whole of a very long text are files
/// beside the history, named after `id`; the app writes and deletes them.
public struct ClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text, link, email, color, image, files

        /// "Link", "Image".
        public var title: String {
            switch self {
            case .text: "Text"
            case .link: "Link"
            case .email: "Email"
            case .color: "Color"
            case .image: "Image"
            case .files: "Files"
            }
        }

        /// "Links", "Images": the type filter's name.
        public var pluralTitle: String {
            switch self {
            case .text: "Text"
            case .link: "Links"
            case .email: "Emails"
            case .color: "Colors"
            case .image: "Images"
            case .files: "Files"
            }
        }

        /// Text you can paste as text: everything but images and files.
        public var isTextual: Bool { self != .image && self != .files }
    }

    /// A UUID: the entry's files are named after it, and it stays when the same content is copied again.
    public var id: String
    public var kind: Kind
    /// The plain text (text, link, email, color); the file paths, one per line (files); empty for an image.
    public var text: String
    /// The text was longer than `textLimit`: `text` is its start, and the whole text is in a file beside the history.
    public var textInFile: Bool
    /// The copied files' paths (files).
    public var files: [String]
    /// An image's size in pixels.
    public var imageWidth: Int?
    public var imageHeight: Int?
    /// The size of an image's PNG, or of a text in UTF-8.
    public var byteCount: Int?
    /// Pasteboard types kept beside the text to paste it back formatted ("public.rtf", "public.html").
    public var richTypes: [String]
    /// The app in front when it was copied.
    public var sourceName: String?
    public var sourceBundleID: String?
    /// The last time it was copied: the history's order.
    public var copied: Date
    public var firstCopied: Date
    public var timesCopied: Int
    /// Pinned entries stay first, never expire, and survive Delete All.
    public var pinned: Bool
    /// A name you gave it (Rename), shown instead of its first line.
    public var customTitle: String?
    /// Text read from an image (OCR), so it can be searched.
    public var recognizedText: String?
    /// What makes two entries the same content (`ClipboardHistoryRules.fingerprint`).
    public var fingerprint: String

    /// Texts longer than this (in UTF-8 bytes) keep only their start in the history's index; the rest is in a file.
    public static let textLimit = 32_768

    public init(id: String = UUID().uuidString, kind: Kind, text: String = "", textInFile: Bool = false,
                files: [String] = [], imageWidth: Int? = nil, imageHeight: Int? = nil, byteCount: Int? = nil,
                richTypes: [String] = [], sourceName: String? = nil, sourceBundleID: String? = nil,
                copied: Date = Date(), firstCopied: Date? = nil, timesCopied: Int = 1, pinned: Bool = false,
                customTitle: String? = nil, recognizedText: String? = nil, fingerprint: String) {
        self.id = id
        self.kind = kind
        self.text = text
        self.textInFile = textInFile
        self.files = files
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.byteCount = byteCount
        self.richTypes = richTypes
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
        self.copied = copied
        self.firstCopied = firstCopied ?? copied
        self.timesCopied = timesCopied
        self.pinned = pinned
        self.customTitle = customTitle
        self.recognizedText = recognizedText
        self.fingerprint = fingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, textInFile, files, imageWidth, imageHeight, byteCount, richTypes, sourceName,
             sourceBundleID, copied, firstCopied, timesCopied, pinned, customTitle, recognizedText, fingerprint
    }

    /// Older indexes may lack newer keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        textInFile = try container.decodeIfPresent(Bool.self, forKey: .textInFile) ?? false
        files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
        imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try container.decodeIfPresent(Int.self, forKey: .imageHeight)
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount)
        richTypes = try container.decodeIfPresent([String].self, forKey: .richTypes) ?? []
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        copied = try container.decode(Date.self, forKey: .copied)
        firstCopied = try container.decodeIfPresent(Date.self, forKey: .firstCopied) ?? copied
        timesCopied = try container.decodeIfPresent(Int.self, forKey: .timesCopied) ?? 1
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        recognizedText = try container.decodeIfPresent(String.self, forKey: .recognizedText)
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) ?? id
    }

    /// The row's title: the name you gave it, else the first line of the text (80 characters at most), "Image
    /// (1280×720)", or the files' names.
    public var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        switch kind {
        case .image:
            guard let imageWidth, let imageHeight else { return "Image" }
            return "Image (\(imageWidth)×\(imageHeight))"
        case .files:
            let names = files.map { URL(fileURLWithPath: $0).lastPathComponent }
            return ClipboardClassifier.clipped(names.joined(separator: ", "))
        default:
            return ClipboardClassifier.title(of: text)
        }
    }

    /// The start of `text` that fits in `limit` UTF-8 bytes, cut between characters.
    public static func prefix(of text: String, bytes limit: Int = textLimit) -> String {
        guard text.utf8.count > limit else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: limit)
        while end > text.startIndex, end.samePosition(in: text) == nil {
            end = text.utf8.index(before: end)
        }
        return String(text[..<end])
    }
}
