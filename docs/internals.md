# Internals

Notes on how the saver is built, and the handful of invariants that are not
obvious from reading the code.

## The development harness

`backdev` runs the renderer outside the screen saver host. Render mode needs no
display, so the look can be tuned over SSH or in an agent session.

```bash
./build/backdev window --seed 7                       # a window
./build/backdev render out.png --at 120 --dump 30,300 # straight to PNG
./build/backdev timeline --minutes 30                 # the level schedule, headless
```

| Flag | Effect |
| --- | --- |
| `--at N` | Pre-roll the director N seconds before frame 1 |
| `--level 0..5` | Pin a level (0 Lobby, 1 Habitable, 2 Poolrooms, 3 Office, 4 Hotel, 5 MotionLights) |
| `--fever` | Pin a randomly generated fever level instead |
| `--shot drift\|cctv` | Pin a shot type |
| `--seed N` | Pick a different maze |
| `--horror 0..1` | Override the horror dial for one run |
| `--entity 0\|1` | Pin a Smiler or a figure on screen for tuning |
| `--dump f1,f2` | Which frames to write |

`timeline` prints which transitions melt and which noclip, and how long each
level is held, without having to sit and watch for half an hour.

## The world

One fragment shader raymarches a signed distance field of an infinite room grid
(4 m cells). Each cell edge may own a wall, and each wall may own a doorway, all
decided by integer hashes of the cell coordinates — so the world is
deterministic, unbounded, and never stored. Low-frequency region hashes modulate
the wall probability, which is what produces the alternation between tight mazes
and vast open halls.

**Corner columns are always present.** They read as architecture, but they are
really the conservative bound that stops rays tunnelling past co-linear
neighbour walls that this cell's 4-edge SDF evaluation cannot see. The 0.10 m
minimum radius is load-bearing in the literal sense.

On top of the base grid, more hashes add geometric variety: random-width pillars
(square or round), walls of varying thickness, leaning walls whose footprint
stays on the grid line, chest-high partition walls, soffit beams over open
edges, per-door width and height variation, and the Hotel's wainscot.

## The passability contract

The same hashes are mirrored **bit-for-bit** in Swift (`Director.swift`), which
is how the drift camera plans its path: a weighted random walk over passable
cell edges, threaded through the hashed doorway positions, densified into a
corner-rounded polyline and followed by arc length. CCTV shots probe for the
cell with the longest sightline and mount the camera near the ceiling.

This is the one thing that will break if you are careless with it. The hashes
exist in two places and must stay identical, or the camera walks through walls.

Everything added on top of the base grid is therefore deliberately
**passability-neutral**, so the Swift mirror never had to change:

- partitions only on doorless edges, which the camera never crosses
- soffits only over open edges, always keeping ≥ 2.3 m of clearance under them
  against a 1.55 m eye height
- leaning walls keep their footprint on the grid line
- door size variation stays inside the planner's margins

The general rule for anything new: **walls may only be removed, doors may only
be added.** Both directions leave an already-planned path valid.

Entities follow the same logic from the other side. They are not in `map()` at
all — they are a post-march overlay, depth-tested against the primary hit. So
they cost no march steps, can never block the camera, and cannot touch the
contract. They are placed down a sightline the planner has already proved open.

## Levels

Level identity is a pair of table indices plus a blend factor, not a scene
switch. Only two levels are ever live at once — the one being held and the one
being blended toward — so shading cost is constant no matter how many exist, and
holding one (the common case) evaluates a single material.

Levels pick a **material family** per surface (carpet, wallpaper, drywall,
concrete, tile, acoustic ceiling, plaster, wood) and supply the colour, so six
levels do not mean six sets of procedural material code. Albedos, light colour /
density / shape, fog, door width, arch radius, pillar girth, wainscot height,
ceiling height and the water plane all blend continuously.

To add a level: append a row to `kLevels[]` in `Backrooms.metal`, bump
`kLevelCount`, add entries to `kLevelCeilH` / `kLevelWaterY` / `kLevelDarkness`
in `Director.swift` (the camera needs the heights CPU-side), and decide its melt
pairs in `kMeltPairs`.

### Fever levels

A `Look` is what actually reaches the shader: a base level (geometry knobs,
panels, fog) plus *independent* material sources for floor, wall and ceiling,
plus scalars for light, fog, pillars, ceiling height and water. A canon level is
the identity case — every source equals the base, every scale is 1 — so it costs
exactly what it did before fever levels existed. `feverLook()` in
`Director.swift` is the whole generator.

### Props

There is a `propProb` column in `kLevels[]`, set to 0 on every level. It puts
stacked crates in the rooms and it works, but it is off for two reasons: it cost
about 15% of frame time, and crates band at close range because the AO and
soft-shadow rays sample further than a crate is thick. Desks and chairs were
built first and were worse for the same reason — a 3 cm chair back is far
thinner than the sampling radius. Scattered clothing survived instead, as pure
floor albedo, which costs nothing in the march.

## Rendering

Lighting is a 3×3 neighbourhood of emissive ceiling panels — some flickering,
some dead — plus SDF ambient occlusion. Deliberately shadowless, which is most
of the liminal flatness. Water does one reflected march bounce with Fresnel and
absorption.

The raymarch renders at reduced internal resolution into an rgba16f target, then
a two-level bloom chain and a composite pass (ACES, vignette, grain) upscale to
the drawable. The CCTV grade — pincushion lens, desaturation, scanlines, rolling
bar, 3×5-pixel-font overlay text — lives in the composite pass and is faded in
per shot; cuts between shots spike a glitch uniform that tears the image into
displaced bands.

**Panel-light falloff must reach zero within 1.5× the panel pitch horizontally**
(the 3×3 light window), or lights pop out of the window and leave visible seams
on the floor.

## Textures

Two bitmaps, both CC0 1.0 from ambientCG and so free to redistribute:

- `walltex.png` — the Level 0 wallpaper detail. Wallpaper001A (clean woodchip)
  and Wallpaper001C (damaged), channel-packed into one texture: R = clean
  relief, G = damaged relief, B = damage colour. The shader blends clean →
  damaged using the procedural grime masks, so the damage never repeats with the
  tile, and the relief drives the wall bump normals.
- `woodtex.png` — Wood051's displacement, the Hotel wainscot grain. 160 KB.

Either one missing falls back to the procedural version of that material, so a
stripped bundle still renders.

A carpet pack was tried alongside them and dropped: at every world scale it was
indistinguishable from the procedural fibre noise once mipmapped, for 700 KB of
bundle. Vertical surfaces near the camera repay a real texture; a floor seen at
a grazing angle under flat light does not.

## Build

No Xcode project. `build.sh` drives `swiftc` directly, links an `MH_BUNDLE`,
embeds the `.metal` source as a Swift string compiled by the Metal runtime at
launch, ad-hoc signs, and finishes by loading the bundle the way
`ScreenSaverEngine` does in both preview and full-screen modes. macOS 13+.

```bash
./build.sh          # build + smoke test
./build.sh install  # ...and copy to ~/Library/Screen Savers
./build.sh dist     # universal arm64 + x86_64 binary, zipped for sharing
```

Because the shader is compiled at launch, shader source length is startup
latency — which is part of why materials are shared between levels rather than
written out per level.

## Performance

Reference: 120 serialized frames at 3024×1890 in roughly 2 s.

Two traps worth knowing:

- A `smoothstep` with **variable** edges hides a divide. `wallSDF` runs on the
  order of 500 times per pixel, so one of those in there is measurable — see
  `cfg.wainscotInv`, which folds the reciprocal out.
- Any early-out in `map()` must be a *bound*, never a cutoff. Two bugs here came
  from forgetting that: an arch slab thicker than what `dQuick` bounds turned
  that early-out into an over-estimate and speckled the frame with tunnelling,
  and a "skip props above eye height" test let rays step straight into a crate.
  Swapping a cheap bound for the exact shape part way is also unsafe for a
  different reason: `calcAO` and `softShadow` sample out to ~1.1 m, so they
  straddle the jump and paint false occlusion bands.
- When benchmarking, **interleave the A and B runs and pin `--level`**. Running
  all of A then all of B lets thermal drift masquerade as a regression, and
  unforced runs may compare different levels entirely if the two builds draw
  from different level counts. That combination once produced a convincing but
  entirely fictitious +15%.

## Where things live

| Want to change | Look at |
| --- | --- |
| Everything about a level | one row of `kLevels[]` in `Backrooms.metal` |
| How a material looks | the family branches in `materialFor` |
| Horror | `kHorror`, and the terms it scales in `panelEmission`, `applyFog`, `shade`, `updateHorrorEvents`, `updateEntity` |
| Maze density | region probabilities in `wallSDF` **and** their mirror in `Director.swift` |
| Shot pacing, level schedule | `startDrift` / `startCCTV` / `updateLevels` / `holdDuration`, checked with `backdev timeline` |
