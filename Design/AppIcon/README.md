# App icon

The icon ships as an Icon Composer document, `GoogleChatSwiftUI/AppIcon.icon`.
Both it and the document's artwork are generated — `render.swift` is the source
of truth:

```sh
Design/AppIcon/make-icon.sh                 # shipping icon
Design/AppIcon/make-icon.sh fan even        # a different composition and palette
```

That rewrites the document, checks it compiles the way Xcode will, and refreshes
`preview.png` from what the system actually renders. Nothing but Xcode's
toolchain is needed. The project uses a synchronized group, so the document is
picked up from disk without touching the Xcode project.

## The design

Google Chat's own logo is Google's trademark, so this is a different mark: two
speech bubbles with their tails on opposite sides, reading as two parties
talking. The front one is opaque; the one behind it is translucent, so the two
sit at different depths.

Colours come from the icon this replaces, sampled off it directly: its bubble ran
`#7BCBFA` at the top through teal to `#0EBC5F`, over a `#00AF57` plate.

## The grid

Geometry is authored on Apple's 1024pt macOS icon grid — an 824×824 card centred
in the canvas. Those numbers are measured, not guessed: the alpha channel of
Messages.app's icon on macOS 26 gives exactly that, and fitting its corner
profile shows a degree-5 superellipse matches Apple's continuous corner to within
a pixel. In the `.icon` document the system draws the shape itself, so the card
outline is only used by the baked renderer.

## Notes on the .icon format

Three things below were established by experiment, since none of them are
obvious and getting any of them wrong fails quietly:

- **Groups are ordered front to back.** The exporter reverses its list. Get this
  wrong and the artwork hides behind whatever is nominally first.
- **The system scales layer artwork by 824/1024 about the centre** — the same
  inset as the grid — so the geometry carries a `position.scale` of 1024/824 to
  land where it was drawn.
- **A background fill takes exactly two colours.** A third makes `actool` throw
  `attempt to insert nil object`, and `orientation` is ignored at that level, so
  the four-stop weighting the baked renderer uses cannot be expressed. Faking it
  with a full-bleed gradient layer would cost the appearance variants, which are
  the reason to use the format, so the ramp here is a plain blue-to-green.

Also worth knowing: `glass` and `translucency` only drive the Clear appearance.
In the default one every layer is opaque, so the back bubble's translucency is
layer `opacity` instead.

What this buys over a flat icon: the system supplies the dome, the specular pass
and the shadows, and the compiled catalogue carries light, dark and tintable
variants rather than one baked image.

## The baked renderer

`render.swift` can still shade the icon itself and write a flat PNG ladder:

```sh
Design/AppIcon/make-icon.sh --baked         # -> Design/AppIcon/baked/
```

That path composites in a float buffer: a Euclidean distance transform of each
silhouette becomes a height field so the lit shoulder follows the shape, a
Lambert key light and Blinn-Phong hotspot light it, and the card bounces its own
colour back up into the undersides. Everything renders at 2048 and halves down,
so every size is an exact box filter. It is not what ships — it is there for
anywhere the layered document cannot go.

## Alternatives

`render.swift` carries two other compositions, `fan` (three bubbles receding —
truer to a group Space, but the back bubbles merge into one shoulder by 32pt) and
`hero` (a single bubble), plus the `even` and `teal` palettes.
