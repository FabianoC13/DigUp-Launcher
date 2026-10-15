# DigUp's icon: "One space"

Four tiles, for what DigUp searches (text, pictures, sound, video), around an amber D with the find glowing in it.
Dark blue palette (navy, blues, a pale-blue D).

- `appicon.svg`: the app icon (1024 × 1024, macOS icon grid). `../AppIcon.icns` holds it at 64 px and up.
- `appicon-small.svg`: the same without the glyphs inside the tiles, which turn to noise when small. `../AppIcon.icns`
  holds it at 16 and 32 px.
- `AppIcon.icon`: the same design as layers for macOS 26 and later (an Icon Composer document: a #0B1530 fill, the
  tiles, the D). `build.sh` compiles it into `Assets.car` with `actool`; `Info.plist`'s `CFBundleIconName` points at
  it. Without it macOS 26 draws the `.icns` shrunk inside a gray square. Older macOS uses the `.icns`
  (`CFBundleIconFile`; untested there).
- `menubar.svg`: the menubar mark, a boxed D. The app draws it in code from the same geometry
  (`StatusIcon` in `Sources/DigUpApp/StatusMenu.swift`), with the indexing ring in place of the box.

To rebuild `AppIcon.icns` after editing a source: render both SVGs to an iconset (`icon_16x16.png` and
`icon_16x16@2x.png`/`icon_32x32.png` from `appicon-small.svg` at 16 and 32 px; the other eight sizes, 64 to 1024 px,
from `appicon.svg`) with a renderer that draws SVG blur filters (a browser or WebKit; macOS's own SVG renderer drops
the soft shadows), then `iconutil -c icns AppIcon.iconset -o ../AppIcon.icns`.

Colors: tile #0B1530; tiles #CFDDFB, #94B4F0, #4F7DD6, #1E3E8C; the D #E6EEFF → #8FB0FF with a #0B1530 outline; the
find #FFFFFF. Rendered with a WebKit snapshot (transparent background); qlmanage draws on white.
