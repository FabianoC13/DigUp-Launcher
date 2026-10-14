# DigUp Launcher (Raycast-style fork)

DigUp's ⌘Space panel becomes a Raycast-style launcher. Typing shows apps, commands and answers instantly at the top;
DigUp's meaning search of files (EmbeddingGemma 2, unchanged) streams in below once 3+ characters are typed. Tab sends
what's typed to Quick AI (the user's DeepSeek API). Everything except Quick AI and currency rates runs locally.

The catalog of Raycast functions this is modelled on is in `raycast-catalog.json` (read from raycast.com, Oct 2026).

## Architecture (foundation — `Sources/DigUpApp/Launcher/`)

- `LauncherItem` (LauncherItem.swift): one row. `id` is `"<provider id>:<stable key>"`. Title, subtitle, icon
  (`LauncherIcon`), accessory tag, `section` (`LauncherSection`: answer, favorites, suggestions, results, files,
  fallback, or `.named(...)` in modes), `score` 0…1, `actions` (first = ↩, second = ⌘↩, all in ⌘K), `detail` (the right
  pane: summary, answer, text, markdown, image, file, custom view), `metadata`, `tracksUsage`.
- `LauncherAction`: id, title, SF Symbol, `LauncherShortcut`, style, `keepsPanelOpen`, async `run(LauncherContext)`.
  Unless `keepsPanelOpen`, the panel hides (keyboard back to the previous app) before `run` starts.
- `LauncherProvider` (Launcher.swift): `id`, `items(for: LauncherQuery) async`, `item(id:) async` (for favorites,
  suggestions, aliases, hotkeys). All providers run concurrently per keystroke; each one's items show as soon as ready.
  Check `Task.isCancelled` after any await.
- `LauncherMode`: a pushed view (Clipboard History, Quick AI…). List modes return items; others return a SwiftUI view
  from `makeView(context:)`. `handle(_:query:context:)` sees keys first (except Esc and ⌘K). Esc / ⌫-on-empty pops.
- `LauncherFeature`: static `providers(_:)`, `start(_:)`, `settingsTitle`, `settingsView(_:)`. Registered in
  `LauncherFeatures.all`. Each feature lives in its own folder and owns only its files.
- `Launcher`: runs providers, ranks (provider score + 0.35·frecency + 0.5·pick boost; alias match = 3), suggestions
  for an empty query (favorites, then most used), `run(itemID:)`, `personalize { usage in … }`, `recordUse`.
  `Launcher.directory` = ~/Library/Application Support/DigUp/Launcher/ for feature data.
- `LauncherContext` (LauncherContext.swift): hide, show, push(mode), popToRoot, refresh, flash, copy, paste (⌘V into
  `previousApp`, needs Accessibility), open, confirm, prompt. Also `Accessibility.isTrusted(prompt:)`,
  `Keystrokes.post`.
- Pure logic goes in `Sources/DigUpKit/Launcher/` (testable with `swift test`): `FuzzyMatch`, `LauncherUsage`, and each
  feature's parsers/math.
- Panel: `SearchPanelController` (SearchPanel.swift) keeps `items`, `modes`, action panel state, `previousApp`; keys:
  ↑↓, ↩ primary, ⌘↩ secondary, ⌘K actions, item shortcuts, Tab → `QuickAIFeature.ask`, Esc pops/closes.
- Global hotkeys: `GlobalHotkey(combo) { … }` (Hotkey.swift) — several can be registered at once.
- Fork: hotkey default ⌘Space (turn off Spotlight's), Sparkle updates off, `digup://` URL scheme and calendar usage
  strings in Info.plist, calendars entitlement.

## Features (one folder each)

| Folder | Feature |
|---|---|
| Apps/ | Applications (scan + Spotlight for apps, icons, frecency), System Settings panes, running apps (quit, hide, force quit), files and folders by name (NSMetadataQuery) |
| Calculator/ | Math, percentages, units, currency (cached daily rates), time zones, dates, number bases; Define (DictionaryServices) |
| System/ | Lock, sleep, sleep displays, restart, shut down, log out, empty trash, dark mode, hidden files, volume, mute, eject, quit/hide all apps, screen saver, show desktop… |
| Windows/ | Halves, quarters, thirds, two-thirds, maximize, almost maximize, center, restore, next/previous display, fullscreen (AX); Switch Windows; Search Menu Items |
| Clipboard/ | Clipboard History mode: text, links, colors, images, files; pin, delete, paste, copy; skips concealed/transient types and password managers; retention setting |
| Snippets/ | Snippets: create/edit/search/paste; keyword text expansion (event tap); dynamic placeholders ({clipboard}, {date}, {time}, {cursor}…) |
| Quicklinks/ | Quicklinks with {query}; fallback commands (web search, Ask AI); favorites/alias/hotkey actions for every item; deeplinks `digup://`; Hyper Key |
| AI/ | Quick AI: Tab → streamed answer (DeepSeek, OpenAI-compatible; key in Keychain "DigUp Quick AI"/"deepseek"); paste/copy answer; follow-ups; regenerate; new chat; settings |
| Schedule/ | My Schedule (EventKit): today and upcoming events, join meeting links |
| Notes/ | Floating notes window, notes list mode, create/search/copy |
| Focus/ | Focus sessions: block apps (hide/quit on launch) and websites (close matching browser tabs), timer in the menu bar |
| Scripts/ | Script Commands from a folder, Raycast metadata (`@raycast.title`, `mode`), output shown/copied |

Emoji picker: skipped (not wanted).
