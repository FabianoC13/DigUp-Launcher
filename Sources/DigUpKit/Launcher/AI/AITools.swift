import Foundation

/// One tool the model may call (OpenAI-compatible `tools` entry).
public struct AIToolDefinition: Encodable, Equatable, Sendable {
    public var name: String
    public var description: String
    /// JSON Schema object for the function arguments (`type: "object"`, `properties`, `required`).
    public var parameters: [String: AIJSONValue]

    public init(name: String, description: String, parameters: [String: AIJSONValue]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey { case type, function }

    private enum FunctionKeys: String, CodingKey { case name, description, parameters }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("function", forKey: .type)
        var function = container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        try function.encode(name, forKey: .name)
        try function.encode(description, forKey: .description)
        try function.encode(parameters, forKey: .parameters)
    }
}

/// A finished tool call the model asked for.
public struct AIToolCall: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// JSON object as a string (OpenAI's wire format).
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One streamed piece of a tool call (`choices[0].delta.tool_calls[i]`).
public struct AIToolCallDelta: Equatable, Sendable {
    public var index: Int
    public var id: String?
    public var name: String?
    public var arguments: String?

    public init(index: Int, id: String? = nil, name: String? = nil, arguments: String? = nil) {
        self.index = index
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Builds complete `AIToolCall`s from streamed deltas (arguments arrive as partial JSON strings).
public struct AIToolCallAccumulator: Sendable {
    private var slots: [Int: Slot] = [:]

    public init() {}

    public mutating func add(_ delta: AIToolCallDelta) {
        var slot = slots[delta.index] ?? Slot()
        if let id = delta.id, !id.isEmpty { slot.id = id }
        if let name = delta.name, !name.isEmpty { slot.name = name }
        if let arguments = delta.arguments { slot.arguments += arguments }
        slots[delta.index] = slot
    }

    /// Finished calls in index order. Incomplete ones (no id or name) are dropped.
    public func calls() -> [AIToolCall] {
        slots.keys.sorted().compactMap { index in
            guard let slot = slots[index], let id = slot.id, !id.isEmpty,
                  let name = slot.name, !name.isEmpty else { return nil }
            return AIToolCall(id: id, name: name, arguments: slot.arguments.isEmpty ? "{}" : slot.arguments)
        }
    }

    private struct Slot {
        var id: String?
        var name: String?
        var arguments = ""
    }
}

/// A small JSON value tree for tool schemas and argument parsing (avoids `Any` in the public API).
public enum AIJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AIJSONValue])
    case object([String: AIJSONValue])

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var object: [String: AIJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var array: [AIJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Parses a JSON object string into a dictionary; nil when it isn't an object.
    public static func parseObject(_ text: String) -> [String: AIJSONValue]? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(AIJSONValue.self, from: data) else { return nil }
        return value.object
    }
}

extension AIJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AIJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AIJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Mac file and shell helpers the model can use through Quick AI tools.
public enum AIMacToolCatalog {
    public static let listDirectory = "list_directory"
    public static let trashPath = "trash_path"
    public static let movePath = "move_path"
    public static let revealPath = "reveal_path"
    public static let openPath = "open_path"
    public static let lookAtImage = "look_at_image"
    public static let runShell = "run_shell"

    /// Tools offered when Mac access is on.
    public static var definitions: [AIToolDefinition] {
        [
            AIToolDefinition(
                name: listDirectory,
                description: "List files and folders at a path on this Mac. Use ~ for the home folder.",
                parameters: objectSchema(
                    properties: [
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Absolute path, or ~ / ~/Desktop / ~/Downloads…"),
                        ]),
                    ],
                    required: ["path"])),
            AIToolDefinition(
                name: lookAtImage,
                description: "Load a local image file so you can see and describe it (wallpaper, screenshot, photo). "
                    + "Use this instead of shell/sips/python when the user asks what an image looks like.",
                parameters: objectSchema(
                    properties: [
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Path to a PNG, JPEG, HEIC, GIF, WebP, TIFF, or BMP file."),
                        ]),
                    ],
                    required: ["path"])),
            AIToolDefinition(
                name: trashPath,
                description: "Move a file or folder to the Trash.",
                parameters: objectSchema(
                    properties: [
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Path of the item to trash."),
                        ]),
                    ],
                    required: ["path"])),
            AIToolDefinition(
                name: movePath,
                description: "Move or rename a file or folder.",
                parameters: objectSchema(
                    properties: [
                        "from": .object([
                            "type": .string("string"),
                            "description": .string("Current path."),
                        ]),
                        "to": .object([
                            "type": .string("string"),
                            "description": .string("Destination path (including the new name when renaming)."),
                        ]),
                    ],
                    required: ["from", "to"])),
            AIToolDefinition(
                name: revealPath,
                description: "Reveal a file or folder in Finder.",
                parameters: objectSchema(
                    properties: [
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Path to reveal."),
                        ]),
                    ],
                    required: ["path"])),
            AIToolDefinition(
                name: openPath,
                description: "Open a file or folder with the default app.",
                parameters: objectSchema(
                    properties: [
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Path to open."),
                        ]),
                    ],
                    required: ["path"])),
            AIToolDefinition(
                name: runShell,
                description: "Run a short shell command on this Mac (zsh -lc) and return stdout/stderr. Prefer the "
                    + "file tools for move/trash/open when they fit. DigUp asks before commands that can delete files.",
                parameters: objectSchema(
                    properties: [
                        "command": .object([
                            "type": .string("string"),
                            "description": .string("The shell command."),
                        ]),
                        "working_directory": .object([
                            "type": .string("string"),
                            "description": .string("Optional working directory (defaults to the home folder)."),
                        ]),
                    ],
                    required: ["command"])),
        ]
    }

    /// Extra system instructions when tools are available.
    public static let systemAddon = """
        You can act on this Mac with tools: list folders, move or trash files, reveal or open paths, look at image \
        files, and run short shell commands. Prefer the dedicated file tools for file work. Expand ~ yourself (or \
        pass it as written). DigUp asks before trashing items or running shell commands that can delete files; \
        list, move, open, reveal, look_at_image, and read-only shell (including clearing /tmp) run without asking. \
        After tools finish you must always reply with a short answer — never stop on a tool step alone. To describe \
        a wallpaper, screenshot or photo: find its path if needed, then call look_at_image on that path and describe \
        what you see — do not guess from sips/python pixel dumps or open it in Preview.
        """

    /// Expands `~` and `~/…` against the home directory; absolute paths pass through; relative paths are under home.
    public static func resolvePath(_ raw: String, home: String = NSHomeDirectory()) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("/") { return trimmed }
        return (home as NSString).appendingPathComponent(trimmed)
    }

    private static func objectSchema(properties: [String: AIJSONValue],
                                     required: [String]) -> [String: AIJSONValue] {
        [
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(AIJSONValue.string)),
        ]
    }
}

/// Whether a shell command looks able to delete or wipe files (DigUp asks before those).
public enum AIMacShellRisk {
    /// True when DigUp should confirm before running `command`.
    public static func canDeleteFiles(_ command: String) -> Bool {
        var text = command.lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Clearing system temp dirs is safe enough to run without asking (wallpaper/color probes use /tmp).
        text = stripTempRemovals(text)
        // Match commands, not pathnames (so `find ~/.Trash` does not ask).
        let patterns = [
            #"\brm\b"#,
            #"\brmdir\b"#,
            #"\bunlink\b"#,
            #"\bshred\b"#,
            #"\bsrm\b"#,
            #"(?:^|[;&|]\s*)(?:trash|gio\s+trash)\b"#,
            #"(?:^|[;&|]\s*)truncate\b"#,
            #"\bmkfs\b"#,
            #"diskutil\s+erase"#,
            #"git\s+clean\b"#,
            #"find\b[\s\S]*\s-delete\b"#,
            #"find\b[\s\S]*-exec\s+(?:rm|unlink|rmdir)\b"#,
            #"xargs\s+(?:rm|unlink|rmdir)\b"#,
            #"\bdd\b[\s\S]*\bof="#,
            #"(?:mv|cp)\b[\s\S]*/dev/null\b"#,
            #"secure\s+empty\s+trash"#,
            #"empty\s+trash"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Drops `rm`/`rmdir` aimed only at `/tmp`, `/var/folders`, `$tmp`, or `$TMPDIR`.
    private static func stripTempRemovals(_ command: String) -> String {
        let patterns = [
            #"\brm\s+(?:-[a-zA-Z]+\s+)*(?:--\s+)?(?:["']?\$(?:tmp|TMPDIR)["']?|["']?/(?:tmp|var/folders)/[^;&|\n]+["']?)"#,
            #"\brmdir\s+(?:-[a-zA-Z]+\s+)*(?:--\s+)?(?:["']?\$(?:tmp|TMPDIR)["']?|["']?/(?:tmp|var/folders)/[^;&|\n]+["']?)"#,
        ]
        return patterns.reduce(command) { partial, pattern in
            partial.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
    }
}
