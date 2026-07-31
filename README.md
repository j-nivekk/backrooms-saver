# Backrooms

A liminal-space macOS screen saver: an endless, procedurally generated interior
toured by a camera that alternates between slow cinematic drifts and locked-off
CCTV angles (timestamp, CAM ##, blinking REC, glitch on the cuts).

The world drifts between three moods on a slow timeline (~8 minutes per lap):

| Phase | Look |
| --- | --- |
| **Level 0** | Mono-yellow wallpaper, damp carpet, humming fluorescent panels. |
| **Concrete halls** | Dark pillar forests, sparse strip lights, heavier fog. |
| **Poolrooms** | White tile, arched openings, tall ceilings — and water that rises out of the floor during the transition, complete with reflections and caustics. |

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

Useful flags: `--at N` pre-rolls the director N seconds; `--level 0|1|2` pins a
mood; `--shot drift|cctv` pins a shot type; `--seed N` picks a different maze.

## How it works

One fragment shader raymarches a signed distance field of an infinite room
grid (4 m cells). Each cell edge may own a wall, and each wall may own a
doorway, all decided by integer hashes of the cell coordinates — so the world
is deterministic, unbounded, and never stored. Low-frequency region hashes
modulate the wall probability, which is what produces the alternation between
tight mazes and vast open halls. Corner columns are always present: they read
as architecture, but they are really the conservative bound that stops rays
tunnelling past co-linear neighbour walls the 4-edge SDF evaluation cannot see.

The same hashes are mirrored bit-for-bit in Swift (`Director.swift`), which is
how the drift camera plans its path: a weighted random walk over passable cell
edges, threaded through the hashed doorway positions, densified into a
corner-rounded polyline and followed by arc length. CCTV shots probe for the
cell with the longest sightline and mount the camera near the ceiling.

Level identity is a weight vector, not a scene switch: albedos, light colour /
density / shape, fog, door width, arch radius, pillar girth, ceiling height and
the water plane all blend continuously, so one level melts into the next while
walking. Lighting is a 3×3 neighbourhood of emissive ceiling panels (some
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

- Mood palettes: the `kLightCol` / `kPanelProb` / `kAmb` / `kFogCol` /
  `kFogDen` tables and `surfaceAt` in `Backrooms.metal`.
- Geometry morphing (door width, arches, pillars): the `MapCfg` blends in
  `backrooms_fs`.
- Maze density: the region probabilities in `wallSDF` — and their **mirror** in
  `Director.swift` (`regionDense` / `wallExists` / `doorExists`), which must
  stay bit-identical or the camera will walk through walls.
- Shot pacing and level timeline: `startDrift` / `startCCTV` durations and
  `levelWeights` in `Director.swift`.
