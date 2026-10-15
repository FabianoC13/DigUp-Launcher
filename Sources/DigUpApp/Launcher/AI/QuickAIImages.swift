import AppKit
import DigUpKit
import ImageIO
import UniformTypeIdentifiers

/// An image waiting to go with the next Quick AI question (dropped or pasted onto the search field).
struct QuickAIPendingImage: Identifiable {
    let id: UUID
    let name: String
    let preview: NSImage
    let attachment: AIImageAttachment

    init(id: UUID = UUID(), name: String, preview: NSImage, attachment: AIImageAttachment) {
        self.id = id
        self.name = name
        self.preview = preview
        self.attachment = attachment
    }
}

/// Reads image files (and pasteboard image data) into `AIImageAttachment` data URLs for Quick AI.
enum QuickAIImages {
    /// Same ceiling as Clipboard History: larger pictures stay out rather than blowing up the request.
    static let maxBytes = ClipboardHistoryRules.maxBytes
    /// Longest side after a gentle downscale, so a Retina screenshot is still readable but not huge on the wire.
    static let maxPixelSide = 2048

    private static let fileTypes: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .tiff, .bmp]
    private static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]

    // MARK: Accept?

    static func canAccept(_ info: NSDraggingInfo) -> Bool {
        canAccept(info.draggingPasteboard)
    }

    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        if !(imageFileURLs(from: pasteboard).isEmpty) { return true }
        if hasFiles(pasteboard) { return false }   // a PDF or a folder: Finder's icon for it isn't a picture to send
        return pasteboardTypes.contains { pasteboard.data(forType: $0) != nil }
            || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    // MARK: Read

    static func fromDraggingInfo(_ info: NSDraggingInfo) -> [QuickAIPendingImage] {
        from(pasteboard: info.draggingPasteboard)
    }

    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> [QuickAIPendingImage] {
        from(pasteboard: pasteboard)
    }

    private static func from(pasteboard: NSPasteboard) -> [QuickAIPendingImage] {
        let urls = imageFileURLs(from: pasteboard)
        if !urls.isEmpty {
            return urls.compactMap { fromFile($0) }
        }
        // Files that aren't images come with Finder's icon for them as a picture: that isn't what was meant.
        if hasFiles(pasteboard) { return [] }
        for type in pasteboardTypes {
            if let data = pasteboard.data(forType: type), let image = fromData(data, name: "Clipboard image") {
                return [image]
            }
        }
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiff = image.tiffRepresentation,
           let pending = fromData(tiff, name: "Clipboard image") {
            return [pending]
        }
        return []
    }

    static func fromFile(_ url: URL) -> QuickAIPendingImage? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return fromData(data, name: url.lastPathComponent)
    }

    static func fromData(_ data: Data, name: String) -> QuickAIPendingImage? {
        guard let prepared = prepare(data) else { return nil }
        let preview = NSImage(data: prepared.png) ?? NSImage(size: NSSize(width: 1, height: 1))
        return QuickAIPendingImage(name: name, preview: preview,
                                   attachment: AIImageAttachment(dataURL: prepared.dataURL))
    }

    // MARK: Dragging helpers

    private static func hasFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private static func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: fileTypes.map(\.identifier),
        ]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { url in
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                return fileTypes.contains { type.conforms(to: $0) }
            }
            return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
                .contains(url.pathExtension.lowercased())
        }
    }

    // MARK: Encode

    private struct Prepared {
        var png: Data
        var dataURL: String
    }

    /// PNG (resized if needed) plus a `data:image/png;base64,…` URL. Nil when unreadable or still over the size cap.
    private static func prepare(_ data: Data) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixelSide,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = pngData(image),
              png.count <= maxBytes else { return nil }
        let dataURL = "data:image/png;base64," + png.base64EncodedString()
        return Prepared(png: png, dataURL: dataURL)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
