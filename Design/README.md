# Design assets (inventory)

| File | What it is |
|---|---|
| `mango.svg` | The app-icon artwork, verbatim as supplied by the owner (2026-09-01). Source: [UXWing](https://uxwing.com), licensed under the [UXWing license](https://uxwing.com/license/): free for commercial/personal projects incl. apps, modification allowed, attribution optional. Not permitted: reselling/redistributing the icon as a standalone icon product, or use as a company logo/trademark — bundling it as this app's icon is within the allowed uses. |
| `../MongoHubPlus/AppIcon.icon` | The live icon source — an Icon Composer document: `icon.json` (deep-green gradient fill + one artwork layer) and `Assets/mango.svg` (the artwork wrapped in a 1024pt canvas at 600pt wide, CSS classes inlined). |

## How the icon builds

A build phase runs `actool` on `AppIcon.icon`, producing:

- `Assets.car` — the layered Liquid Glass icon (macOS 26+ renders it
  full-bleed, no backdrop plate)
- `AppIcon.icns` — actool's auto-generated flattened fallback for
  macOS 14/15

Nothing is committed pre-rendered; edit `icon.json` or the layer SVG and
rebuild. If `mango.svg` (the original) changes, regenerate the layer SVG:
scale the artwork into a 1024×1024 canvas (see git history of
`Assets/mango.svg` for the transform).
