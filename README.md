# Backrooms

A liminal-space macOS screen saver: an endless, procedurally generated interior
toured by a camera that alternates between slow cinematic drifts and locked-off
CCTV angles (timestamp, CAM ##, blinking REC, glitch on the cuts).

The world moves between six levels on a randomised schedule: every launch starts
in a random one, holds it for 1.5–2.5 minutes, then moves on — no fixed order.

| # | Level | Look |
| --- | --- | --- |
| 0 | **Level 0, The Lobby** | Mono-yellow wallpaper, damp carpet, humming fluorescent panels. |
| 1 | **Level 1, Habitable Zone** | Dark concrete pillar forests, sparse strip lights, heavier fog. |
| 2 | **Level 37, Poolrooms** | White tile, arched openings, tall ceilings — and water that rises out of the floor during the transition, with reflections and caustics. |
| 3 | **Level 4, Abandoned Office** | Beige drywall with a chair-rail scuff, grey-blue carpet tile, cubicle partitions, cold 4000 K light. |
| 4 | **Level 5, Terror Hotel** | Deep red wallpaper over dark wood wainscot, patterned carpet, low ceilings, warm sconce-ish downlights. |
| 5 | **Level 94, Motion Lights** | Near-dark concrete where the fluorescents wake as you approach and die behind you. |

The numbers in the first column are what `--level` takes; the names are the
canon Backrooms levels each one depicts.

How it gets from one to the next depends on how far apart they are. Levels that
share a material family or palette **melt** — a slow 32-second crossfade, which
is how the poolroom water rises and how Habitable Zone's lights gradually decide
to start following you. Everything else **noclips**: the picture tears, cuts to
black for a moment, and comes back somewhere else entirely. Over half an hour
that runs at roughly eight melts to five noclips.

### Motion Lights, and who is switching them on

Level 94's lights track a walker, not the camera. During a drift shot those are
the same thing. During a CCTV shot the walk carries on without us — so what you
watch is a pool of light moving through rooms you are not standing in.

### The horror dial

One constant at the top of `Sources/Core/Director.swift`:

```swift
public let kHorror: Float = 0.0
```

At `0.0` — the default — every horror term multiplies out and the piece is
purely liminal: empty, calm, unsettling only through absence. Turn it up and it
scales continuously into: **entities** (emissive Smilers on dark levels, silent
standing figures on lit ones), twice as many dead tubes, far more of them
buzzing, deeper power sags, building-wide blackouts, thicker fog and glitch
spikes that fire mid-shot instead of only on cuts.

Entities are deliberately *not* part of the SDF. They are a post-march overlay,
depth-tested against the primary hit, so they cost no march steps, can never
block the camera, and cannot touch the passability contract below. They are
placed down a sightline the planner has already proved open, they last a few
seconds, and they fade as you close on them — you never reach one.

```bash
./build.sh            # build + smoke test
./build.sh install    # ...and copy to ~/Library/Screen Savers
```

Then pick **Backrooms** in System Settings → Screen Saver (under *Other*).
Deleting the bundle from `~/Library/Screen Savers` uninstalls it.

## Watching one without installing

    ./build/backdev window --seed 7

Or render frames straight to PNG (no display needed, works over SSH):

    ./build/backdev render shots/out.png --at 120 --dump 30,300

Useful flags: `--at N` pre-rolls the director N seconds; `--level 0..5` pins a
level; `--shot drift|cctv` pins a shot type; `--seed N` picks a different maze;
`--horror 0..1` overrides the dial for one run; `--entity 0|1` pins a Smiler or
a figure on screen for tuning.

    ./build/backdev timeline --minutes 30

prints the level schedule headlessly — which transitions melt, which noclip, and
how long each level is held — without having to sit and watch for half an hour.

## How it works

One fragment shader raymarches a signed distance field of an infinite room
grid (4 m cells). Each cell edge may own a wall, and each wall may own a
doorway, all decided by integer hashes of the cell coordinates — so the world
is deterministic, unbounded, and never stored. Low-frequency region hashes
modulate the wall probability, which is what produces the alternation between
tight mazes and vast open halls. Corner columns are always present: they read
as architecture, but they are really the conservative bound that stops rays
tunnelling past co-linear neighbour walls the 4-edge SDF evaluation cannot see.

On top of the base grid, more hashes add geometric variety without touching
passability: random-width pillars (square or round), walls of varying
thickness, leaning walls whose footprint stays on the grid line, chest-high
partition walls (only ever on doorless edges, which the camera never crosses),
soffit beams hanging over open edges (always ≥ 2.3 m of clearance), and
per-door width/height variation within the planner's margins.

The same hashes are mirrored bit-for-bit in Swift (`Director.swift`), which is
how the drift camera plans its path: a weighted random walk over passable cell
edges, threaded through the hashed doorway positions, densified into a
corner-rounded polyline and followed by arc length. CCTV shots probe for the
cell with the longest sightline and mount the camera near the ceiling.

Two bitmaps, both **CC0 1.0** and so free to redistribute. `walltex.png` is the
Level 0 wallpaper detail: ambientCG's Wallpaper001A (clean woodchip) and
Wallpaper001C (damaged), channel-packed into one texture (R = clean relief,
G = damaged relief, B = damage colour). The shader blends clean → damaged using
the procedural grime masks, so the damage never repeats with the 1 m tile, and
the relief drives the wall bump normals. `woodtex.png` (160 KB) is Wood051's
displacement, the Hotel wainscot grain. Either one missing falls back to the
procedural version of that material.

A carpet pack was tried alongside them and dropped: at every world scale it was
indistinguishable from the procedural fibre noise once mipmapped, for 700 KB of
bundle. Vertical surfaces near the camera repay a real texture; a floor seen at
a grazing angle under flat light does not.

Level identity is a pair of table indices plus a blend factor, not a scene
switch. Only two levels are ever live at once, so shading cost stays constant no
matter how many exist, and holding one — the common case — evaluates a single
material. Levels pick a *material family* (carpet, wallpaper, drywall, concrete,
tile, acoustic ceiling, plaster, wood) per surface and supply the colour, so six
levels do not mean six sets of procedural material code. Albedos, light colour /
density / shape, fog, door width, arch radius, pillar girth, wainscot height,
ceiling height and the water plane all blend continuously.

Lighting is a 3×3 neighbourhood of emissive ceiling panels (some
flickering, some dead) plus SDF ambient occlusion — deliberately shadowless,
which is most of the liminal flatness. Water does one reflected march bounce
with Fresnel and absorption.

The raymarch renders at half resolution into an rgba16f target, then a
two-level bloom chain and a composite pass (ACES, vignette, grain) upscale to
the drawable. The CCTV grade — pincushion lens, desaturation, scanlines,
rolling bar, 3×5-pixel-font overlay text — lives in the composite pass and is
faded in per shot; cuts between shots spike a glitch uniform that tears the
image into displaced bands.

## Build notes

Same scheme as `~/Dev/xp-pipes-saver`: no Xcode project, `build.sh` drives
`swiftc` directly, links an `MH_BUNDLE`, embeds the `.metal` source as a string
compiled by the Metal runtime at launch, ad-hoc signs, and finishes by loading
the bundle the way `ScreenSaverEngine` does in both preview and full-screen
modes. arm64, macOS 13+.

## Tuning

- Everything about a level: one row of `kLevels[]` in `Backrooms.metal`.
  Ceiling height and water depth also need their entry in `kLevelCeilH` /
  `kLevelWaterY` in `Director.swift`, which is where the camera reads them.
- Adding a level: append a `kLevels[]` row, bump `kLevelCount`, extend the
  three Swift tables, and decide its melt pairs in `kMeltPairs`.
- Material look: the family branches in `materialFor`.
- Horror: the `kHorror` dial, and the terms it scales in `panelEmission`,
  `applyFog`, `shade`, and `updateHorrorEvents` / `updateEntity`.
- Maze density: the region probabilities in `wallSDF` — and their **mirror** in
  `Director.swift` (`regionDense` / `wallExists` / `doorExists`), which must
  stay bit-identical or the camera will walk through walls.
- Shot pacing and the level schedule: `startDrift` / `startCCTV` durations and
  `updateLevels` / `holdDuration` in `Director.swift`. Check the result with
  `backdev timeline`.
