# Backrooms.saver

A generative liminal-space screen saver for macOS. An endless interior that
nobody built and nobody is in, toured by a camera that alternates between slow
cinematic drifts and locked-off CCTV angles.

![The Lobby](docs/media/hero.jpg)

Nothing here is modelled. One fragment shader raymarches an infinite grid of
rooms whose walls and doorways are decided by hashing the cell coordinates, so
the world is unbounded, deterministic and never stored — it is regenerated from
its coordinates every frame. Walk for an hour and you will not repeat a room.

## Six levels

Every launch starts somewhere random, holds it a couple of minutes, then moves
on. These are all the **same floorplan and the same seed** — only the level
changes:

![The six levels](docs/media/levels.jpg)

| Level | Motif |
| --- | --- |
| **0 · The Lobby** | Mono-yellow wallpaper, damp carpet, the buzz of too many fluorescents. |
| **1 · Habitable Zone** | Concrete pillar forests, sparse strip lights, thick fog. |
| **37 · Poolrooms** | White tile, arched openings, tall ceilings, and water on the floor with reflections and caustics. |
| **4 · Abandoned Office** | Beige drywall, grey-blue carpet tile, cubicle partitions, cold 4000 K light. |
| **5 · Terror Hotel** | Deep red wallpaper over dark wood wainscot, patterned carpet, low ceilings. |
| **94 · Motion Lights** | Near-dark concrete where the lights wake as you approach and die behind you. |

Getting between them depends on how far apart they are. Levels that share a
palette **melt** into each other over half a minute — that is how the poolroom
water rises out of the floor. Everything else **noclips**: the picture tears,
cuts to black, and you are somewhere else entirely.

### Level 94 has a resident

Its lights track a walker rather than the camera. On a drift shot those are the
same thing. But the walk carries on during CCTV shots — so you sit on a fixed
camera and watch a pool of light move through rooms that you are not in.

![CCTV](docs/media/cctv.jpg)

### There is a horror dial

One line in [`Sources/Core/Director.swift`](Sources/Core/Director.swift):

```swift
public let kHorror: Float = 0.0
```

At `0.0`, the default, every horror term multiplies out and the piece stays
purely liminal — empty, calm, unsettling only through absence. Turn it up and it
scales continuously into entities, dead and buzzing tubes, deeper power sags,
building-wide blackouts, thicker fog, and glitches that fire mid-shot.

Dark levels get Smilers. Lit ones get something standing very still at the end
of a corridor. Both fade before you can reach them.

![Horror mode](docs/media/horror.jpg)

## Install

Requires macOS 13+ and the Xcode Command Line Tools. No Xcode project.

```bash
./build.sh install
```

Then pick **Backrooms** in System Settings → Screen Saver, under *Other*.
Deleting the bundle from `~/Library/Screen Savers` uninstalls it.

To watch one without installing:

```bash
./build/backdev window --seed 7
```

`backdev` also renders straight to PNG with no display attached, which is how
every image above was made. See [docs/internals.md](docs/internals.md) for its
flags and for how the thing actually works.

## Licence and credits

The code is [MIT](LICENSE).

Textures are from [ambientCG](https://ambientcg.com) (Wallpaper001A/001C and
Wood051), all **CC0 1.0** and bundled directly, so redistributing the built
saver is fine. Everything else (geometry, materials, lighting, grain) is
generated at runtime.
