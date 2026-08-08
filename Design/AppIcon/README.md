# App icon

The icon is rendered, not drawn by hand. `render.swift` is the source of truth:

```sh
Design/AppIcon/make-icon.sh                 # shipping icon
Design/AppIcon/make-icon.sh fan even        # a different composition and palette
```

That rewrites every PNG in `GoogleChatSwiftUI/Assets.xcassets/AppIcon.appiconset`.
It needs nothing but Xcode's toolchain — shapes are rasterised with CoreGraphics
and the rest is composited in a float buffer, so gradients, glass, shading and
shadows are all under our own control rather than a filter's.

## The design

Google Chat's own logo is Google's trademark, so this is a different mark: two
speech bubbles with their tails on opposite sides, reading as two parties
talking. The front one is a solid lit object; the one behind it is frosted glass
that samples and blurs the card underneath, so the two sit at different depths.

Colours come from the icon this replaces, sampled off it directly: its bubble ran
`#7BCBFA` at the top through teal to `#0EBC5F`, over a `#00AF57` plate. The card
gradient keeps those hues and the same weighting, where blue holds only the top
sliver before turning green.

## The grid

An 824×824 card centred in a 1024×1024 canvas, leaving a 100pt margin for the
drop shadow. Those numbers are measured, not guessed — the alpha channel of
Messages.app's icon on macOS 26 gives exactly that, and fitting its corner
profile shows a degree-5 superellipse matches Apple's continuous corner to within
a pixel. `continuousRoundedRect` draws that curve, and with a radius of half the
side it degenerates to the card outline itself.

## What the material is doing

- A Euclidean distance transform of each silhouette becomes a height field, so
  the shoulder follows the shape rather than a canned gradient.
- Lambert key light from the upper left, a Blinn-Phong hotspot, and a rim light
  along the top edge where the surface turns away.
- The card bounces its own colour back up into the underside of each bubble.
  That one term is most of what stops white reading as flat paint.
- Everything is rendered at 2048 and halved down, so every size the catalogue
  wants is an exact box filter with no resampling artefacts.

## Alternatives

`render.swift` carries two other compositions, `fan` (three bubbles receding —
truer to a group Space, but the glass bubbles merge into one shoulder by 32pt)
and `hero` (a single bubble), plus the `even` and `teal` palettes.

## Liquid Glass

This is a flat icon with its card, shadow and highlights baked in, so it gets
none of the macOS 26 layered treatment — no system specular pass, and no dark,
clear or tinted appearance variants. Unlike a flat glyph it also does not
decompose into Icon Composer layers cleanly, because the back bubble's glass is
derived from the card behind it. Moving to a `.icon` document would mean
rebuilding the glass as a real layer effect rather than something we composite.
