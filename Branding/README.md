# Aikana logo assets

Mark: a sun over a horizon with shortening bars beneath it. Two colours only.

| Colour | Hex |
|---|---|
| Cream | `#F6EFE0` |
| Navy | `#20264A` |

Two options, each a full set: `cream-navy` (cream tile, navy mark) and `navy-cream` (navy tile, cream mark).

The mark is drawn in a 100 x 100 box and fills 84 x 70 of it, centred. On a tile it is scaled to 66% of the tile's width, which leaves 22% at the sides and 27% above and below, with the horizon bar on the tile's centre line.

## logo/

- `aikana-mark-navy.svg`, `aikana-mark-cream.svg`: the mark alone, transparent background.
- `aikana-icon-<option>.svg`: the mark on a rounded tile, full bleed.
- `aikana-lockup-<option>.svg`: tile and the name. The name is Sora SemiBold converted to outlines, so no font is needed. Sora is under the SIL Open Font License.
- `png/`: the same at 1024 px (lockups at 4x).

## macos/

- `AppIcon-<option>.appiconset`: all ten macOS sizes, drawn on the macOS 11 to 15 icon grid (824 px tile on a 1024 px canvas, with the standard soft shadow). To use one, rename it to `AppIcon.appiconset` and replace the empty one in `Aikana/Assets.xcassets`.
- `MenuBar/MenuBar-fine|attention|failed.imageset`: one-colour template glyphs at 18 pt for the three menu bar states. The app uses SF Symbols today; these are here if you want the mark in the menu bar instead.
- `source/`: the SVGs the app icons were rendered from.

## web/

Each of `web/cream-navy` and `web/navy-cream` holds:

- `favicon.ico` (16, 32, 48), `favicon.svg`
- `apple-touch-icon.png` (180, square, no transparency)
- `icon-192.png`, `icon-512.png`, `icon-maskable-512.png`, `site.webmanifest`
- `og-image.png` (1200 x 630) for link previews
- `head.html`: the tags to paste into the page head. Replace `YOUR-DOMAIN`.
- `source/`: the SVGs the PNGs were rendered from.

`web/adaptive/favicon.svg` is a single favicon that shows cream and navy in light mode and navy and cream in dark mode.
