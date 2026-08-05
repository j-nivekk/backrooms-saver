#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Shared layout. Every member is a float4/uint4 so Swift's SIMD types and MSL
// agree on offsets without packing guesswork.
// ---------------------------------------------------------------------------

struct RMUniforms {
    float4 eyeTime;     // xyz eye, w time
    float4 rightTanX;   // xyz right basis, w tan(fovX/2)
    float4 upTanY;      // xyz up basis, w tan(fovY/2)
    float4 fwdSeed;     // xyz forward basis, w world seed (as bits)
    float4 level;       // x blend A->B, y water height, zw unused
    float4 mode;        // x cctv, y global light, z ceiling height, w wall texture present
    float4 horror;      // x horror, y wood texture present, z ceiling drift amp, w its phase
    // Two "looks", one per live level. A look is a base level plus per-surface
    // material sources and a few scalar overrides, which is what lets the
    // Director synthesise fever variants that mix elements between levels.
    float4 lookA0;      // x base, y floorSrc, z wallSrc, w ceilSrc (level ids)
    float4 lookA1;      // x light scale, yzw light tint
    float4 lookA2;      // x fog scale, y pillar scale, zw unused
    float4 lookB0, lookB1, lookB2;
    float4 motion;      // xy motion-light centre (xz), zw its forward (xz)
    float4 entPos;      // xyz entity world position, w alpha (0 = none)
    float4 entCfg;      // x type (0 smiler, 1 figure), y card scale, z phase, w unused
};

struct CompositeParams {
    float4 params;      // x fade, y exposure, z grain seed, w bloom intensity
    float4 cctv;        // x cctv amount, y glitch, z time, w unused
    float4 res;         // xy output resolution
    uint4 textA;        // glyph codes 0..15, one byte each
    uint4 textB;        // glyph codes 16..31
};

struct PostParams {
    // Blur passes: xy = direction in texels, z = bright-pass threshold.
    float4 params;
};

// ---------------------------------------------------------------------------
// World hashing. MUST stay bit-identical with Director.swift: the CPU plans
// camera paths through the same maze these hashes describe.
// ---------------------------------------------------------------------------

constant float kCell = 4.0;
constant float kHalfT = 0.075;
constant float kPanelPitch = 2.0;

constant uint kSaltRegion  = 0xA341316Cu;
constant uint kSaltWall    = 0x8F1BBCDCu;
constant uint kSaltDoor    = 0xC2B2AE35u;
constant uint kSaltDoorPos = 0x165667B1u;
constant uint kSaltPanel   = 0xD3A2646Cu;
constant uint kSaltOrient  = 0x85EBCA6Bu;
constant uint kSaltFlick   = 0xFD7046C5u;
constant uint kSaltPillar  = 0xB55A4F09u;
constant uint kSaltTint    = 0x7C3A11B7u;
constant uint kSaltThick   = 0x1B873593u;
constant uint kSaltLean    = 0xCC9E2D51u;
constant uint kSaltHeight  = 0xE6546B64u;
constant uint kSaltSoffit  = 0x38495AB5u;
constant uint kSaltDoorSz  = 0x9B05688Cu;
constant uint kSaltPilSize = 0x27B70A85u;
constant uint kSaltPilShape = 0x2E1B2138u;
constant uint kSaltMotion   = 0x6A09E667u;   // GPU-only: motion-light radius jitter
constant uint kSaltProp     = 0xBB67AE85u;   // GPU-only: which corner owns a prop
constant uint kSaltCloth    = 0x3C6EF372u;   // GPU-only: floor clutter decals

static uint uhash(uint h)
{
    h ^= h >> 16; h *= 0x7feb352du;
    h ^= h >> 15; h *= 0x846ca68bu;
    h ^= h >> 16;
    return h;
}

static float hcell(int2 c, uint salt, uint seed)
{
    uint u = uint(c.x) * 0x9E3779B1u ^ uint(c.y) * 0x85EBCA77u ^ salt ^ seed;
    return float(uhash(u)) * (1.0 / 4294967296.0);
}

static float edgeHash(int2 e, int axis, uint base, uint seed)
{
    return hcell(e, base + uint(axis) * 0x27D4EB2Fu, seed);
}

// ---------------------------------------------------------------------------
// GPU-only texture noise (does not need to match the CPU)
// ---------------------------------------------------------------------------

static float vhash(float2 p)
{
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float vnoise(float2 p)
{
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = vhash(i), b = vhash(i + float2(1, 0));
    float c = vhash(i + float2(0, 1)), d = vhash(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float fbm(float2 p)
{
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; ++i) {
        v += a * vnoise(p);
        p = p * 2.13 + 17.7;
        a *= 0.5;
    }
    return v;
}

// ---------------------------------------------------------------------------
// The world SDF: an infinite grid of rooms. Each cell may own a wall (with a
// doorway) on each edge; corner plugs double as decorative columns AND as the
// conservative bound that stops rays tunnelling past co-linear neighbour walls
// that this cell's 4-edge evaluation cannot see.
// ---------------------------------------------------------------------------

struct MapCfg {
    float ceilAmp, ceilPhase;   // ceiling drift: amplitude in metres, world phase
    float ceilH, doorW, doorH, doorR, pillarR, roundness, skirt, wainscotH;
    // 1 / (0.35 * wainscotH - wainscotH), precomputed. wallSDF runs ~500 times
    // per pixel and a smoothstep with variable edges hides a divide in there,
    // which the old fixed 0.13/0.05 edges folded away. Cheap to keep folded.
    float wainscotInv;
    float leanAmt, partProb, soffitProb;
    float pillarProb, archProb, bowAmt, propProb;
    uint seed;
};

// ---------------------------------------------------------------------------
// Bevels.
//
// Nothing built is knife-sharp. Drywall gets a corner bead, concrete arrises
// are chamfered by the formwork, door jambs are eased, and every one of those
// catches a highlight the eye reads as evidence of construction. A few
// millimetres of radius is one of the cheapest realism cues there is - and it
// is the one thing an SDF gives away almost free, where a mesh pays real
// geometry for it.
//
// Rounding an intersection only ever REMOVES material, so openings get very
// slightly larger and dQuick stays a valid lower bound. Safe in both directions
// that matter here.
// ---------------------------------------------------------------------------
constant float kBevelWall = 0.012;   // where a wall segment ends
constant float kBevelDoor = 0.016;   // door and arch reveals
constant float kBevelCol  = 0.020;   // column arrises

static float roundIntersect(float a, float b, float r)
{
    float2 u = max(float2(r + a, r + b), 0.0);
    return min(-r, max(a, b)) + length(u);
}

/// Carve `hole` out of `a` with an eased arris rather than a sharp one.
static float roundSubtract(float a, float hole, float r)
{
    return roundIntersect(a, -hole, r);
}

static float boxSDF(float3 p, float3 b)
{
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// Props are all UNDER 0.95 m. That single rule is what makes them safe: the
// camera eye rides at 1.55 m, so it passes over anything it walks through and
// can never clip one. Tall furniture (shelves, coat racks) would need to be
// pinned to doorless walls the planner never crosses, so it is left out.
constant float kPropTop = 0.95;

// Crates only, and deliberately so. Desks and chairs were built here too, but
// their thin parts - a 7 cm table top, a 3 cm chair back - are thinner than the
// AO and soft-shadow sampling radius, so they came out banded and melted at
// close range. Chunky boxes have no feature small enough to hit that, and a
// stack of abandoned crates is the more backrooms prop regardless.
static float propSDF(float3 p, float h)
{
    float k = fract(h * 91.7);
    float w = 0.24 + 0.07 * fract(h * 53.1);
    float d = boxSDF(p - float3(0.0, w, 0.0), float3(w * 1.15, w, w * 1.05));
    if (k < 0.55) {          // a second crate shoved on top, off-centre
        float w2 = w * 0.78;
        d = min(d, boxSDF(p - float3(w * 0.35, w * 2.0 + w2, w * 0.2),
                          float3(w2 * 1.1, w2, w2)));
    }
    return d;
}

/// Where the prop owned by `corner` sits, in that corner's local frame, and how
/// far `p` is from it. Returns a cheap AABB bound first so the march only pays
/// for the real shape when it is close. `q` is p.xz relative to the corner.
static float propAt(float2 q, float3 p, int2 corner, MapCfg cfg, thread float &hOut)
{
    float hp = hcell(corner, kSaltProp, cfg.seed);
    hOut = hp;
    if (hp >= cfg.propProb) return 1e5;
    float2 sgn = float2(fract(hp * 13.1) < 0.5 ? -1.0 : 1.0,
                        fract(hp * 17.9) < 0.5 ? -1.0 : 1.0);
    float2 off = float2(0.75 + 0.75 * fract(hp * 31.7), 0.75 + 0.75 * fract(hp * 71.3));
    float3 lp = float3(q.x - off.x * sgn.x, p.y, q.y - off.y * sgn.y);
    // No AABB shortcut here. Swapping a cheap bound for the exact shape part way
    // makes the field jump, and calcAO/softShadow sample out to ~1.1 m - they
    // straddle that jump and band the prop with false occlusion. The exact
    // union is only a couple of boxes, so just pay for it.
    return propSDF(lp, hp);
}

// The ceiling is not one flat plane over the whole world - it drifts.
//
// Sines rather than a hashed per-region height, for two reasons. A stepped
// ceiling makes `top - p.y` an OVER-estimate near the step (the vertical face
// is nearer than the slab), which tunnels rays. And sines are trivially
// mirrored on the CPU, which the CCTV camera needs so it can mount itself under
// the ceiling that is actually above it. Periods are incommensurate, so the
// drift never visibly repeats; |grad| stays around 0.05 per metre of amplitude,
// so the field stays comfortably Lipschitz.
static float ceilDrift(float2 xz, float phase)
{
    return 0.40 * sin(xz.x * 0.083 + phase)
         + 0.34 * sin(xz.y * 0.061 + phase * 1.7)
         + 0.26 * sin((xz.x + xz.y) * 0.037 + phase * 2.3);
}

// The floor of 2.2 m is load-bearing, not taste. A low-ceilinged level under a
// fever's ceilScale can start near 2.1 m, and the drift then takes it under the
// 1.55 m eye - and the CCTV camera, which mounts 0.42 m below the ceiling, ends
// up on the floor. max() of two Lipschitz functions is still Lipschitz.
constant float kCeilMin = 2.20;

static float ceilAt(float2 xz, MapCfg cfg)
{
    return max(cfg.ceilH + cfg.ceilAmp * ceilDrift(xz, cfg.ceilPhase), kCeilMin);
}

// Geometry variety lives here, but NOTHING may change passability: the Swift
// path planner only knows "wall yes/no" and "door yes/no". So partitions only
// appear on doorless walls (never crossed), soffits only on open edges (and
// keep >= 2.3 m clearance under them), leans keep their footprint on the grid
// line, and door size variation stays within the planner's margins.
static float wallSDF(float3 p, int2 e, int axis, float lineC, float alongOrigin, MapCfg cfg)
{
    float oh = hcell(int2(floor(float2(e) / 6.0)), kSaltRegion, cfg.seed);
    float wallProb = oh < 0.55 ? 0.52 : 0.18;
    float doorProb = oh < 0.55 ? 0.78 : 0.90;

    float along = (axis == 0) ? p.z : p.x;
    float perp  = (axis == 0) ? p.x : p.z;
    float aL = along - alongOrigin;
    float aBox = abs(aL - kCell * 0.5) - kCell * 0.5;

    // Conservative bound over every variant this wall could be (max thickness,
    // max lean, bow, skirt). Far from the slab, skip all the detail hashes: a
    // lower bound is a valid sphere-tracing distance.
    float dQuick = max(abs(perp - lineC)
                       - (kHalfT * 1.8 + cfg.leanAmt + cfg.bowAmt + cfg.skirt), aBox);
    if (dQuick > 0.55) return dQuick;

    if (edgeHash(e, axis, kSaltWall, cfg.seed) >= wallProb) {
        // Open edge. It may carry an archway, or a soffit beam, or nothing.
        // One hash decides which, split into ranges, so this costs no extra
        // lookup in the march loop.
        float sh = edgeHash(e, axis, kSaltSoffit, cfg.seed);
        if (sh < cfg.archProb) {
            // Archway: a slab with a wide opening centred on the edge - which is
            // exactly where the planner crosses an open edge, so the crossing
            // keeps well over half a metre of clearance either side.
            //
            // Every dimension is drawn off the same edge hash. The hash already
            // varies per edge; what made early arches look stamped from one mould
            // was that only the *presence* was hashed and the shape was constant.
            float a1 = fract(sh * 61.7), a2 = fract(sh * 131.3), a3 = fract(sh * 277.1);
            // 1.8 is the ceiling here, not a taste choice: dQuick above bounds
            // wall thickness at kHalfT * 1.8, and anything thicker turns that
            // early-out into an OVER-estimate, which lets rays tunnel through
            // and speckles the whole frame.
            float d = roundIntersect(abs(perp - lineC) - kHalfT * mix(1.2, 1.8, a1),
                                     aBox, kBevelWall);
            float aw = mix(2.55, 3.45, a1);                       // springing width
            float ah = max(cfg.ceilH - mix(0.22, 0.95, a2), 2.4);  // crown height
            // r sweeps a shallow segmental head through to a full semicircle
            float r = min(aw * 0.5, ah * 0.45) * mix(0.32, 1.0, a3);
            // Lean the head over. The shear is zero at the floor, so the point
            // where the camera actually crosses is untouched and this is free.
            float tilt = (a2 - 0.5) * 0.6;
            float xr = aL - kCell * 0.5 - tilt * clamp(p.y / max(ah, 0.1), 0.0, 1.0);
            float2 q = abs(float2(xr, p.y - ah * 0.5 + 0.2))
                     - float2(aw * 0.5, ah * 0.5 + 0.2) + r;
            float hole = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
            return roundSubtract(d, hole, kBevelDoor);
        }
        if (sh >= cfg.archProb + cfg.soffitProb) return 1e5;
        float yBot = max(cfg.ceilH - mix(0.5, 0.85, fract(sh * 9.3)), 2.3);
        float d = roundIntersect(abs(perp - lineC) - kHalfT * 1.4, aBox, kBevelWall);
        return max(d, yBot - p.y);
    }

    // Per-wall thickness, skirting, and an occasional lean that grows with height
    float th = edgeHash(e, axis, kSaltThick, cfg.seed);
    // The skirt bulge doubles as the Hotel's wainscot: same 2 cm of thickness,
    // just carried up to `wainscotH`. dQuick already bounds it either way.
    float halfT = kHalfT * (0.8 + 1.0 * th);
    if (cfg.skirt > 0.0) {
        float u = clamp((p.y - cfg.wainscotH) * cfg.wainscotInv, 0.0, 1.0);
        halfT += cfg.skirt * (u * u * (3.0 - 2.0 * u));
    }
    float lh = edgeHash(e, axis, kSaltLean, cfg.seed);
    float lean = (lh < 0.25) ? (lh / 0.125 - 1.0) * cfg.leanAmt : 0.0;
    // A gentle bow across the span, pinned to zero at both ends so the wall
    // still meets its corners on the grid line. Peak sits mid-span, where the
    // doorway usually is, so it stays well inside the planner's door margin.
    float bow = cfg.bowAmt * (lh * 2.0 - 1.0) * sin(aL * (3.14159265 / kCell));
    float d = roundIntersect(abs(perp - lineC - lean * (p.y / cfg.ceilH) - bow) - halfT,
                            aBox, kBevelWall);

    if (edgeHash(e, axis, kSaltDoor, cfg.seed) < doorProb) {
        float frac = mix(0.28, 0.72, edgeHash(e, axis, kSaltDoorPos, cfg.seed));
        float ds = edgeHash(e, axis, kSaltDoorSz, cfg.seed);
        float dw = cfg.doorW * (0.85 + 0.35 * ds);
        float dh = cfg.doorH * (0.92 + 0.20 * fract(ds * 5.1));
        float r = min(cfg.doorR, dw * 0.45);
        float2 q = abs(float2(aL - frac * kCell, p.y - dh * 0.5 + 0.2))
                 - float2(dw * 0.5, dh * 0.5 + 0.2) + r;
        float hole = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        d = roundSubtract(d, hole, kBevelDoor);
    } else {
        // Doorless walls are sometimes only chest-high partitions
        float hh = edgeHash(e, axis, kSaltHeight, cfg.seed);
        if (hh < cfg.partProb) {
            d = max(d, p.y - mix(1.05, 1.4, fract(hh * 7.7)));
        }
    }
    return d;
}

static float map(float3 p, MapCfg cfg)
{
    // Only the ceiling plane itself needs the local height. Soffits, arches and
    // wall lean read the base height instead: they are all clamped to keep
    // headroom regardless, and putting ceilAt in wallSDF would pay for it on
    // every one of the ~500 wall evaluations a pixel makes.
    float d = min(p.y, ceilAt(p.xz, cfg) - p.y);

    float2 cf = floor(p.xz / kCell);
    int2 ci = int2(cf);
    float2 base = cf * kCell;

    d = min(d, wallSDF(p, ci,                     0, base.x,         base.y, cfg));
    d = min(d, wallSDF(p, int2(ci.x + 1, ci.y),   0, base.x + kCell, base.y, cfg));
    d = min(d, wallSDF(p, ci,                     1, base.y,         base.x, cfg));
    d = min(d, wallSDF(p, int2(ci.x, ci.y + 1),   1, base.y + kCell, base.x, cfg));

    for (int k = 0; k < 4; ++k) {
        int2 corner = ci + int2(k & 1, k >> 1);
        float2 q0 = p.xz - float2(corner) * kCell;
        float2 q = q0;
        float dSq = max(abs(q.x), abs(q.y));
        // 0.80 bounds the fattest column plus its flare and its lean.
        if (dSq - 0.80 > 0.4) { d = min(d, dSq - 0.80); continue; }
        float ph = hcell(corner, kSaltPillar, cfg.seed);
        // The 0.10 minimum is load-bearing: corner plugs are the conservative
        // bound that stops rays tunnelling past co-linear neighbour walls.
        float r = 0.10;
        float round = cfg.roundness;
        if (ph < cfg.pillarProb) {
            float sh = hcell(corner, kSaltPilSize, cfg.seed);
            r = clamp(cfg.pillarR * (0.45 + 1.35 * sh), 0.10, 0.60);
            float shp = hcell(corner, kSaltPilShape, cfg.seed);
            if (shp < 0.35) round = 1.0;
            // Column character: entasis toward the ceiling, a flared base and
            // capital, and occasionally one that has given up and leans.
            float hN = clamp(p.y / cfg.ceilH, 0.0, 1.0);
            r *= 1.0 - 0.20 * hN;
            r += r * 0.20 * (smoothstep(0.11, 0.0, hN) + smoothstep(0.86, 1.0, hN));
            if (shp > 0.82) q -= (0.14 * (hN - 0.5)) * float2(1.0, 0.65);
            dSq = max(abs(q.x), abs(q.y));
        }
        // Chamfered arrises on square columns, via a rounded box rather than
        // the raw Chebyshev distance.
        float2 qb = abs(q) - max(r - kBevelCol, 0.0);
        float boxd = length(max(qb, 0.0)) + min(max(qb.x, qb.y), 0.0) - kBevelCol;
        d = min(d, mix(boxd, length(q) - r, round));

        // Props hang off the same corners, so the existing 4-corner loop
        // already covers every prop within reach - no extra neighbourhood.
        // Note q0, not q: the pillar lean above shears q with height, and
        // feeding that to a prop would twist it into a corkscrew.
        //
        // There is deliberately no "skip if p.y is above the props" test here.
        // That is a cutoff rather than a bound: a ray coming down from eye
        // height would see no prop at all, take one huge step and land inside
        // one. propAt's AABB is conservative in y, so it does the job honestly.
        if (cfg.propProb > 0.0) {
            float hp;
            d = min(d, propAt(q0, p, corner, cfg, hp));
        }
    }
    return d;
}

static float march(float3 ro, float3 rd, float tmax, int steps, MapCfg cfg, thread bool &hit)
{
    hit = false;
    float t = 0.015;
    for (int i = 0; i < steps; ++i) {
        float d = map(ro + rd * t, cfg);
        if (d < max(0.0012, 0.0016 * t)) { hit = true; break; }
        t += d * 0.92;
        if (t > tmax) break;
    }
    return t;
}

static float3 calcNormal(float3 p, MapCfg cfg)
{
    const float e = 0.005;
    const float2 k = float2(1, -1);
    return normalize(k.xyy * map(p + k.xyy * e, cfg) +
                     k.yyx * map(p + k.yyx * e, cfg) +
                     k.yxy * map(p + k.yxy * e, cfg) +
                     k.xxx * map(p + k.xxx * e, cfg));
}

static float calcAO(float3 p, float3 n, MapCfg cfg)
{
    float ao = 0.0, w = 0.5;
    for (int i = 1; i <= 4; ++i) {
        float h = 0.07 * float(i * i);
        ao += w * clamp(map(p + n * h, cfg) / h, 0.0, 1.0);
        w *= 0.6;
    }
    return clamp(ao / 0.87, 0.0, 1.0);
}

// ---------------------------------------------------------------------------
// Levels.
//
// Only two levels are ever live at once - the one being held and the one being
// blended toward - so this takes a pair of ids plus a blend factor rather than
// an N-wide weight vector. Shading cost is then constant no matter how many
// levels exist, and holding a level (the common case) evaluates just one.
//
// Ids are append-only. The canon Backrooms level each one depicts is in the
// comment; Director.swift owns the names shown in the CCTV overlay.
//   0 -> Level 0    The Lobby         yellow wallpaper, damp carpet
//   1 -> Level 1    Habitable Zone    concrete, sparse strip lights
//   2 -> Level 37   Poolrooms         white tile, tall ceilings, water
//   3 -> Level 4    Abandoned Office  beige drywall, carpet tile, cubicles
//   4 -> Level 5    Terror Hotel      red paper, wainscot, low ceiling
//   5 -> Level 94   Motion Lights     dark concrete, lights ignite near you
// ---------------------------------------------------------------------------

// Material families. Levels pick a family per surface and supply the colour, so
// six levels do not mean six sets of procedural material code.
constant int kFamCarpet   = 0;
constant int kFamPaper    = 1;   // wallpaper: stripe + woodchip relief + grime
constant int kFamDrywall  = 2;   // flat painted board, scuffed
constant int kFamConcrete = 3;
constant int kFamTile     = 4;
constant int kFamAcoustic = 5;   // suspended ceiling grid
constant int kFamPlaster  = 6;
constant int kFamWood     = 7;   // wainscot / trim
constant int kFamPaint    = 8;   // skirting board

struct LevelDef {
    float3 lightCol;      // emissive colour with intensity folded in
    float  panelProb;
    float2 panelExt;
    float3 amb;
    float3 fogCol;
    float  fogDen;
    float3 floorCol, wallCol, ceilCol, trimCol;
    int    floorFam, wallFam, ceilFam, trimFam;
    float  floorParam;    // carpet/tile: grid pitch in metres (0 = none)
    float  floorMotif;    // patterned carpet strength (Hotel)
    float  wallParam;     // paper: stripe frequency | tile: grout pitch
    float  doorW, doorH, doorR;
    float  pillarR, roundness, skirt, wainscotH;
    float  leanAmt, partProb, soffitProb;
    float  motion;        // 1 = panels ignite by proximity to the eye
    float  darkness;      // 1 = entities read as Smilers, 0 = as figures
    float  pillarProb;    // how often a corner grows a real column
    float  archProb;      // how often an open edge becomes an archway.
                          // Keep this low: an arch should be a find, not
                          // the default, and every edge that is not one is
                          // free to be a soffit or an honest opening.
    float  bowAmt;        // gentle lateral bow across a wall span
    // Chance a corner owns a crate. OFF (0) on every level by default: the
    // crates render honestly at a distance but band at close range, because
    // the AO and soft-shadow rays sample further than the crate is thick, and
    // they cost ~15% of frame time. Raise per level to switch them back on.
    float  propProb;
};

constant LevelDef kLevels[6] = {
    {   // 0 - Level 0, The Lobby
        float3(1.00, 0.90, 0.66) * 7.5, 0.55, float2(0.60, 0.32),
        float3(0.150, 0.128, 0.072), float3(0.050, 0.042, 0.021), 0.075,
        float3(0.400, 0.335, 0.170), float3(0.630, 0.550, 0.290),
        float3(0.660, 0.650, 0.580), float3(0.300, 0.240, 0.120),
        kFamCarpet, kFamPaper, kFamAcoustic, kFamPaint,
        0.0, 0.0, 18.0,
        1.50, 2.25, 0.03,
        0.16, 0.00, 0.016, 0.130,
        0.06, 0.30, 0.25,
        0.0, 0.15,
        0.18, 0.03, 0.05, 0.0
    },
    {   // 1 - Level 1, Habitable Zone
        float3(0.70, 0.95, 0.78) * 9.5, 0.30, float2(0.68, 0.07),
        float3(0.085, 0.096, 0.089), float3(0.022, 0.028, 0.025), 0.078,
        float3(0.200, 0.210, 0.200), float3(0.330, 0.340, 0.330),
        float3(0.250, 0.260, 0.250), float3(0.330, 0.340, 0.330),
        kFamConcrete, kFamConcrete, kFamConcrete, kFamConcrete,
        0.0, 0.0, 0.0,
        2.30, 2.60, 0.06,
        0.45, 0.00, 0.000, 0.130,
        0.22, 0.35, 0.30,
        0.0, 0.55,
        0.34, 0.05, 0.10, 0.0
    },
    {   // 2 - Level 37, Poolrooms
        float3(0.85, 0.93, 1.05) * 8.0, 0.42, float2(0.42, 0.42),
        float3(0.095, 0.110, 0.125), float3(0.052, 0.062, 0.072), 0.042,
        float3(0.660, 0.720, 0.760), float3(0.780, 0.820, 0.850),
        float3(0.740, 0.770, 0.800), float3(0.740, 0.770, 0.800),
        kFamTile, kFamTile, kFamTile, kFamTile,
        0.50, 0.0, 0.30,
        1.90, 3.10, 0.80,
        0.40, 1.00, 0.000, 0.130,
        0.05, 0.15, 0.15,
        0.0, 0.10,
        0.22, 0.15, 0.04, 0.0
    },
    {   // 3 - Level 4, Abandoned Office
        float3(0.92, 0.96, 1.00) * 6.0, 0.62, float2(0.60, 0.32),
        float3(0.100, 0.104, 0.112), float3(0.032, 0.035, 0.040), 0.052,
        float3(0.240, 0.260, 0.300), float3(0.600, 0.585, 0.520),
        float3(0.660, 0.660, 0.640), float3(0.470, 0.460, 0.420),
        kFamCarpet, kFamDrywall, kFamAcoustic, kFamPaint,
        0.50, 0.0, 0.35,
        1.85, 2.35, 0.02,
        0.20, 0.00, 0.012, 0.100,
        0.04, 0.62, 0.22,
        0.0, 0.20,
        0.15, 0.02, 0.03, 0.0
    },
    {   // 4 - Level 5, Terror Hotel
        float3(1.00, 0.84, 0.58) * 6.5, 0.34, float2(0.16, 0.16),
        float3(0.100, 0.066, 0.044), float3(0.034, 0.020, 0.014), 0.062,
        float3(0.300, 0.062, 0.058), float3(0.420, 0.150, 0.125),
        float3(0.480, 0.435, 0.375), float3(0.150, 0.088, 0.052),
        kFamCarpet, kFamPaper, kFamPlaster, kFamWood,
        0.0, 1.0, 26.0,
        1.35, 2.15, 0.35,
        0.18, 0.35, 0.020, 0.950,
        0.03, 0.20, 0.18,
        0.0, 0.45,
        0.20, 0.12, 0.06, 0.0
    },
    {   // 5 - Level 94, Motion Lights
        float3(0.88, 0.94, 1.00) * 11.0, 0.70, float2(0.55, 0.30),
        float3(0.032, 0.034, 0.040), float3(0.012, 0.014, 0.018), 0.090,
        float3(0.170, 0.175, 0.180), float3(0.300, 0.305, 0.310),
        float3(0.220, 0.225, 0.230), float3(0.300, 0.305, 0.310),
        kFamConcrete, kFamConcrete, kFamConcrete, kFamConcrete,
        0.0, 0.0, 0.0,
        2.10, 2.50, 0.04,
        0.30, 0.00, 0.000, 0.130,
        0.10, 0.25, 0.28,
        1.0, 1.00,
        0.30, 0.04, 0.08, 0.0
    },
};

// Everything the shader needs about "where we are between two levels".
// Indices, not copies: a LevelMix is passed through every shading function, and
// two LevelDefs by value would be ~240 bytes of struct copied down the whole
// call graph. The level pair is uniform across the draw, so reading kLevels[]
// from the constant address space is a scalar load instead.
// A look is "which level am I, and which bits of other levels am I wearing".
// For a canon level every source equals `base` and every scale is 1, so the
// canon path costs exactly what it did before fever levels existed.
struct Look {
    int base;                          // geometry knobs, panels, fog come from here
    int floorSrc, wallSrc, ceilSrc;    // materials may come from anywhere
    float lightScale, fogScale, pillarScale;
    float3 lightTint;
};

static Look unpackLook(float4 a, float4 b, float4 c)
{
    Look L;
    L.base     = clamp(int(a.x), 0, 5);
    L.floorSrc = clamp(int(a.y), 0, 5);
    L.wallSrc  = clamp(int(a.z), 0, 5);
    L.ceilSrc  = clamp(int(a.w), 0, 5);
    L.lightScale = b.x;
    L.lightTint  = b.yzw;
    L.fogScale   = c.x;
    L.pillarScale = c.y;
    return L;
}

/// The material source for one surface kind: 0 floor, 1 ceiling, 2 wall.
static int srcFor(thread const Look &k, int kind)
{
    return (kind == 0) ? k.floorSrc : ((kind == 1) ? k.ceilSrc : k.wallSrc);
}

struct LevelMix {
    Look a, b;
    float t;              // 0 = pure a, 1 = pure b
    float horror;
};

static float3 mixCol(thread const LevelMix &L, float3 ca, float3 cb) { return mix(ca, cb, L.t); }
static float  mixF(thread const LevelMix &L, float va, float vb) { return mix(va, vb, L.t); }

struct Surface {
    float3 albedo;
    float roughness;   // perceptual: 0 mirror, 1 fully diffuse
    float metallic;
    float bumpAmt;
};

// ---------------------------------------------------------------------------
// Metallic/roughness BRDF. GGX distribution, height-correlated Smith
// visibility, Schlick Fresnel.
//
// The diffuse term deliberately keeps a wrap (dot * 0.62 + 0.38) rather than a
// true clamped N.L. It is not physical - it is a stand-in for the interreflected
// light a real room is full of, and it is most of why this place reads as
// flatly, evenly lit rather than dramatic. Losing it would look more "correct"
// and less like the Backrooms. Replace it only when there is real indirect
// light to replace it with.
// ---------------------------------------------------------------------------

static float D_GGX(float ndh, float a)
{
    float a2 = a * a;
    float d = ndh * ndh * (a2 - 1.0) + 1.0;
    return a2 / max(3.14159265 * d * d, 1e-7);
}

static float V_SmithGGX(float ndv, float ndl, float a)
{
    float a2 = a * a;
    float gv = ndl * sqrt(ndv * ndv * (1.0 - a2) + a2);
    float gl = ndv * sqrt(ndl * ndl * (1.0 - a2) + a2);
    return 0.5 / max(gv + gl, 1e-5);   // includes the 1/(4 ndl ndv)
}

static float3 F_Schlick(float3 f0, float vdh)
{
    float f = pow(clamp(1.0 - vdh, 0.0, 1.0), 5.0);
    return f0 + (1.0 - f0) * f;
}

/// Karis representative point: the ceiling panels are rectangles, not points.
/// Intersect the reflection ray with the panel plane, clamp into the rectangle,
/// and shade toward that instead of the centre. This is what turns a small hot
/// dot on glazed tile into the broad soft streak a real troffer casts.
static float3 rectRepresentativePoint(float3 p, float3 R, float3 centre, float2 ext)
{
    float denom = R.y;
    if (denom > 1e-4) {                       // ray heading up toward the ceiling
        float tPl = (centre.y - p.y) / denom;
        if (tPl > 0.0) {
            float3 hit = p + R * tPl;
            float2 off = clamp(hit.xz - centre.xz, -ext, ext);
            return float3(centre.x + off.x, centre.y, centre.z + off.y);
        }
    }
    return centre;
}

// Channel-packed CC0 wallpaper detail (ambientCG Wallpaper001A + 001C):
// R = clean woodchip relief, G = damaged relief, B = damage colour luminance.
// Where the damage sits is decided procedurally, so it never tiles.
constexpr sampler wallSampler(filter::linear, mip_filter::linear, address::repeat);
constant float kWallTexScale = 0.91;   // ~1.1 m per tile

// Wood grain for the Hotel wainscot (ambientCG Wood051 displacement, CC0).
// A carpet pack was tried alongside it and dropped: at every world scale it was
// indistinguishable from the procedural fibre noise once mipmapped, so it was
// 700 KB of bundle for nothing. Vertical surfaces near the camera repay a real
// texture; the floor, seen at a grazing angle under flat light, does not.
constant float kWoodTexScale = 0.85;   // wainscot, ~1.2 m per tile

// One level's material at a point. kind: 0 floor, 1 ceiling, 2 wall.
static Surface materialFor(int li, int kind, float3 p, float3 n, float along,
                           float waterY, texture2d<float> wallTex, float hasTex,
                           texture2d<float> woodTex, float hasWood, MapCfg cfg)
{
    constant LevelDef &L = kLevels[li];
    Surface s;
    s.roughness = 0.90;
    s.metallic = 0.0;
    s.bumpAmt = 0.0;

    int fam = (kind == 0) ? L.floorFam : ((kind == 1) ? L.ceilFam : L.wallFam);
    float3 base = (kind == 0) ? L.floorCol : ((kind == 1) ? L.ceilCol : L.wallCol);

    // Wall trim: skirting board, or the Hotel's full wainscot.
    if (kind == 2 && L.skirt > 0.0001 && p.y < L.wainscotH * 0.88) {
        fam = L.trimFam;
        base = L.trimCol;
    }

    float3 a = base;

    if (fam == kFamCarpet) {
        // Coarse mottling, fibre structure, big damp blotches. The mid-scale
        // fbm and the blotches stay procedural so nothing repeats with the tile.
        float blotch = smoothstep(0.60, 0.88, fbm(p.xz * 0.33 + 7.3));
        a = base * (0.85 + 0.30 * fbm(p.xz * 6.0));
        a *= 0.92 + 0.16 * vnoise(p.xz * 34.0);
        a *= 1.0 - 0.22 * blotch;
        if (L.floorParam > 0.001) {
            // Carpet tiles: seams plus a slight per-tile dye-lot drift
            float2 g = abs(fract(p.xz / L.floorParam) - 0.5) * L.floorParam;
            a *= 1.0 - 0.11 * smoothstep(0.030, 0.010, min(g.x, g.y));
            a *= 0.95 + 0.09 * vhash(floor(p.xz / L.floorParam));
        }
        if (L.floorMotif > 0.001) {
            // Hotel figure: two lattices at 45 degrees make a busy damask-ish
            // repeat. Keep it small and low-contrast - a bold motif at carpet
            // scale reads as lava, not as a pattern.
            float2 m = p.xz * 3.2;
            float2 r = float2(m.x + m.y, m.x - m.y) * 0.70711;
            float fig = sin(m.x * 3.14159) * sin(m.y * 3.14159)
                      + 0.7 * sin(r.x * 6.28318) * sin(r.y * 6.28318);
            float motif = smoothstep(0.34, 0.70, fig * 0.5 + 0.5);
            a = mix(a, a * float3(1.50, 1.24, 0.80), motif * L.floorMotif * 0.38);
        }
        s.bumpAmt = 0.06;
    } else if (fam == kFamPaper) {
        float stripe = smoothstep(0.30, 0.70, 0.5 + 0.5 * sin(along * L.wallParam));
        a = mix(base, base * float3(0.865, 0.845, 0.810), stripe);
        float grimeLo = smoothstep(0.55, 0.0, p.y);
        float grimeHi = smoothstep(cfg.ceilH - 0.45, cfg.ceilH, p.y);
        float sf = fbm(float2(along * 0.45, p.y * 0.45));
        float stain = smoothstep(0.55, 0.85, sf);
        a *= 1.0 - 0.32 * grimeLo - 0.18 * grimeHi - 0.28 * stain;
        if (hasTex > 0.5) {
            // Woodchip relief modulates the paint; where the procedural damage
            // mask bites, blend to the torn variant and let the backing show.
            float4 tx = wallTex.sample(wallSampler, float2(along, p.y) * kWallTexScale);
            float dmg = clamp(smoothstep(0.42, 0.78, sf) + 0.30 * grimeLo, 0.0, 1.0);
            float relief = mix(tx.r, tx.g, dmg);
            a *= 0.80 + 0.45 * relief;
            float torn = dmg * smoothstep(0.88, 0.72, tx.b);
            a = mix(a, float3(0.50, 0.455, 0.38) * (0.45 + 0.85 * tx.b), torn);
        } else {
            a *= 0.96 + 0.07 * vnoise(float2(along, p.y) * 48.0);
        }
        float scuff = smoothstep(0.60, 0.88, fbm(float2(along * 2.5, p.y * 0.7) + 4.2))
                    * smoothstep(1.1, 0.35, p.y);
        a *= 1.0 - 0.20 * scuff;
        a *= 0.93 + 0.14 * hcell(int2(floor(floor(p.xz / kCell) / 6.0)), kSaltTint, cfg.seed);
        s.roughness = 0.86;
        s.bumpAmt = (hasTex > 0.5) ? 0.03 : 0.10;
    } else if (fam == kFamDrywall) {
        a = base * (0.94 + 0.10 * fbm(float2(along * 0.6, p.y * 0.6)));
        a *= 1.0 - 0.16 * smoothstep(0.55, 0.0, p.y);
        // Chair rail: the band where trolleys and chair backs have hit the board
        float rail = smoothstep(0.10, 0.0, fabs(p.y - 0.76));
        a *= 1.0 - L.wallParam * 0.35 * rail * (0.4 + 0.6 * fbm(float2(along * 4.0, 1.7)));
        float scuff = smoothstep(0.62, 0.90, fbm(float2(along * 2.2, p.y * 0.8) + 2.3))
                    * smoothstep(1.3, 0.3, p.y);
        a *= 1.0 - L.wallParam * 0.45 * scuff;
        s.roughness = 0.90;
        s.bumpAmt = 0.06;
    } else if (fam == kFamConcrete) {
        if (kind == 0) {
            a = base * (0.85 + 0.25 * fbm(p.xz * 1.3));
            s.roughness = 0.72; s.bumpAmt = 0.28;
        } else if (kind == 1) {
            a = base * (0.9 + 0.2 * fbm(p.xz * 0.9));
            s.roughness = 0.85; s.bumpAmt = 0.12;
        } else {
            a = base * (0.80 + 0.30 * fbm(float2(along, p.y) * 1.7));
            a *= 1.0 - 0.35 * smoothstep(1.2, 0.0, p.y) * fbm(float2(along * 0.8, 3.1));
            s.roughness = 0.82; s.bumpAmt = 0.50;
        }
    } else if (fam == kFamTile) {
        float2 tc = (kind == 2) ? float2(along, p.y) : p.xz;
        float pitch = (kind == 2) ? L.wallParam : L.floorParam;
        float2 g = abs(fract(tc / pitch) - 0.5) * pitch;
        float grout = smoothstep(0.021, 0.012, min(g.x, g.y));
        float tint = 0.92 + 0.16 * vhash(floor(tc / pitch));
        a = mix(base * tint, float3(0.42, 0.45, 0.47), grout);
        if (kind == 2 && waterY > -0.1) {   // old waterline stain on the tile
            a *= 1.0 - 0.28 * exp(-fabs(p.y - (waterY + 0.05)) * 22.0);
        }
        // glazed ceramic is genuinely smooth - this is the biggest single
        // material change, and what finally makes the poolrooms read as tile
        s.roughness = (kind == 0) ? 0.18 : 0.26;
        s.bumpAmt = (kind == 2) ? 0.05 : 0.02;
    } else if (fam == kFamAcoustic) {
        a = base * (0.95 + 0.09 * vhash(floor(p.xz)));
        a *= 1.0 - 0.10 * smoothstep(0.78, 0.92, vnoise(p.xz * 34.0));
        float2 g = abs(fract(p.xz) - 0.5);
        a *= 1.0 - 0.22 * smoothstep(0.47, 0.5, max(g.x, g.y));
    } else if (fam == kFamPlaster) {
        a = base * (0.95 + 0.09 * fbm(p.xz * 1.1));
        s.roughness = 0.88;
        s.bumpAmt = 0.05;
    } else if (fam == kFamWood) {
        // Real grain if we have it, stretched fbm if not, plus panel divisions
        if (hasWood > 0.5) {
            float gr = woodTex.sample(wallSampler, float2(along, p.y) * kWoodTexScale).r;
            a = base * (0.62 + 0.78 * gr);
        } else {
            a = base * (0.78 + 0.44 * fbm(float2(along * 1.4, p.y * 22.0)));
        }
        float seam = smoothstep(0.035, 0.012, fabs(fract(along / 0.80) - 0.5) * 0.80);
        a *= 1.0 - 0.35 * seam;
        s.roughness = 0.42;
        s.bumpAmt = 0.10;
    } else {   // kFamPaint - skirting board
        a = base * (0.9 + 0.2 * vnoise(float2(along * 30.0, p.y * 60.0)));
    }

    if (kind == 0) {
        // Scattered clothing and debris. Pure albedo - no geometry, so this is
        // free in the march and costs one test per shaded floor pixel.
        float2 cc = floor(p.xz / 2.0);
        float ch = vhash(cc + 0.5);
        if (ch < 0.20) {
            float2 cpos = (cc + float2(0.25 + 0.5 * fract(ch * 37.0),
                                       0.25 + 0.5 * fract(ch * 71.0))) * 2.0;
            float2 dv = p.xz - cpos;
            float ang = ch * 6.2831;
            float ca = cos(ang), sa = sin(ang);
            float2 rv = float2(dv.x * ca - dv.y * sa, dv.x * sa + dv.y * ca);
            float m = smoothstep(0.30, 0.13, length(rv * float2(1.0, 2.3)))
                    * (0.55 + 0.45 * fbm(p.xz * 9.0));
            float3 cloth = float3(0.20 + 0.30 * fract(ch * 13.0),
                                  0.19 + 0.22 * fract(ch * 29.0),
                                  0.22 + 0.26 * fract(ch * 53.0));
            a = mix(a, cloth, clamp(m, 0.0, 1.0) * 0.85);
        }
    }

    s.albedo = a;
    return s;
}

// Blend the two live levels. When holding (t == 0) only one is evaluated.
static Surface surfaceAt(float3 p, float3 n, int kind, thread const LevelMix &L, float waterY,
                         texture2d<float> wallTex, float hasTex,
                         texture2d<float> woodTex, float hasWood, MapCfg cfg)
{
    float along = (abs(n.x) > 0.5) ? p.z : p.x;
    Surface s = materialFor(srcFor(L.a, kind), kind, p, n, along, waterY,
                           wallTex, hasTex, woodTex, hasWood, cfg);
    if (L.t > 0.004) {
        Surface o = materialFor(srcFor(L.b, kind), kind, p, n, along, waterY,
                               wallTex, hasTex, woodTex, hasWood, cfg);
        s.albedo = mix(s.albedo, o.albedo, L.t);
        s.roughness = mix(s.roughness, o.roughness, L.t);
        s.metallic = mix(s.metallic, o.metallic, L.t);
        s.bumpAmt = mix(s.bumpAmt, o.bumpAmt, L.t);
    }
    return s;
}

// Everything panelEmission needs, resolved once per fragment: the light loop
// calls it ten times per shaded pixel, so the level lookups and the horror
// thresholds are hoisted out rather than recomputed on every call.
struct PanelCfg {
    float3 lightA, lightB;
    float probA, probB;
    float2 extA, extB;
    float t, motion;
    float deadT, buzzT, badT;
};

static PanelCfg resolvePanels(thread const LevelMix &L)
{
    constant LevelDef &A = kLevels[L.a.base];
    constant LevelDef &B = kLevels[L.b.base];
    PanelCfg P;
    P.lightA = A.lightCol * L.a.lightScale * L.a.lightTint;
    P.lightB = B.lightCol * L.b.lightScale * L.b.lightTint;
    P.probA = A.panelProb;  P.probB = B.panelProb;
    P.extA = A.panelExt;    P.extB = B.panelExt;
    P.t = L.t;
    P.motion = mix(A.motion, B.motion, L.t);
    // Horror widens both tails: more dead tubes, more of them buzzing.
    P.deadT = mix(0.05, 0.16, L.horror);
    P.buzzT = mix(0.93, 0.75, L.horror);
    P.badT  = mix(0.72, 0.35, L.horror);
    return P;
}

static float3 panelEmission(int2 pc, thread const PanelCfg &P, float t, float globalLight,
                            uint seed, float2 mCen, float2 mFwd, thread float2 &ext)
{
    float h = hcell(pc, kSaltPanel, seed);
    float3 c = float3(0);
    if (h < P.probA) c += (1.0 - P.t) * P.lightA;
    if (h < P.probB) c += P.t * P.lightB;

    ext = mix(P.extA, P.extB, P.t);
    if (hcell(pc, kSaltOrient, seed) < 0.5) ext = ext.yx;

    if (dot(c, c) < 1e-6) return float3(0);

    float fh = hcell(pc, kSaltFlick, seed);
    float b = 1.0;
    if (fh < P.deadT) {
        b = 0.04;                                   // the dead one down the hall
    } else if (fh > P.buzzT) {
        // Episodic trouble: steady most of the time, then a stretch of
        // buzzing every half minute or so.
        float window = floor(t / 11.0 + fh * 53.0);
        float bad = step(P.badT, vhash(float2(window, fh * 191.0)));
        float n = step(0.45, vhash(float2(floor(t * 5.5), fh * 371.0)));
        b = mix(1.0, 0.5 + 0.5 * n, bad * 0.9);
    }

    float motion = P.motion;
    if (motion > 0.001) {
        // Level 94: panels wake as the walker approaches. The ramp is centred
        // behind them, so lights ignite ahead and linger a beat after they pass
        // - stateless, but it reads exactly like switching lag.
        float2 lc = (float2(pc) + 0.5) * kPanelPitch;
        float d = distance(lc, mCen - mFwd * 2.2);
        float r = 7.0 + 2.6 * hcell(pc, kSaltMotion, seed);   // ragged, not a clean circle
        float on = smoothstep(r, r - 2.4, d);
        // Fluorescent strike: a stutter or two right at the threshold
        float settled = smoothstep(r - 0.6, r - 2.0, d);
        float strike = step(0.42, vhash(float2(floor(t * 9.0), h * 613.0)));
        on *= mix(strike, 1.0, settled);
        // A few tubes never went out. Without them the rooms nobody is walking
        // through are pure black, and a CCTV shot has nothing in it at all.
        float keep = (hcell(pc, kSaltMotion, seed ^ 0x5BD1u) < 0.22) ? 0.16 : 0.015;
        b *= mix(1.0, max(on, keep), motion);
    }
    return c * b * globalLight;
}

static float softShadow(float3 p, float3 L, float dist, MapCfg cfg)
{
    float res = 1.0, t = 0.06;
    for (int i = 0; i < 8; ++i) {
        if (t > dist - 0.15) break;
        float d = map(p + L * t, cfg);
        res = min(res, 8.0 * d / t);
        t += clamp(d, 0.06, 0.55);
    }
    return clamp(res, 0.0, 1.0);
}

static float3 shade(float3 p, float3 n, float3 rd, thread const LevelMix &L, float t, float globalLight,
                    float waterY, bool primary, texture2d<float> wallTex, float hasTex,
                    texture2d<float> woodTex, float hasWood,
                    float2 mCen, float2 mFwd, MapCfg cfg)
{
    constant LevelDef &A = kLevels[L.a.base];
    constant LevelDef &B = kLevels[L.b.base];
    PanelCfg P = resolvePanels(L);
    int kind = 2;
    if (n.y > 0.6 && p.y < 1.0) kind = 0;
    else if (n.y < -0.6) kind = 1;

    // Direct hit on a lit ceiling panel: pure emission (bloom does the rest).
    if (kind == 1 && p.y > ceilAt(p.xz, cfg) - 0.05) {
        int2 pc = int2(floor(p.xz / kPanelPitch));
        float2 ext;
        float3 em = panelEmission(pc, P, t, globalLight, cfg.seed, mCen, mFwd, ext);
        float2 lc = (float2(pc) + 0.5) * kPanelPitch;
        float2 dxz = abs(p.xz - lc);
        if (dot(em, em) > 1e-6 && dxz.x < ext.x && dxz.y < ext.y) {
            float2 rim = ext - dxz;
            float frame = smoothstep(0.0, 0.045, min(rim.x, rim.y));
            float2 diff = abs(p.xz - lc) / max(ext, 0.001);
            float fall = 1.0 - 0.25 * max(diff.x, diff.y);
            return em * frame * fall + float3(0.02) * (1.0 - frame);
        }
    }

    Surface s = surfaceAt(p, n, kind, L, waterY, wallTex, hasTex, woodTex, hasWood, cfg);

    // Props wear their own material rather than inheriting the floor's. Four
    // corner tests, but only for points low enough to be a prop, and only once
    // per shaded pixel rather than once per march step.
    if (cfg.propProb > 0.0 && p.y < kPropTop + 0.06) {
        int2 ci = int2(floor(p.xz / kCell));
        for (int k = 0; k < 4; ++k) {
            int2 corner = ci + int2(k & 1, k >> 1);
            float hp;
            float dp = propAt(p.xz - float2(corner) * kCell, p, corner, cfg, hp);
            if (dp < 0.025) {
                float kind2 = fract(hp * 91.7);
                float3 pc = (kind2 < 0.34) ? float3(0.34, 0.27, 0.18)    // desk, wood
                          : (kind2 < 0.68) ? float3(0.16, 0.17, 0.20)    // chair, dark plastic
                                           : float3(0.44, 0.34, 0.22);   // cardboard
                // Keep this nearly flat. An fbm in p.xz is constant in y, so
                // any strength here paints vertical streaks down the sides and
                // the prop reads as melted rather than manufactured.
                float wear = 0.94 + 0.10 * vnoise(p.xz * 3.0 + hp * 40.0);
                s.albedo = pc * wear * (n.y > 0.6 ? 1.12 : 1.0);
                s.roughness = (kind2 < 0.68) ? 0.45 : 0.85;
                s.bumpAmt = 0.0;
                break;
            }
        }
    }

    // Real woodchip relief bump, wherever the live mix uses wallpaper
    float paper = (A.wallFam == kFamPaper ? 1.0 - L.t : 0.0)
                + (B.wallFam == kFamPaper ? L.t : 0.0);
    if (hasTex > 0.5 && kind == 2 && paper > 0.004) {
        float2 wuv = float2((fabs(n.x) > 0.5) ? p.z : p.x, p.y) * kWallTexScale;
        const float te = 0.008;
        float h0 = wallTex.sample(wallSampler, wuv).r;
        float hx = wallTex.sample(wallSampler, wuv + float2(te, 0)).r;
        float hy = wallTex.sample(wallSampler, wuv + float2(0, te)).r;
        float3 uA = (fabs(n.x) > 0.5) ? float3(0, 0, 1) : float3(1, 0, 0);
        n = normalize(n - (uA * (hx - h0) + float3(0, 1, 0) * (hy - h0)) * (paper * 2.0));
    }

    // Procedural bump: perturb the normal with an fbm gradient in the plane
    if (s.bumpAmt > 0.005) {
        float2 tp = (kind == 2) ? float2((fabs(n.x) > 0.5) ? p.z : p.x, p.y) : p.xz;
        const float freq = 2.6, e = 0.05;
        float2 g = float2(fbm(tp * freq + float2(e, 0)) - fbm(tp * freq - float2(e, 0)),
                          fbm(tp * freq + float2(0, e)) - fbm(tp * freq - float2(0, e)))
                 * (0.5 / e);
        float3 uA = (kind == 2) ? ((fabs(n.x) > 0.5) ? float3(0, 0, 1) : float3(1, 0, 0))
                                : float3(1, 0, 0);
        float3 vA = (kind == 2) ? float3(0, 1, 0) : float3(0, 0, 1);
        n = normalize(n - (uA * g.x + vA * g.y) * (s.bumpAmt * 0.08));
    }

    float ao = calcAO(p, n, cfg);
    float3 V = -rd;
    float ndv = max(dot(n, V), 1e-4);
    float3 Rv = reflect(-V, n);
    float3 f0 = mix(float3(0.04), s.albedo, s.metallic);   // dielectric default

    // Ambient follows the light dial on a curve, not linearly: a fever level at
    // 0.15 light should be gloomy and legible, not a black screen.
    float3 amb = mixCol(L, A.amb * sqrt(L.a.lightScale) * L.a.lightTint,
                           B.amb * sqrt(L.b.lightScale) * L.b.lightTint)
               * mix(1.0, 0.55, L.horror);
    float3 col = s.albedo * amb * (0.35 + 0.65 * ao);

    float bestLum = 0.0, bestDist = 0.0;
    float3 bestAdd = float3(0), bestL = float3(0, 1, 0);

    int2 pcc = int2(floor(p.xz / kPanelPitch));
    for (int dz = -1; dz <= 1; ++dz)
    for (int dx = -1; dx <= 1; ++dx) {
        int2 pc = pcc + int2(dx, dz);
        float2 ext;
        float3 em = panelEmission(pc, P, t, globalLight, cfg.seed, mCen, mFwd, ext);
        if (dot(em, em) < 1e-6) continue;
        float2 lc = (float2(pc) + 0.5) * kPanelPitch;
        float3 lp = float3(lc.x, ceilAt(lc, cfg) - 0.07, lc.y);
        float3 toL = lp - p;
        float d2 = dot(toL, toL);
        float3 L = toL * rsqrt(max(d2, 1e-5));
        float nl = clamp(dot(n, L) * 0.62 + 0.38, 0.0, 1.0);   // wrap: see BRDF note
        float atten = 1.0 / (1.0 + d2 * 0.32);
        // Falloff must reach zero before a light can leave the 3x3 window
        // (1.5 * panel pitch horizontally), or seams appear on the floor.
        float2 hv = lc - p.xz;
        float range = clamp(1.0 - dot(hv, hv) / 9.0, 0.0, 1.0);
        range *= range;

        float3 kd = s.albedo * (1.0 - s.metallic);
        float3 add = kd * em * (0.075 * nl * atten * range);

        // Specular toward a representative point on the panel rectangle
        float3 Ls = normalize(rectRepresentativePoint(p, Rv, lp, ext) - p);
        float ndl = max(dot(n, Ls), 0.0);
        if (ndl > 0.0) {
            float3 H = normalize(Ls + V);
            float a = max(s.roughness * s.roughness, 0.002);
            float3 F = F_Schlick(f0, max(dot(V, H), 0.0));
            float spec = D_GGX(max(dot(n, H), 0.0), a) * V_SmithGGX(ndv, ndl, a);
            add += em * F * (spec * ndl * atten * range * 0.09);
        }
        col += add;
        float lum = add.x + add.y + add.z;
        if (lum > bestLum) {
            bestLum = lum; bestAdd = add; bestL = L; bestDist = sqrt(d2);
        }
    }

    // One soft shadow ray toward whichever panel dominates this point.
    // Ceiling points skip it (a ray grazing the ceiling self-shadows).
    if (primary && kind != 1 && bestLum > 0.003) {
        float sh = softShadow(p + n * 0.03, bestL, bestDist, cfg);
        col -= bestAdd * (1.0 - sh) * 0.78;
    }

    // Caustic shimmer on submerged floor
    if (kind == 0 && waterY > 0.02) {
        float wet = smoothstep(0.02, 0.16, waterY);
        float ca = fbm(p.xz * 1.8 + float2(t * 0.23, -t * 0.17));
        col *= 1.0 + wet * 2.2 * pow(ca, 3.0);
    }

    col *= 0.55 + 0.45 * ao;
    return col;
}

static float3 fogColour(thread const LevelMix &L)
{
    return mixCol(L, kLevels[L.a.base].fogCol, kLevels[L.b.base].fogCol);
}

static float3 applyFog(float3 col, float t, thread const LevelMix &L, float2 q, float time)
{
    constant LevelDef &A = kLevels[L.a.base];
    constant LevelDef &B = kLevels[L.b.base];
    float den = mixF(L, A.fogDen * L.a.fogScale, B.fogDen * L.b.fogScale)
              * mix(1.0, 1.45, L.horror);
    den *= 0.72 + 0.55 * fbm(q * 0.09 + time * 0.02);   // patchy, slowly drifting haze
    return mix(col, fogColour(L), 1.0 - exp(-t * den));
}

// ---------------------------------------------------------------------------
// Entities (horror only).
//
// Deliberately NOT part of map(): they are a post-march overlay, depth-tested
// against the primary hit. So they cost no march steps, can never block the
// camera, and cannot touch the passability contract the path planner relies on.
// Director.swift owns spawning, lifetime and fade, and passes at most one.
// ---------------------------------------------------------------------------

static float smilerMask(float2 uv)
{
    // Grin: a band following a parabola that opens upward, so the corners of
    // the mouth sit above its centre, broken into teeth.
    float yc = -0.30 + 0.62 * uv.x * uv.x;
    float mouth = smoothstep(0.16, 0.10, fabs(uv.y - yc))
                * smoothstep(0.62, 0.52, fabs(uv.x));
    float teeth = smoothstep(0.30, 0.46, fabs(fract(uv.x * 8.0) - 0.5) * 2.0);
    mouth *= 0.30 + 0.70 * teeth;
    // Eyes: two crescents, flat side down
    float2 e = float2(fabs(uv.x) - 0.30, uv.y - 0.42);
    float eye = smoothstep(0.16, 0.09, length(e * float2(1.0, 1.5)))
              * smoothstep(-0.04, 0.06, e.y + 0.11);
    return clamp(mouth + eye, 0.0, 1.0);
}

static float figureMask(float2 uv)
{
    float head = smoothstep(0.17, 0.13, length((uv - float2(0.0, 0.70)) * float2(1.15, 1.0)));
    float body = smoothstep(0.31, 0.26, length((uv - float2(0.0, -0.18)) * float2(1.0, 0.40)));
    return clamp(head + body, 0.0, 1.0);
}

static float3 applyEntity(float3 col, float3 ro, float3 rd, float tHit,
                          float4 entPos, float4 entCfg, thread const LevelMix &L, float time)
{
    constant LevelDef &A = kLevels[L.a.base];
    constant LevelDef &B = kLevels[L.b.base];
    float alpha = entPos.w;
    if (alpha < 0.002) return col;

    float3 toE = entPos.xyz - ro;
    float d = dot(toE, rd);
    if (d < 0.6 || d > tHit) return col;        // behind us, or behind a wall

    float3 off = ro + rd * d - entPos.xyz;
    float3 right = normalize(cross(rd, float3(0, 1, 0)));
    float3 up = normalize(cross(right, rd));
    float2 uv = float2(dot(off, right), dot(off, up)) / max(entCfg.y, 0.05);
    if (max(fabs(uv.x), fabs(uv.y)) > 1.3) return col;

    float den = mixF(L, A.fogDen * L.a.fogScale, B.fogDen * L.b.fogScale);
    if (entCfg.x < 0.5) {
        // Smiler: emissive, so the bloom chain gives it a halo in the haze
        float m = smilerMask(uv);
        if (m < 0.002) return col;
        float flick = 0.82 + 0.18 * vhash(float2(floor(time * 7.0), entCfg.z));
        float3 glow = float3(0.95, 0.93, 0.80) * (2.6 * m * alpha * flick);
        return col + glow * exp(-d * den * 0.85);
    }
    // Figure: a hole in the haze, read as an absence rather than an object
    float m = figureMask(uv);
    if (m < 0.002) return col;
    float3 fog = fogColour(L);
    return mix(col, mix(fog * 0.22, fog, 1.0 - exp(-d * den)), m * alpha);
}

// ---------------------------------------------------------------------------
// Primary pass
// ---------------------------------------------------------------------------

struct FSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSOut fullscreen_vs(uint vid [[vertex_id]])
{
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 backrooms_fs(FSOut in [[stage_in]],
                             constant RMUniforms &U [[buffer(0)]],
                             texture2d<float> wallTex [[texture(0)]],
                             texture2d<float> woodTex [[texture(1)]])
{
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - 2.0 * in.uv.y);
    float3 ro = U.eyeTime.xyz;
    float3 rd = normalize(U.fwdSeed.xyz
                          + U.rightTanX.xyz * (ndc.x * U.rightTanX.w)
                          + U.upTanY.xyz * (ndc.y * U.upTanY.w));

    LevelMix L;
    L.a = unpackLook(U.lookA0, U.lookA1, U.lookA2);
    L.b = unpackLook(U.lookB0, U.lookB1, U.lookB2);
    L.t = clamp(U.level.x, 0.0, 1.0);
    L.horror = clamp(U.horror.x, 0.0, 1.0);
    constant LevelDef &A = kLevels[L.a.base];
    constant LevelDef &B = kLevels[L.b.base];

    float t = U.eyeTime.w;
    float waterY = U.level.y;
    float globalLight = U.mode.y;

    MapCfg cfg;
    cfg.ceilH = U.mode.z;
    cfg.ceilAmp = U.horror.z;
    cfg.ceilPhase = U.horror.w;
    cfg.doorW = mixF(L, A.doorW, B.doorW);
    cfg.doorH = mixF(L, A.doorH, B.doorH);
    cfg.doorR = mixF(L, A.doorR, B.doorR);
    cfg.pillarR = mixF(L, A.pillarR * L.a.pillarScale, B.pillarR * L.b.pillarScale);
    cfg.roundness = mixF(L, A.roundness, B.roundness);
    cfg.skirt = mixF(L, A.skirt, B.skirt);
    cfg.wainscotH = mixF(L, A.wainscotH, B.wainscotH);
    cfg.wainscotInv = 1.0 / (cfg.wainscotH * 0.35 - cfg.wainscotH);
    cfg.leanAmt = mixF(L, A.leanAmt, B.leanAmt);
    cfg.partProb = mixF(L, A.partProb, B.partProb);
    cfg.soffitProb = mixF(L, A.soffitProb, B.soffitProb);
    cfg.pillarProb = mixF(L, A.pillarProb, B.pillarProb);
    cfg.archProb = mixF(L, A.archProb, B.archProb);
    cfg.bowAmt = mixF(L, A.bowAmt, B.bowAmt);
    cfg.propProb = mixF(L, A.propProb, B.propProb);
    cfg.seed = as_type<uint>(U.fwdSeed.w);

    bool hit;
    float tHit = march(ro, rd, 48.0, 120, cfg, hit);
    float3 col;
    if (hit) {
        float3 p = ro + rd * tHit;
        float3 n = calcNormal(p, cfg);
        float2 fq = (ro + rd * min(tHit, 14.0)).xz;
        col = applyFog(shade(p, n, rd, L, t, globalLight, waterY, true, wallTex, U.mode.w,
                             woodTex, U.horror.y, U.motion.xy, U.motion.zw, cfg),
                       tHit, L, fq, t);
    } else {
        col = fogColour(L);
    }

    // Water plane: reflect one bounce, absorb what is underneath.
    if (waterY > 0.02 && rd.y < -0.001 && ro.y > waterY) {
        float tw = (waterY - ro.y) / rd.y;
        if (tw > 0.0 && tw < tHit) {
            float3 wp = ro + rd * tw;
            float2 q = wp.xz * 1.35 + float2(t * 0.16, -t * 0.11);
            float e = 0.09;
            float2 grad = float2(fbm(q + float2(e, 0)) - fbm(q - float2(e, 0)),
                                 fbm(q + float2(0, e)) - fbm(q - float2(0, e)));

            // Drips: expanding rings from hashed points, fading as they spread
            for (int dz = -1; dz <= 1; ++dz)
            for (int dx = -1; dx <= 1; ++dx) {
                float2 dc = floor(wp.xz / 2.6) + float2(dx, dz);
                float h1 = vhash(dc * 1.71 + 0.31);
                float h2 = vhash(dc * 2.13 + 9.17);
                float2 cpos = (dc + float2(0.2 + 0.6 * h1, 0.2 + 0.6 * h2)) * 2.6;
                float ph = fract(t / (4.0 + 5.0 * h1) + h2 * 7.0);
                float r = length(wp.xz - cpos);
                float ring = sin((r - ph * 2.1) * 30.0)
                           * exp(-fabs(r - ph * 2.1) * 6.0)
                           * exp(-ph * 3.5) * 0.35;
                if (r > 1e-3) grad += (wp.xz - cpos) / r * ring;
            }

            float3 nW = normalize(float3(-grad.x * 0.22, 1.0, -grad.y * 0.22));

            float3 rrd = reflect(rd, nW);
            rrd.y = abs(rrd.y) + 0.02;
            bool rhit;
            float rt = march(wp + float3(0, 0.02, 0), normalize(rrd), 26.0, 48, cfg, rhit);
            float3 rcol;
            if (rhit) {
                float3 rp = wp + normalize(rrd) * rt;
                float3 rn = calcNormal(rp, cfg);
                rcol = applyFog(shade(rp, rn, normalize(rrd), L, t, globalLight, waterY, false,
                                      wallTex, U.mode.w, woodTex, U.horror.y,
                                      U.motion.xy, U.motion.zw, cfg),
                                tw + rt, L, wp.xz, t);
            } else {
                rcol = fogColour(L);
            }
            rcol = min(rcol, float3(3.5));   // tame reflected-panel sparkle

            float depth = tHit - tw;
            float3 absorb = exp(-depth * float3(0.55, 0.30, 0.22) * 1.4);
            float3 under = col * absorb * 0.85;
            float fres = 0.03 + 0.97 * pow(1.0 - max(dot(-rd, nW), 0.0), 5.0);
            col = mix(under, rcol, clamp(fres * 1.9, 0.0, 1.0));
            tHit = min(tHit, tw);   // the water surface is what we actually see
        }
    }

    col = applyEntity(col, ro, rd, tHit, U.entPos, U.entCfg, L, t);
    return float4(col, 1.0);
}

// ---------------------------------------------------------------------------
// Post: bright pass, blur, and the grading/CCTV composite
// ---------------------------------------------------------------------------

constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

fragment float4 bright_fs(FSOut in [[stage_in]],
                          texture2d<float> src [[texture(0)]],
                          constant PostParams &P [[buffer(0)]])
{
    float3 c = src.sample(linearSampler, in.uv).rgb;
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    float threshold = P.params.z;
    float knee = threshold * 0.6 + 1e-5;
    float soft = clamp(luma - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee);
    float contrib = max(soft, luma - threshold) / max(luma, 1e-5);
    return float4(c * contrib, 1.0);
}

fragment float4 downsample_fs(FSOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              constant PostParams &P [[buffer(0)]])
{
    float2 tx = P.params.xy;
    float3 c = src.sample(linearSampler, in.uv + float2(-tx.x, -tx.y)).rgb;
    c += src.sample(linearSampler, in.uv + float2( tx.x, -tx.y)).rgb;
    c += src.sample(linearSampler, in.uv + float2(-tx.x,  tx.y)).rgb;
    c += src.sample(linearSampler, in.uv + float2( tx.x,  tx.y)).rgb;
    return float4(c * 0.25, 1.0);
}

fragment float4 blur_fs(FSOut in [[stage_in]],
                        texture2d<float> src [[texture(0)]],
                        constant PostParams &P [[buffer(0)]])
{
    float2 dir = P.params.xy;
    const float offsets[3] = { 0.0, 1.3846153846, 3.2307692308 };
    const float weights[3] = { 0.2270270270, 0.3162162162, 0.0702702703 };
    float3 c = src.sample(linearSampler, in.uv).rgb * weights[0];
    for (int i = 1; i < 3; ++i) {
        c += src.sample(linearSampler, in.uv + dir * offsets[i]).rgb * weights[i];
        c += src.sample(linearSampler, in.uv - dir * offsets[i]).rgb * weights[i];
    }
    return float4(c, 1.0);
}

// Catmull-Rom upsample (9 bilinear taps): keeps the half-res raymarch crisp.
static float3 sampleCatmullRom(texture2d<float> tex, float2 uv, float2 texSize)
{
    float2 samplePos = uv * texSize;
    float2 texPos1 = floor(samplePos - 0.5) + 0.5;
    float2 f = samplePos - texPos1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 tp0 = (texPos1 - 1.0) / texSize;
    float2 tp3 = (texPos1 + 2.0) / texSize;
    float2 tp12 = (texPos1 + w2 / w12) / texSize;
    float3 c =
        tex.sample(linearSampler, float2(tp0.x, tp0.y)).rgb * w0.x * w0.y +
        tex.sample(linearSampler, float2(tp12.x, tp0.y)).rgb * w12.x * w0.y +
        tex.sample(linearSampler, float2(tp3.x, tp0.y)).rgb * w3.x * w0.y +
        tex.sample(linearSampler, float2(tp0.x, tp12.y)).rgb * w0.x * w12.y +
        tex.sample(linearSampler, float2(tp12.x, tp12.y)).rgb * w12.x * w12.y +
        tex.sample(linearSampler, float2(tp3.x, tp12.y)).rgb * w3.x * w12.y +
        tex.sample(linearSampler, float2(tp0.x, tp3.y)).rgb * w0.x * w3.y +
        tex.sample(linearSampler, float2(tp12.x, tp3.y)).rgb * w12.x * w3.y +
        tex.sample(linearSampler, float2(tp3.x, tp3.y)).rgb * w3.x * w3.y;
    return max(c, 0.0);
}

static float3 acesFilm(float3 x)
{
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// 3x5 pixel font: rows packed 3 bits each, top row in the low bits,
// leftmost pixel in the high bit of each row.
#define G(r0,r1,r2,r3,r4) ushort((r0)|((r1)<<3)|((r2)<<6)|((r3)<<9)|((r4)<<12))
constant ushort kFont[19] = {
    G(7,5,5,5,7), G(2,6,2,2,7), G(7,1,7,4,7), G(7,1,7,1,7), G(5,5,7,1,1),
    G(7,4,7,1,7), G(7,4,7,5,7), G(7,1,1,2,2), G(7,5,7,5,7), G(7,5,7,1,7),
    G(0,2,0,2,0),                 // :
    G(1,1,2,4,4),                 // /
    G(0,0,0,0,0),                 // space
    G(7,4,4,4,7),                 // C
    G(2,5,7,5,5),                 // A
    G(5,7,7,5,5),                 // M
    G(6,5,6,5,5),                 // R
    G(7,4,6,4,7),                 // E
    G(0,7,7,7,0),                 // record dot
};
#undef G

static uint charAt(uint i, constant CompositeParams &P)
{
    uint word = (i < 16) ? P.textA[i >> 2] : P.textB[(i - 16) >> 2];
    return (word >> ((i & 3) * 8)) & 0xFFu;
}

static float fieldMask(float2 px, float2 origin, uint start, uint count, float s,
                       constant CompositeParams &P)
{
    float2 rel = px - origin;
    if (rel.x < 0.0 || rel.y < 0.0 || rel.y >= 5.0 * s) return 0.0;
    uint ci = uint(rel.x / (4.0 * s));
    if (ci >= count) return 0.0;
    int gx = int((rel.x - float(ci) * 4.0 * s) / s);
    if (gx > 2) return 0.0;
    int gy = int(rel.y / s);
    uint code = min(charAt(start + ci, P), 18u);
    ushort row = (kFont[code] >> (gy * 3)) & 7;
    return float((row >> (2 - gx)) & 1);
}

static float textMask(float2 px, constant CompositeParams &P)
{
    float s = max(2.0, floor(P.res.y / 300.0));
    float m = fieldMask(px, float2(8.0 * s, 6.0 * s), 0, 8, s, P);
    m = max(m, fieldMask(px, float2(P.res.x - 40.0 * s, 6.0 * s), 8, 8, s, P));
    m = max(m, fieldMask(px, float2(8.0 * s, P.res.y - 11.0 * s), 16, 16, s, P));
    return m;
}

fragment float4 composite_fs(FSOut in [[stage_in]],
                             texture2d<float> hdr [[texture(0)]],
                             texture2d<float> bloomNear [[texture(1)]],
                             texture2d<float> bloomFar [[texture(2)]],
                             constant CompositeParams &P [[buffer(0)]])
{
    float cctv = P.cctv.x;
    float glitch = P.cctv.y;
    float t = P.cctv.z;
    float2 px = in.position.xy;

    float2 uv = in.uv;
    float2 dc = uv - 0.5;
    float r2 = dot(dc, dc);
    uv = 0.5 + dc * (1.0 - 0.13 * r2 * cctv);       // wide-lens pincushion

    if (glitch > 0.002) {
        float bandH = 10.0 + 50.0 * vhash(float2(floor(t * 24.0), 3.0));
        float band = floor(px.y / bandH);
        float off = (vhash(float2(band, floor(t * 31.0))) - 0.5) * glitch * glitch * 0.24;
        uv.x = fract(uv.x + off);
    }

    float3 c = sampleCatmullRom(hdr, uv, P.res.zw);
    float3 b = bloomNear.sample(linearSampler, uv).rgb * 0.62
             + bloomFar.sample(linearSampler, uv).rgb * 0.38;
    c += b * P.params.w;

    c = acesFilm(c * P.params.y);

    if (cctv > 0.01) {
        float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(c, luma * float3(0.74, 0.88, 0.80), 0.55 * cctv);
        c = c * (1.0 - 0.06 * cctv) + 0.030 * cctv;
        c *= 1.0 - 0.10 * cctv * (0.5 + 0.5 * sin(px.y * 3.14159));
        float roll = exp(-pow(fract(uv.y - t * 0.045) - 0.5, 2.0) * 260.0);
        c *= 1.0 + 0.045 * cctv * roll;
    }

    // Vignette + grain (heavier on camera feeds)
    c *= 1.0 - (0.42 + 0.16 * cctv) * pow(clamp(r2 * 2.0, 0.0, 1.0), 1.5);
    float g = fract(sin(dot(px + P.params.z, float2(12.9898, 78.233))) * 43758.5453);
    c += (g - 0.5) * (0.007 + 0.035 * cctv + 0.10 * glitch);

    c = pow(max(c, 0.0), float3(1.0 / 2.2));

    if (cctv > 0.5) {
        float s = max(2.0, floor(P.res.y / 300.0));
        float shadow = textMask(px - s * 0.8, P);
        float mask = textMask(px, P);
        c = mix(c, float3(0.02), shadow * 0.8 * (1.0 - mask));
        c = mix(c, float3(0.92), mask * 0.95);
    }

    return float4(c * P.params.x, 1.0);
}
