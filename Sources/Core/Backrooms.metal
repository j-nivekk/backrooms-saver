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
    float4 level;       // xyz level weights (yellow, concrete, pool), w water height
    float4 mode;        // x cctv, y global light, z ceiling height, w unused
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
    float ceilH, doorW, doorH, doorR, pillarR, roundness, skirt;
    float leanAmt, partProb, soffitProb;
    uint seed;
};

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
    // max lean, skirt). Far from the slab, skip all the detail hashes: a lower
    // bound is a valid sphere-tracing distance.
    float dQuick = max(abs(perp - lineC) - (kHalfT * 1.8 + cfg.leanAmt + cfg.skirt), aBox);
    if (dQuick > 0.55) return dQuick;

    if (edgeHash(e, axis, kSaltWall, cfg.seed) >= wallProb) {
        // Open edge - sometimes a soffit beam hangs across it.
        float sh = edgeHash(e, axis, kSaltSoffit, cfg.seed);
        if (sh >= cfg.soffitProb) return 1e5;
        float yBot = max(cfg.ceilH - mix(0.5, 0.85, fract(sh * 9.3)), 2.3);
        float d = max(abs(perp - lineC) - kHalfT * 1.4, aBox);
        return max(d, yBot - p.y);
    }

    // Per-wall thickness, skirting, and an occasional lean that grows with height
    float th = edgeHash(e, axis, kSaltThick, cfg.seed);
    float halfT = kHalfT * (0.8 + 1.0 * th) + cfg.skirt * smoothstep(0.13, 0.05, p.y);
    float lh = edgeHash(e, axis, kSaltLean, cfg.seed);
    float lean = (lh < 0.25) ? (lh / 0.125 - 1.0) * cfg.leanAmt : 0.0;
    float d = max(abs(perp - lineC - lean * (p.y / cfg.ceilH)) - halfT, aBox);

    if (edgeHash(e, axis, kSaltDoor, cfg.seed) < doorProb) {
        float frac = mix(0.28, 0.72, edgeHash(e, axis, kSaltDoorPos, cfg.seed));
        float ds = edgeHash(e, axis, kSaltDoorSz, cfg.seed);
        float dw = cfg.doorW * (0.85 + 0.35 * ds);
        float dh = cfg.doorH * (0.92 + 0.20 * fract(ds * 5.1));
        float r = min(cfg.doorR, dw * 0.45);
        float2 q = abs(float2(aL - frac * kCell, p.y - dh * 0.5 + 0.2))
                 - float2(dw * 0.5, dh * 0.5 + 0.2) + r;
        float hole = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        d = max(d, -hole);
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
    float d = min(p.y, cfg.ceilH - p.y);

    float2 cf = floor(p.xz / kCell);
    int2 ci = int2(cf);
    float2 base = cf * kCell;

    d = min(d, wallSDF(p, ci,                     0, base.x,         base.y, cfg));
    d = min(d, wallSDF(p, int2(ci.x + 1, ci.y),   0, base.x + kCell, base.y, cfg));
    d = min(d, wallSDF(p, ci,                     1, base.y,         base.x, cfg));
    d = min(d, wallSDF(p, int2(ci.x, ci.y + 1),   1, base.y + kCell, base.x, cfg));

    for (int k = 0; k < 4; ++k) {
        int2 corner = ci + int2(k & 1, k >> 1);
        float2 q = p.xz - float2(corner) * kCell;
        float dSq = max(abs(q.x), abs(q.y));
        if (dSq - 0.62 > 0.4) { d = min(d, dSq - 0.62); continue; }
        float ph = hcell(corner, kSaltPillar, cfg.seed);
        // The 0.10 minimum is load-bearing: corner plugs are the conservative
        // bound that stops rays tunnelling past co-linear neighbour walls.
        float r = 0.10;
        float round = cfg.roundness;
        if (ph < 0.30) {
            float sh = hcell(corner, kSaltPilSize, cfg.seed);
            r = clamp(cfg.pillarR * (0.45 + 1.35 * sh), 0.10, 0.60);
            if (hcell(corner, kSaltPilShape, cfg.seed) < 0.35) round = 1.0;
        }
        d = min(d, mix(dSq, length(q), round) - r);
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
// The three moods, blended by U.level.xyz.
//   0: Level 0 - yellow wallpaper, damp carpet, humming fluorescents
//   1: concrete halls - dark, sparse strip lights, pillar forests
//   2: poolrooms-ish - white tile, tall ceilings, water on the floor
// ---------------------------------------------------------------------------

constant float3 kLightCol[3] = {
    float3(1.00, 0.90, 0.66) * 7.5,
    float3(0.70, 0.95, 0.78) * 9.5,
    float3(0.85, 0.93, 1.05) * 8.0,
};
constant float kPanelProb[3] = { 0.55, 0.30, 0.42 };
constant float2 kPanelExt[3] = { float2(0.60, 0.32), float2(0.68, 0.07), float2(0.42, 0.42) };
constant float3 kAmb[3] = {
    float3(0.150, 0.128, 0.072),
    float3(0.085, 0.096, 0.089),
    float3(0.095, 0.110, 0.125),
};
constant float3 kFogCol[3] = {
    float3(0.050, 0.042, 0.021),
    float3(0.022, 0.028, 0.025),
    float3(0.052, 0.062, 0.072),
};
constant float kFogDen[3] = { 0.075, 0.078, 0.042 };

struct Surface {
    float3 albedo;
    float glossAmt;
    float glossPow;
    float bumpAmt;
};

// Channel-packed CC0 wallpaper detail (ambientCG Wallpaper001A + 001C):
// R = clean woodchip relief, G = damaged relief, B = damage colour luminance.
// Where the damage sits is decided procedurally, so it never tiles.
constexpr sampler wallSampler(filter::linear, mip_filter::linear, address::repeat);
constant float kWallTexScale = 0.91;   // ~1.1 m per tile

// kind: 0 floor, 1 ceiling, 2 wall
static Surface surfaceAt(float3 p, float3 n, int kind, float3 w, float waterY,
                         texture2d<float> wallTex, float hasTex, MapCfg cfg)
{
    Surface s;
    s.albedo = float3(0);
    s.glossAmt = 0.0;
    s.glossPow = 24.0;
    s.bumpAmt = 0.0;

    float along = (abs(n.x) > 0.5) ? p.z : p.x;

    if (w.x > 0.004) {
        float3 a;
        if (kind == 0) {
            // Carpet: coarse mottling, fine fibre noise, big damp blotches
            float fibers = 0.92 + 0.16 * vnoise(p.xz * 34.0);
            float blotch = smoothstep(0.60, 0.88, fbm(p.xz * 0.33 + 7.3));
            a = float3(0.40, 0.335, 0.170) * (0.85 + 0.30 * fbm(p.xz * 6.0));
            a *= fibers * (1.0 - 0.22 * blotch);
        } else if (kind == 1) {
            // Acoustic tiles: per-tile tint drift, speckle, grid grooves
            a = float3(0.66, 0.65, 0.58) * (0.95 + 0.09 * vhash(floor(p.xz)));
            a *= 1.0 - 0.10 * smoothstep(0.78, 0.92, vnoise(p.xz * 34.0));
            float2 g = abs(fract(p.xz) - 0.5);
            a *= 1.0 - 0.22 * smoothstep(0.47, 0.5, max(g.x, g.y));
        } else {
            float stripe = smoothstep(0.30, 0.70, 0.5 + 0.5 * sin(along * 18.0));
            a = mix(float3(0.63, 0.55, 0.29), float3(0.545, 0.465, 0.235), stripe);
            float grimeLo = smoothstep(0.55, 0.0, p.y);
            float grimeHi = smoothstep(cfg.ceilH - 0.45, cfg.ceilH, p.y);
            float sf = fbm(float2(along * 0.45, p.y * 0.45));
            float stain = smoothstep(0.55, 0.85, sf);
            a *= 1.0 - 0.32 * grimeLo - 0.18 * grimeHi - 0.28 * stain;
            if (hasTex > 0.5) {
                // Woodchip relief modulates the paint; where the procedural
                // damage mask bites, blend to the torn variant and let the
                // grey plaster backing show through.
                float4 tx = wallTex.sample(wallSampler, float2(along, p.y) * kWallTexScale);
                float dmg = clamp(smoothstep(0.42, 0.78, sf) + 0.30 * grimeLo, 0.0, 1.0);
                float relief = mix(tx.r, tx.g, dmg);
                a *= 0.80 + 0.45 * relief;
                float torn = dmg * smoothstep(0.88, 0.72, tx.b);
                a = mix(a, float3(0.50, 0.455, 0.38) * (0.45 + 0.85 * tx.b), torn);
            } else {
                a *= 0.96 + 0.07 * vnoise(float2(along, p.y) * 48.0);
            }
            // Scuff streaks and a per-region tint of the yellow
            float scuff = smoothstep(0.60, 0.88, fbm(float2(along * 2.5, p.y * 0.7) + 4.2))
                        * smoothstep(1.1, 0.35, p.y);
            a *= 1.0 - 0.20 * scuff;
            a *= 0.93 + 0.14 * hcell(int2(floor(floor(p.xz / kCell) / 6.0)), kSaltTint, cfg.seed);
            if (p.y < 0.115) {   // skirting board paint
                a = float3(0.30, 0.24, 0.12) * (0.9 + 0.2 * vnoise(float2(along * 30.0, p.y * 60.0)));
            }
        }
        s.albedo += w.x * a;
        s.glossAmt += w.x * (kind == 2 ? 0.03 : 0.0);
        // With the texture, the real relief drives the wall bump instead
        s.bumpAmt += w.x * (kind == 2 ? (hasTex > 0.5 ? 0.03 : 0.10)
                                      : (kind == 0 ? 0.06 : 0.0));
    }

    if (w.y > 0.004) {
        float3 a;
        if (kind == 0) {
            a = float3(0.20, 0.21, 0.20) * (0.85 + 0.25 * fbm(p.xz * 1.3));
        } else if (kind == 1) {
            a = float3(0.25, 0.26, 0.25) * (0.9 + 0.2 * fbm(p.xz * 0.9));
        } else {
            a = float3(0.33, 0.34, 0.33) * (0.80 + 0.30 * fbm(float2(along, p.y) * 1.7));
            a *= 1.0 - 0.35 * smoothstep(1.2, 0.0, p.y) * fbm(float2(along * 0.8, 3.1));
        }
        s.albedo += w.y * a;
        s.glossAmt += w.y * (kind == 0 ? 0.10 : 0.05);
        s.bumpAmt += w.y * (kind == 2 ? 0.50 : (kind == 0 ? 0.28 : 0.12));
    }

    if (w.z > 0.004) {
        float3 a;
        float2 tc = (kind == 2) ? float2(along, p.y) : p.xz;
        float pitch = (kind == 2) ? 0.30 : 0.50;
        float2 g = abs(fract(tc / pitch) - 0.5) * pitch;
        float grout = smoothstep(0.021, 0.012, min(g.x, g.y));
        float tint = 0.92 + 0.16 * vhash(floor(tc / pitch));
        float3 tile = (kind == 2) ? float3(0.78, 0.82, 0.85) : float3(0.66, 0.72, 0.76);
        if (kind == 1) tile = float3(0.74, 0.77, 0.80);
        a = mix(tile * tint, float3(0.42, 0.45, 0.47), grout);
        if (kind == 2 && waterY > -0.1) {   // old waterline stain on the tile
            a *= 1.0 - 0.28 * exp(-fabs(p.y - (waterY + 0.05)) * 22.0);
        }
        s.albedo += w.z * a;
        s.glossAmt += w.z * (kind == 0 ? 0.55 : 0.40);
        s.glossPow = 70.0;
        s.bumpAmt += w.z * (kind == 2 ? 0.05 : 0.02);
    }

    return s;
}

static float3 panelEmission(int2 pc, float3 w, float t, float globalLight, uint seed,
                            thread float2 &ext)
{
    float h = hcell(pc, kSaltPanel, seed);
    float3 c = float3(0);
    for (int i = 0; i < 3; ++i)
        if (w[i] > 0.004 && h < kPanelProb[i]) c += w[i] * kLightCol[i];

    ext = w.x * kPanelExt[0] + w.y * kPanelExt[1] + w.z * kPanelExt[2];
    if (hcell(pc, kSaltOrient, seed) < 0.5) ext = ext.yx;

    if (dot(c, c) < 1e-6) return float3(0);

    float fh = hcell(pc, kSaltFlick, seed);
    float b = 1.0;
    if (fh < 0.05) {
        b = 0.04;                                   // the dead one down the hall
    } else if (fh > 0.93) {
        // Episodic trouble: steady most of the time, then a stretch of
        // buzzing every half minute or so.
        float window = floor(t / 11.0 + fh * 53.0);
        float bad = step(0.72, vhash(float2(window, fh * 191.0)));
        float n = step(0.45, vhash(float2(floor(t * 5.5), fh * 371.0)));
        b = mix(1.0, 0.5 + 0.5 * n, bad * 0.9);
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

static float3 shade(float3 p, float3 n, float3 rd, float3 w, float t, float globalLight,
                    float waterY, bool primary, texture2d<float> wallTex, float hasTex,
                    MapCfg cfg)
{
    int kind = 2;
    if (n.y > 0.6 && p.y < 1.0) kind = 0;
    else if (n.y < -0.6) kind = 1;

    // Direct hit on a lit ceiling panel: pure emission (bloom does the rest).
    if (kind == 1 && p.y > cfg.ceilH - 0.05) {
        int2 pc = int2(floor(p.xz / kPanelPitch));
        float2 ext;
        float3 em = panelEmission(pc, w, t, globalLight, cfg.seed, ext);
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

    Surface s = surfaceAt(p, n, kind, w, waterY, wallTex, hasTex, cfg);

    // Real woodchip relief bump on Level 0 walls
    if (hasTex > 0.5 && kind == 2 && w.x > 0.004) {
        float2 wuv = float2((fabs(n.x) > 0.5) ? p.z : p.x, p.y) * kWallTexScale;
        const float te = 0.008;
        float h0 = wallTex.sample(wallSampler, wuv).r;
        float hx = wallTex.sample(wallSampler, wuv + float2(te, 0)).r;
        float hy = wallTex.sample(wallSampler, wuv + float2(0, te)).r;
        float3 uA = (fabs(n.x) > 0.5) ? float3(0, 0, 1) : float3(1, 0, 0);
        n = normalize(n - (uA * (hx - h0) + float3(0, 1, 0) * (hy - h0)) * (w.x * 2.0));
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

    float3 col = s.albedo * (w.x * kAmb[0] + w.y * kAmb[1] + w.z * kAmb[2]) * (0.35 + 0.65 * ao);

    float bestLum = 0.0, bestDist = 0.0;
    float3 bestAdd = float3(0), bestL = float3(0, 1, 0);

    int2 pcc = int2(floor(p.xz / kPanelPitch));
    for (int dz = -1; dz <= 1; ++dz)
    for (int dx = -1; dx <= 1; ++dx) {
        int2 pc = pcc + int2(dx, dz);
        float2 ext;
        float3 em = panelEmission(pc, w, t, globalLight, cfg.seed, ext);
        if (dot(em, em) < 1e-6) continue;
        float2 lc = (float2(pc) + 0.5) * kPanelPitch;
        float3 lp = float3(lc.x, cfg.ceilH - 0.07, lc.y);
        float3 toL = lp - p;
        float d2 = dot(toL, toL);
        float3 L = toL * rsqrt(max(d2, 1e-5));
        float nl = clamp(dot(n, L) * 0.62 + 0.38, 0.0, 1.0);
        float atten = 1.0 / (1.0 + d2 * 0.32);
        // Falloff must reach zero before a light can leave the 3x3 window
        // (1.5 * panel pitch horizontally), or seams appear on the floor.
        float2 hv = lc - p.xz;
        float range = clamp(1.0 - dot(hv, hv) / 9.0, 0.0, 1.0);
        range *= range;
        float3 add = s.albedo * em * (0.075 * nl * atten * range);
        if (s.glossAmt > 0.005) {
            float3 H = normalize(L + V);
            float sp = pow(max(dot(n, H), 0.0), s.glossPow);
            add += em * (sp * s.glossAmt * 0.08 * atten * range);
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
        float ca = fbm(p.xz * 1.8 + float2(t * 0.23, -t * 0.17));
        col *= 1.0 + w.z * 2.2 * pow(ca, 3.0);
    }

    col *= 0.55 + 0.45 * ao;
    return col;
}

static float3 applyFog(float3 col, float t, float3 w, float2 q, float time)
{
    float den = dot(w, float3(kFogDen[0], kFogDen[1], kFogDen[2]));
    den *= 0.72 + 0.55 * fbm(q * 0.09 + time * 0.02);   // patchy, slowly drifting haze
    float3 fog = w.x * kFogCol[0] + w.y * kFogCol[1] + w.z * kFogCol[2];
    return mix(col, fog, 1.0 - exp(-t * den));
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
                             texture2d<float> wallTex [[texture(0)]])
{
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - 2.0 * in.uv.y);
    float3 ro = U.eyeTime.xyz;
    float3 rd = normalize(U.fwdSeed.xyz
                          + U.rightTanX.xyz * (ndc.x * U.rightTanX.w)
                          + U.upTanY.xyz * (ndc.y * U.upTanY.w));

    float3 w = U.level.xyz;
    float t = U.eyeTime.w;
    float waterY = U.level.w;
    float globalLight = U.mode.y;

    MapCfg cfg;
    cfg.ceilH = U.mode.z;
    cfg.doorW = dot(w, float3(1.5, 2.3, 1.9));
    cfg.doorH = dot(w, float3(2.25, 2.6, 3.1));
    cfg.doorR = dot(w, float3(0.03, 0.06, 0.80));
    cfg.pillarR = dot(w, float3(0.16, 0.45, 0.40));
    cfg.roundness = w.z;
    cfg.skirt = 0.016 * w.x;
    cfg.leanAmt = dot(w, float3(0.06, 0.22, 0.05));
    cfg.partProb = dot(w, float3(0.30, 0.35, 0.15));
    cfg.soffitProb = dot(w, float3(0.25, 0.30, 0.15));
    cfg.seed = as_type<uint>(U.fwdSeed.w);

    bool hit;
    float tHit = march(ro, rd, 48.0, 120, cfg, hit);
    float3 col;
    if (hit) {
        float3 p = ro + rd * tHit;
        float3 n = calcNormal(p, cfg);
        float2 fq = (ro + rd * min(tHit, 14.0)).xz;
        col = applyFog(shade(p, n, rd, w, t, globalLight, waterY, true, wallTex, U.mode.w, cfg),
                       tHit, w, fq, t);
    } else {
        col = w.x * kFogCol[0] + w.y * kFogCol[1] + w.z * kFogCol[2];
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
                rcol = applyFog(shade(rp, rn, normalize(rrd), w, t, globalLight, waterY, false,
                                      wallTex, U.mode.w, cfg),
                                tw + rt, w, wp.xz, t);
            } else {
                rcol = w.x * kFogCol[0] + w.y * kFogCol[1] + w.z * kFogCol[2];
            }
            rcol = min(rcol, float3(3.5));   // tame reflected-panel sparkle

            float depth = tHit - tw;
            float3 absorb = exp(-depth * float3(0.55, 0.30, 0.22) * 1.4);
            float3 under = col * absorb * 0.85;
            float fres = 0.03 + 0.97 * pow(1.0 - max(dot(-rd, nW), 0.0), 5.0);
            col = mix(under, rcol, clamp(fres * 1.9, 0.0, 1.0));
        }
    }

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
