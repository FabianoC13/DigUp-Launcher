import AppKit
import DigUpKit
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Records what you copy: checks the pasteboard's change count twice a second (cheap) and, when it moved, reads what
/// was copied, unless it's marked secret or passing (nspasteboard.org types), comes from an ignored app, or
/// recording is paused.
final class ClipboardWatcher {
    private let store: ClipboardStore
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    init(store: ClipboardStore) {
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func poll() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        if let own = store.takeOwnWrite(changeCount) {
            // DigUp put an entry back (Paste, Copy): it moves to the top; a restored clipboard isn't a copy.
            if let id = own { store.touch(id) }
            return
        }
        guard store.loaded, !store.settings.paused else { return }
        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard !types.isEmpty else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if ClipboardHistoryRules.shouldSkip(types: types, sourceBundleID: front?.bundleIdentifier,
                                            ignoredBundleIDs: store.ignoredBundleIDs) {
            log("clipboard: left a copy out (marked secret or passing, or from an ignored app)")
            return
        }
        capture(pasteboard, types: Set(types), source: front)
    }

    // MARK: Reading a copy

    private func capture(_ pasteboard: NSPasteboard, types: Set<String>, source: NSRunningApplication?) {
        let sourceName = source?.localizedName
        let sourceID = source?.bundleIdentifier
        let now = Date()

        // Files first: Finder also puts their names as text and their icons as an image.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map(\.path)
            store.record(ClipboardEntry(kind: .files, text: paths.joined(separator: "\n"), files: paths,
                                        sourceName: sourceName, sourceBundleID: sourceID, copied: now,
                                        fingerprint: ClipboardHistoryRules.fingerprint(kind: .files, files: paths)))
            return
        }

        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            captureText(text, pasteboard: pasteboard, types: types, sourceName: sourceName, sourceID: sourceID, at: now)
            return
        }

        for type in [NSPasteboard.PasteboardType.png, .tiff] where types.contains(type.rawValue) {
            guard let data = pasteboard.data(forType: type) else { continue }
            guard data.count <= ClipboardHistoryRules.maxBytes else {
                log("clipboard: left out an image over 20 MB")
                return
            }
            captureImage(data, sourceName: sourceName, sourceID: sourceID, at: now)
            return
        }
    }

    private func captureText(_ text: String, pasteboard: NSPasteboard, types: Set<String>, sourceName: String?,
                             sourceID: String?, at date: Date) {
        let bytes = text.utf8.count
        guard bytes <= ClipboardHistoryRules.maxBytes else {
            log("clipboard: left out a text over 20 MB")
            return
        }
        let kind = ClipboardClassifier.kind(of: text)
        let fingerprint = ClipboardHistoryRules.fingerprint(kind: kind, text: text)
        let id = UUID().uuidString
        var files: [(URL, Data)] = []
        var richTypes: [String] = []
        var total = bytes
        for type in [NSPasteboard.PasteboardType.rtf, .html] where types.contains(type.rawValue) {
            guard let data = pasteboard.data(forType: type), total + data.count <= ClipboardHistoryRules.maxBytes else {
                continue
            }
            total += data.count
            richTypes.append(type.rawValue)
            files.append((store.richURL(id, type: type.rawValue), data))
        }
        let inFile = bytes > ClipboardEntry.textLimit
        if inFile { files.append((store.textURL(id), Data(text.utf8))) }
        let entry = ClipboardEntry(id: id, kind: kind, text: inFile ? ClipboardEntry.prefix(of: text) : text,
                                   textInFile: inFile, byteCount: bytes, richTypes: richTypes, sourceName: sourceName,
                                   sourceBundleID: sourceID, copied: date, fingerprint: fingerprint)
        store.record(entry, files: files)
    }

    /// Converts and saves the image off the main thread, then records it and reads its text (for search).
    private func captureImage(_ data: Data, sourceName: String?, sourceID: String?, at date: Date) {
        let id = UUID().uuidString
        let imageURL = store.imageURL(id)
        let thumbnailURL = store.thumbnailURL(id)
        let known = store.knownFingerprints
        let store = store
        Task {
            let prepared = await Task.detached(priority: .utility) {
                ClipboardImaging.prepare(data, imageURL: imageURL, thumbnailURL: thumbnailURL, known: known)
            }.value
            guard let prepared else { return }
            let recordedID = store.record(ClipboardEntry(
                id: id, kind: .image, imageWidth: prepared.width, imageHeight: prepared.height,
                byteCount: prepared.byteCount, sourceName: sourceName, sourceBundleID: sourceID, copied: date,
                fingerprint: prepared.fingerprint))
            guard recordedID == id, prepared.saved else { return }
            let text = await Task.detached(priority: .background) { ClipboardImaging.recognizeText(at: imageURL) }.value
            if let text { store.setRecognizedText(text, for: id) }
        }
    }
}

/// Image work for Clipboard History, off the main thread.
nonisolated enum ClipboardImaging {
    nonisolated struct Prepared: Sendable {
        var fingerprint: String
        var width: Int?
        var height: Int?
        var byteCount: Int?
        /// False when the same image is already in the history (nothing was written).
        var saved: Bool
    }

    /// The thumbnail's longest side, in pixels.
    static let thumbnailSide = 256

    /// Saves the image as PNG with a thumbnail beside it, unless the history has it already (`known` fingerprints).
    /// Nil when it can't be read or its PNG is over 20 MB.
    static func prepare(_ data: Data, imageURL: URL, thumbnailURL: URL, known: Set<String>) -> Prepared? {
        let fingerprint = ClipboardHistoryRules.fingerprint(kind: .image, data: data)
        if known.contains(fingerprint) { return Prepared(fingerprint: fingerprint, saved: false) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int
        let height = properties?[kCGImagePropertyPixelHeight] as? Int
        let png: Data
        if (CGImageSourceGetType(source) as String?) == UTType.png.identifier {
            png = data
        } else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let converted = pngData(image) else {
                return nil
            }
            png = converted
        }
        guard png.count <= ClipboardHistoryRules.maxBytes else {
            log("clipboard: left out an image over 20 MB")
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: imageURL, options: .atomic)
        } catch {
            log("clipboard: couldn't save an image: \(error.localizedDescription)")
            return nil
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: thumbnailSide,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options), let small = pngData(thumbnail) {
            try? small.write(to: thumbnailURL, options: .atomic)
        }
        return Prepared(fingerprint: fingerprint, width: width, height: height, byteCount: png.count, saved: true)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The text in a picture (a screenshot of a page, a photo of a sign), so "image invoice" finds it.
    static func recognizeText(at url: URL) -> String? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 2048,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
