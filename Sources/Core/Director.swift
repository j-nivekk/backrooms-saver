import Foundation
import simd

// The Director owns everything that is not a pixel: the shot sequencer
// (cinematic drift vs. locked-off CCTV angles), the level-drift timeline, and
// a camera path planned through the same hash-generated maze the shader draws.
// The world hashes here MUST stay bit-identical with Backrooms.metal.

private let kCell: Float = 4.0

// ---------------------------------------------------------------------------
// The horror dial.
//
//   0.0  pure liminal - empty, calm, unsettling only through absence. No
//        entities. Every horror term below multiplies out at exactly 0, so
//        this is the original look, unchanged.
//   1.0  full horror - Smilers and standing figures, twice the dead tubes,
//        buzzing everywhere, building-wide blackouts, heavy fog.
//
// Anything in between scales continuously. Edit this line, rebuild, done.
// ---------------------------------------------------------------------------
public let kHorror: Float = 0.0

// Per-level values the Director needs as well as the shader. Everything else
// about a level lives in kLevels[] in Backrooms.metal - keep the order in sync.
//   0 Lobby   1 Habitable   2 Poolrooms   3 Office   4 Hotel   5 MotionLights
private let kLevelCount = 6
private let kLevelCeilH: [Float]    = [3.05, 3.05, 4.25, 2.85, 2.75, 3.20]
private let kLevelWaterY: [Float]   = [-0.30, -0.30, 0.16, -0.30, -0.30, -0.30]
private let kLevelDarkness: [Float] = [0.15, 0.55, 0.10, 0.20, 0.45, 1.00]

/// What the shader needs to draw one level: which level it fundamentally is
/// (geometry knobs, panels, fog), which levels its surfaces are *wearing*, and
/// a few scalar distortions. For a canon level everything agrees and every
/// scale is 1; a fever level is the same struct with the pieces shuffled.
public struct Look {
    public var base = 0
    public var floorSrc = 0, wallSrc = 0, ceilSrc = 0
    public var lightScale: Float = 1
    public var lightTint = SIMD3<Float>(1, 1, 1)
    public var fogScale: Float = 1
    public var pillarScale: Float = 1
    public var ceilScale: Float = 1
    public var waterY: Float = -0.30
    public var isFever = false

    static func canon(_ level: Int) -> Look {
        var k = Look()
        k.base = level
        k.floorSrc = level; k.wallSrc = level; k.ceilSrc = level
        k.waterY = kLevelWaterY[level]
        return k
    }
}

/// Level pairs close enough to melt into one another - each shares a material
/// family or a palette, so the crossfade lands on something plausible the whole
/// way through. Habitable -> MotionLights is the same concrete with the lights
/// slowly deciding to follow you. Everything not listed noclips instead: a
/// glitch, a blackout, and you are somewhere else entirely.
private let kMeltPairs: [(Int, Int)] = [(0, 1), (0, 3), (0, 4), (1, 2), (1, 5), (3, 4)]

private func levelsMelt(_ a: Int, _ b: Int) -> Bool {
    let lo = min(a, b), hi = max(a, b)
    return kMeltPairs.contains { $0 == lo && $1 == hi }
}

private let kSaltRegion: UInt32  = 0xA341316C
private let kSaltWall: UInt32    = 0x8F1BBCDC
private let kSaltDoor: UInt32    = 0xC2B2AE35
private let kSaltDoorPos: UInt32 = 0x165667B1
private let kSaltCam: UInt32     = 0x94D049BB

private func uhash(_ x: UInt32) -> UInt32 {
    var h = x
    h ^= h >> 16; h = h &* 0x7feb352d
    h ^= h >> 15; h = h &* 0x846ca68b
    h ^= h >> 16
    return h
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// Deterministic RNG for the Director's own choices (shot lengths, turns).
/// The world layout does not depend on it - only the tour does.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

public struct DirectorFrame {
    public var eye = SIMD3<Float>(0, 1.55, 0)
    public var right = SIMD3<Float>(1, 0, 0)
    public var up = SIMD3<Float>(0, 1, 0)
    public var fwd = SIMD3<Float>(0, 0, 1)
    public var tanX: Float = 0.68
    public var cctv: Float = 0
    public var glitch: Float = 0
    public var fade: Float = 1
    public var globalLight: Float = 1
    public var lookA = Look.canon(0)
    public var lookB = Look.canon(0)
    public var blend: Float = 0
    public var waterY: Float = -0.3
    public var ceilH: Float = 3.05
    public var horror: Float = 0
    /// Where Level 94's lights think "you" are. During a drift that is the
    /// camera; during a CCTV shot the walk carries on without us, so lights
    /// come on in rooms we are only watching. xz only - height is irrelevant.
    public var motionCentre = SIMD2<Float>(0, 0)
    public var motionFwd = SIMD2<Float>(0, 1)
    public var entity = SIMD3<Float>(0, 0, 0)
    public var entityAlpha: Float = 0
    public var entityType: Float = 0     // 0 smiler, 1 figure
    public var entityScale: Float = 0.9
    public var entityPhase: Float = 0
    public var text = [UInt8](repeating: 12, count: 32)
}

public final class Director {
    let seed: UInt32
    let preview: Bool
    public var forcedShot: String?
    /// Debug: pin one look for the whole run (backdev --level / --fever).
    private var forcedLook: Look?
    public func pin(level: Int) { forcedLook = Look.canon(min(max(level, 0), kLevelCount - 1)) }
    public func pinFever() { forcedLook = feverLook() }
    /// Defaults to the kHorror dial; backdev's --horror overrides it per run.
    public var horror: Float = kHorror
    /// Debug only: pin an entity on screen (0 smiler, 1 figure) for tuning.
    public var forcedEntity: Int?

    private var time: Float = 0
    private var rng: SplitMix

    // MARK: - World queries (mirror of the shader)

    private func hcell(_ x: Int32, _ z: Int32, _ salt: UInt32) -> Float {
        let u = UInt32(bitPattern: x) &* 0x9E3779B1 ^ UInt32(bitPattern: z) &* 0x85EBCA77 ^ salt ^ seed
        return Float(uhash(u)) * (1.0 / 4294967296.0)
    }

    private func edgeHash(_ ex: Int32, _ ez: Int32, _ axis: Int32, _ base: UInt32) -> Float {
        return hcell(ex, ez, base &+ UInt32(bitPattern: axis) &* 0x27D4EB2F)
    }

    private func regionDense(_ ex: Int32, _ ez: Int32) -> Bool {
        let rx = Int32(floorf(Float(ex) / 6.0))
        let rz = Int32(floorf(Float(ez) / 6.0))
        return hcell(rx, rz, kSaltRegion) < 0.55
    }

    private func wallExists(_ ex: Int32, _ ez: Int32, _ axis: Int32) -> Bool {
        let prob: Float = regionDense(ex, ez) ? 0.52 : 0.18
        return edgeHash(ex, ez, axis, kSaltWall) < prob
    }

    private func doorExists(_ ex: Int32, _ ez: Int32, _ axis: Int32) -> Bool {
        let prob: Float = regionDense(ex, ez) ? 0.78 : 0.90
        return edgeHash(ex, ez, axis, kSaltDoor) < prob
    }

    private func doorFrac(_ ex: Int32, _ ez: Int32, _ axis: Int32) -> Float {
        return 0.28 + 0.44 * edgeHash(ex, ez, axis, kSaltDoorPos)
    }

    /// Edge crossed when moving from cell c one step in direction d.
    private func edgeFor(_ c: SIMD2<Int32>, _ d: SIMD2<Int32>) -> (SIMD2<Int32>, Int32) {
        if d.x == 1 { return (SIMD2(c.x + 1, c.y), 0) }
        if d.x == -1 { return (c, 0) }
        if d.y == 1 { return (SIMD2(c.x, c.y + 1), 1) }
        return (c, 1)
    }

    private func passable(_ c: SIMD2<Int32>, _ d: SIMD2<Int32>) -> Bool {
        let (e, axis) = edgeFor(c, d)
        if !wallExists(e.x, e.y, axis) { return true }
        return doorExists(e.x, e.y, axis)
    }

    private func center(_ c: SIMD2<Int32>) -> SIMD2<Float> {
        return SIMD2((Float(c.x) + 0.5) * kCell, (Float(c.y) + 0.5) * kCell)
    }

    // MARK: - Path (dense polyline with rounded corners, followed by arc length)

    private var curCell = SIMD2<Int32>(0, 0)
    private var prevDir = SIMD2<Int32>(0, 1)
    private var raw: [SIMD2<Float>] = []        // future vertices only
    private var cursorPoint = SIMD2<Float>(0, 0)
    private var dense: [SIMD2<Float>] = []
    private var cum: [Float] = []
    private var arc: Float = 0.6
    private var arcIdx = 0
    private let dirs: [SIMD2<Int32>] = [SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)]

    private func findOpenCell(near base: SIMD2<Int32>) -> SIMD2<Int32> {
        for radius in 0..<40 {
            for dz in -radius...radius {
                for dx in -radius...radius where abs(dx) == radius || abs(dz) == radius {
                    let c = SIMD2(base.x + Int32(dx), base.y + Int32(dz))
                    let open = dirs.filter { passable(c, $0) }.count
                    if open >= 2 { return c }
                }
            }
        }
        return base
    }

    private func resetPath(at cell: SIMD2<Int32>) {
        curCell = findOpenCell(near: cell)
        prevDir = dirs.first(where: { passable(curCell, $0) }) ?? SIMD2(0, 1)
        cursorPoint = center(curCell)
        raw = []
        dense = [cursorPoint]
        cum = [0]
        arc = 0.6
        arcIdx = 0
        ensureDense(upTo: arc + 4)
        smoothedFwd = pathTangent()
    }

    private func extendRaw() {
        var options: [(SIMD2<Int32>, Float)] = []
        for d in dirs where passable(curCell, d) {
            if d == SIMD2<Int32>(0, 0) &- prevDir { options.append((d, 0.05)) }
            else if d == prevDir { options.append((d, 3.0)) }
            else { options.append((d, 1.0)) }
        }
        guard !options.isEmpty else {
            // Sealed room (vanishingly rare): restart nearby.
            resetPath(at: SIMD2(curCell.x + 13, curCell.y + 7))
            return
        }
        let total = options.reduce(Float(0)) { $0 + $1.1 }
        var pick = Float.random(in: 0..<total, using: &rng)
        var dir = options[0].0
        for (d, w) in options {
            if pick < w { dir = d; break }
            pick -= w
        }

        let (e, axis) = edgeFor(curCell, dir)
        let next = curCell &+ dir
        var pt: SIMD2<Float>
        if wallExists(e.x, e.y, axis) {
            let f = doorFrac(e.x, e.y, axis)
            if axis == 0 {
                pt = SIMD2(Float(e.x) * kCell, (Float(e.y) + f) * kCell)
            } else {
                pt = SIMD2((Float(e.x) + f) * kCell, Float(e.y) * kCell)
            }
        } else {
            if axis == 0 {
                pt = SIMD2(Float(e.x) * kCell, (Float(e.y) + 0.5) * kCell)
            } else {
                pt = SIMD2((Float(e.x) + 0.5) * kCell, Float(e.y) * kCell)
            }
        }
        raw.append(pt)
        raw.append(center(next))
        prevDir = dir
        curCell = next
    }

    private func appendDense(_ p: SIMD2<Float>) {
        let last = dense[dense.count - 1]
        let d = simd_distance(last, p)
        if d < 1e-4 { return }
        dense.append(p)
        cum.append(cum[cum.count - 1] + d)
    }

    private func emitCorner() {
        while raw.count < 2 { extendRaw() }
        let b = raw[0], c = raw[1]
        let inVec = b - cursorPoint
        let outVec = c - b
        let lIn = simd_length(inVec), lOut = simd_length(outVec)
        guard lIn > 1e-4, lOut > 1e-4 else { raw.removeFirst(); return }
        let dIn = inVec / lIn, dOut = outVec / lOut
        let r = min(0.65, lIn * 0.4, lOut * 0.4)
        let p1 = b - dIn * r
        let p2 = b + dOut * r

        let lineLen = simd_distance(cursorPoint, p1)
        let n = max(1, Int(lineLen / 0.15))
        for i in 1...n {
            appendDense(cursorPoint + dIn * (lineLen * Float(i) / Float(n)))
        }
        for i in 1...8 {
            let t = Float(i) / 8.0
            let q = (1 - t) * (1 - t) * p1 + 2 * (1 - t) * t * b + t * t * p2
            appendDense(q)
        }
        cursorPoint = p2
        raw.removeFirst()
    }

    private func ensureDense(upTo s: Float) {
        var guardCount = 0
        while (cum.last ?? 0) < s && guardCount < 400 {
            emitCorner()
            guardCount += 1
        }
    }

    private func pathPos(_ s: Float) -> SIMD2<Float> {
        let sc = min(max(s, 0), cum.last ?? 0)
        var i = min(arcIdx, cum.count - 2)
        while i > 0 && cum[i] > sc { i -= 1 }
        while i < cum.count - 2 && cum[i + 1] < sc { i += 1 }
        arcIdx = i
        let span = cum[i + 1] - cum[i]
        let t = span > 1e-5 ? (sc - cum[i]) / span : 0
        return dense[i] + (dense[i + 1] - dense[i]) * t
    }

    private func trimPath() {
        guard arcIdx > 3000 else { return }
        let drop = arcIdx - 500
        let s0 = cum[drop]
        dense.removeFirst(drop)
        cum.removeFirst(drop)
        for i in 0..<cum.count { cum[i] -= s0 }
        arc -= s0
        arcIdx -= drop
    }

    private func pathTangent() -> SIMD3<Float> {
        let a = pathPos(arc - 0.4)
        let b = pathPos(arc + 1.4)
        let d = b - a
        let l = simd_length(d)
        if l < 1e-4 { return SIMD3(0, 0, 1) }
        return SIMD3(d.x / l, 0, d.y / l)
    }

    // MARK: - Shots

    private enum Phase { case drift, cctv }
    private var phase = Phase.drift
    private var phaseT: Float = 0
    private var glitchAt: Float = -10
    private var fadeStart: Float = -10
    private var pendingTeleport = false
    private var smoothedFwd = SIMD3<Float>(0, 0, 1)

    // CCTV shot state
    private var camXZ = SIMD2<Float>(0, 0)
    private var camTargetXZ = SIMD2<Float>(0, 0)
    private var camTargetY: Float = 0.9
    private var camPanAmp: Float = 0
    private var camPanFreq: Float = 0.07
    private var camPanPhase: Float = 0
    private var camLabel = 0

    private var driftSpeed: Float { preview ? 0.8 : 0.55 }

    public init(seed: UInt32, preview: Bool) {
        self.seed = seed
        self.preview = preview
        self.rng = SplitMix(state: UInt64(seed) &* 0x9E3779B97F4A7C15 &+ 0x1234)
        resetPath(at: SIMD2(Int32(seed % 23), Int32((seed >> 8) % 23)))
        phase = .drift
        phaseT = preview ? 14 : 34
        fadeStart = -0.7          // fade in from black on launch
        pendingTeleport = false
        lookCur = Look.canon(Int.random(in: 0..<kLevelCount, using: &rng))
        levelT = holdDuration() * Float.random(in: 0.3...1.0, using: &rng)
    }

    private func startDrift(teleport: Bool) {
        phase = .drift
        phaseT = preview ? 10 + Float.random(in: 0..<6, using: &rng)
                         : 26 + Float.random(in: 0..<18, using: &rng)
        if teleport {
            fadeStart = time
            pendingTeleport = true
        } else {
            glitchAt = time
        }
    }

    private func startCCTV() {
        phase = .cctv
        phaseT = preview ? 6 + Float.random(in: 0..<4, using: &rng)
                         : 14 + Float.random(in: 0..<10, using: &rng)
        glitchAt = time

        let here = SIMD2<Int32>(Int32(floorf(pathPos(arc).x / kCell)),
                                Int32(floorf(pathPos(arc).y / kCell)))
        var bestCell = here
        var bestDir = SIMD2<Int32>(1, 0)
        var bestRun = -1
        // On Level 94 stay near the walker: the shot worth watching is the pool
        // of light coming down the hall toward a camera nobody is standing at.
        let span: Int32 = levelCur == 5 ? 4 : 12
        for _ in 0..<14 {
            let off = SIMD2<Int32>(Int32.random(in: -span...span, using: &rng),
                                   Int32.random(in: -span...span, using: &rng))
            let c = SIMD2(here.x + off.x, here.y + off.y)
            for d in dirs {
                var run = 0
                var walk = c
                while run < 9 && passable(walk, d) {
                    walk &+= d
                    run += 1
                }
                if run > bestRun {
                    bestRun = run
                    bestCell = c
                    bestDir = d
                }
            }
        }

        let cc = center(bestCell)
        let df = SIMD2<Float>(Float(bestDir.x), Float(bestDir.y))
        let lateral = SIMD2<Float>(-df.y, df.x) * (Bool.random(using: &rng) ? 0.9 : -0.9)
        camXZ = cc - df * (kCell * 0.32) + lateral
        camTargetXZ = cc + df * (Float(max(bestRun, 1)) * kCell * 0.45)
        camTargetY = 0.9
        camPanAmp = Bool.random(using: &rng) ? 0.10 : 0
        camPanFreq = 0.06 + Float.random(in: 0..<0.03, using: &rng)
        camPanPhase = Float.random(in: 0..<6.28, using: &rng)
        camLabel = Int(hcell(bestCell.x, bestCell.y, kSaltCam) * 98) + 1
    }

    private func advanceShot() {
        switch forcedShot {
        case "drift": startDrift(teleport: Float.random(in: 0..<1, using: &rng) < 0.35); return
        case "cctv": startCCTV(); return
        default: break
        }
        switch phase {
        case .drift:
            if Float.random(in: 0..<1, using: &rng) < 0.58 { startCCTV() }
            else { startDrift(teleport: true) }
        case .cctv:
            if Float.random(in: 0..<1, using: &rng) < 0.20 { startCCTV() }
            else { startDrift(teleport: Float.random(in: 0..<1, using: &rng) < 0.25) }
        }
    }

    // MARK: - Level timeline
    // Randomised schedule: a random starting level each launch, held for a
    // random stretch, then on to a randomly chosen other one. No fixed order.
    // Neighbouring palettes melt; distant ones noclip.

    private var lookCur = Look.canon(0)
    private var lookNext = Look.canon(0)
    private var levelCur: Int { lookCur.base }
    private var levelHolding = true
    private var levelT: Float = 0
    private var levelTransLen: Float = 30
    private var levelNoclip = false

    private func holdDuration() -> Float {
        preview ? Float.random(in: 25...45, using: &rng)
                : Float.random(in: 90...160, using: &rng)
    }

    /// A fever level: a real level wearing other levels' surfaces, with the
    /// lighting gone wrong in one of a few specific ways. Random per axis, but
    /// never random per pixel - it is still one coherent place.
    private func feverLook() -> Look {
        var k = Look.canon(Int.random(in: 0..<kLevelCount, using: &rng))
        k.isFever = true
        // At least one surface always comes from elsewhere, or it is not a fever
        for _ in 0..<Int.random(in: 1...3, using: &rng) {
            let other = Int.random(in: 0..<kLevelCount, using: &rng)
            switch Int.random(in: 0...2, using: &rng) {
            case 0: k.floorSrc = other
            case 1: k.wallSrc = other
            default: k.ceilSrc = other
            }
        }
        switch Int.random(in: 0...5, using: &rng) {
        case 0: k.lightScale = Float.random(in: 0.08...0.22, using: &rng)   // nearly out
        case 1: k.lightScale = Float.random(in: 2.6...4.2, using: &rng)     // blinding
        case 2: k.lightTint = SIMD3(1.00, 0.34, 0.26); k.lightScale = 1.5   // red
        case 3: k.lightTint = SIMD3(0.44, 1.00, 0.54); k.lightScale = 1.2   // sick green
        case 4: k.lightTint = SIMD3(0.58, 0.72, 1.00); k.lightScale = 1.1   // cold
        default: break                                                      // lighting is fine, materials are not
        }
        k.fogScale = Float.random(in: 0.45...2.0, using: &rng)
        k.pillarScale = Float.random(in: 0.30...1.90, using: &rng)
        k.ceilScale = Float.random(in: 0.78...1.35, using: &rng)
        // Water anywhere, not just the poolrooms
        if Float.random(in: 0..<1, using: &rng) < 0.28 {
            k.waterY = Float.random(in: 0.04...0.17, using: &rng)
        }
        return k
    }

    private func nextLook() -> Look {
        if Float.random(in: 0..<1, using: &rng) < 0.32 {
            var k = feverLook()
            // Bias a third of fevers to the level we are already in, so the
            // "this room is going wrong" melt happens often enough to notice.
            if Float.random(in: 0..<1, using: &rng) < 0.34 { k.base = levelCur }
            return k
        }
        return Look.canon((0..<kLevelCount).filter { $0 != levelCur }.randomElement(using: &rng)!)
    }

    private func updateLevels(_ dt: Float) {
        levelT -= dt
        guard levelT <= 0 else { return }
        if levelHolding {
            lookNext = nextLook()
            // Melt when the two share a base or sit next to each other, fever or
            // not. Melting into a fever of the *same* base is the best thing the
            // whole system does: the room you are standing in slowly goes wrong
            // around you - the lights sink, the water comes up - without a cut.
            levelNoclip = !(lookCur.base == lookNext.base
                            || levelsMelt(lookCur.base, lookNext.base))
            if levelNoclip {
                // Tear the image, cut to black, come back somewhere else. The
                // swap itself lands mid-blackout, so it is never seen; 0.65 s
                // sits inside the fade's black window.
                levelTransLen = 0.65
                startDrift(teleport: true)
                glitchAt = time
            } else {
                levelTransLen = preview ? 16 : 32
            }
            levelT = levelTransLen
            levelHolding = false
        } else {
            lookCur = lookNext
            levelT = holdDuration()
            levelHolding = true
        }
    }

    private func levelBlend() -> Float {
        if levelHolding || levelNoclip { return 0 }
        return smoothstep(0, 1, 1 - levelT / levelTransLen)
    }

    // MARK: - Entities (horror only)

    private var entPos = SIMD3<Float>(0, 0, 0)
    private var entAlpha: Float = 0
    private var entType: Float = 0
    private var entScale: Float = 0.9
    private var entPhase: Float = 0
    private var entLife: Float = 0
    private var entSpawnT: Float = 20
    private var lastEyeXZ = SIMD2<Float>(0, 0)
    private var blackoutT: Float = 30
    private var blackoutUntil: Float = -10
    private var horrorGlitchT: Float = 12

    /// Places one entity somewhere the camera can plausibly see it. Both
    /// sources - the drift path and the CCTV sightline - are made of cells the
    /// planner already proved passable, so an entity never lands inside a wall.
    private func spawnEntity(type forced: Int? = nil) {
        var p: SIMD2<Float>
        if phase == .cctv {
            let f = Float.random(in: 0.45...0.85, using: &rng)
            p = camXZ + (camTargetXZ - camXZ) * f
        } else {
            // Down whichever cardinal the camera is actually facing, only as far
            // as the run is open. Following the path instead would keep putting
            // it around the next corner, where it is never in shot.
            let eye = pathPos(arc)
            let cell = SIMD2<Int32>(Int32(floorf(eye.x / kCell)), Int32(floorf(eye.y / kCell)))
            let f = smoothedFwd
            let dir: SIMD2<Int32> = abs(f.x) > abs(f.z)
                ? SIMD2(f.x > 0 ? 1 : -1, 0) : SIMD2(0, f.z > 0 ? 1 : -1)
            var run = 0
            var walk = cell
            while run < 5 && passable(walk, dir) { walk &+= dir; run += 1 }
            if run >= 2 {
                let reach = min(Float(run) * kCell - 2.0, Float.random(in: 8...15, using: &rng))
                p = center(cell) + SIMD2(Float(dir.x), Float(dir.y)) * reach
            } else {
                let ahead = Float.random(in: 9...17, using: &rng)
                ensureDense(upTo: arc + ahead + 4)
                p = pathPos(arc + ahead)
            }
        }
        // Dark levels get Smilers; lit ones get a figure, which reads better
        // when there is enough light to make a silhouette out of.
        if let f = forced {
            entType = Float(f)
        } else {
            entType = Float.random(in: 0..<1, using: &rng) < kLevelDarkness[levelCur] ? 0 : 1
        }
        entPos = SIMD3(p.x, entType < 0.5 ? 1.62 : 0.98, p.y)
        entScale = entType < 0.5 ? 0.55 : 1.05
        entPhase = Float.random(in: 0..<100, using: &rng)
        entLife = Float.random(in: 2.5...6.0, using: &rng)
    }

    private func updateEntity(_ dt: Float) {
        // Debug: keep one in the visible band ahead so the masks can be tuned.
        if let fe = forcedEntity {
            let d = simd_distance(lastEyeXZ, SIMD2(entPos.x, entPos.z))
            if entLife <= 0 || d < 5 || d > 20 { spawnEntity(type: fe) }
            entLife = 5
            entAlpha = 1
            return
        }
        guard horror > 0.01 else { entAlpha = 0; entLife = 0; return }
        if entLife > 0 {
            entLife -= dt
            // Fade with distance: it is gone before you can reach it, which is
            // both the canon behaviour and what keeps it out of the way.
            let d = simd_distance(lastEyeXZ, SIMD2(entPos.x, entPos.z))
            let near = smoothstep(4.0, 8.5, d)
            entAlpha = min(entLife, 1.0) * near * min(horror * 1.6, 1.0)
            if entLife <= 0 { entAlpha = 0 }
            return
        }
        entAlpha = 0
        entSpawnT -= dt
        guard entSpawnT <= 0 else { return }
        entSpawnT = Float.random(in: 14...48, using: &rng) / max(horror, 0.15)
        spawnEntity()
    }

    // MARK: - Update / frame

    /// Blackouts and unprovoked glitch spikes. Horror only - at 0 the guard
    /// returns immediately and neither timer ever fires.
    private func updateHorrorEvents(_ dt: Float) {
        guard horror > 0.01 else { return }
        blackoutT -= dt
        if blackoutT <= 0 {
            blackoutT = Float.random(in: 25...70, using: &rng) / max(horror, 0.15)
            blackoutUntil = time + Float.random(in: 0.5...2.0, using: &rng) * horror
        }
        horrorGlitchT -= dt
        if horrorGlitchT <= 0 {
            horrorGlitchT = Float.random(in: 6...22, using: &rng) / max(horror, 0.15)
            glitchAt = time
        }
    }

    public func update(deltaTime dt: Float) {
        time += dt
        updateLevels(dt)
        updateEntity(dt)
        updateHorrorEvents(dt)
        phaseT -= dt
        if phaseT <= 0 { advanceShot() }

        if pendingTeleport && time - fadeStart >= 0.5 {
            pendingTeleport = false
            let jump = SIMD2<Int32>(Int32.random(in: 40...120, using: &rng) * (Bool.random(using: &rng) ? 1 : -1),
                                    Int32.random(in: 40...120, using: &rng) * (Bool.random(using: &rng) ? 1 : -1))
            resetPath(at: curCell &+ jump)
        }

        // The walk continues whether or not the camera is following it: that is
        // what lets Level 94's lights switch on in a room we are only watching.
        do {
            arc += driftSpeed * dt
            ensureDense(upTo: arc + 4)
            trimPath()
            let target = pathTangent()
            let k = 1 - expf(-dt * 1.6)
            smoothedFwd += (target - smoothedFwd) * k
            smoothedFwd = simd_normalize(smoothedFwd)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        return f
    }()

    private func glyph(_ ch: Character) -> UInt8 {
        switch ch {
        case "0"..."9": return UInt8(ch.asciiValue! - 48)
        case ":": return 10
        case "/": return 11
        case "C": return 13
        case "A": return 14
        case "M": return 15
        case "R": return 16
        case "E": return 17
        case "\u{2022}": return 18
        default: return 12
        }
    }

    private func fill(_ text: inout [UInt8], _ s: String, at offset: Int, width: Int) {
        for (i, ch) in s.prefix(width).enumerated() {
            text[offset + i] = glyph(ch)
        }
    }

    public func frame() -> DirectorFrame {
        var f = DirectorFrame()
        let ka = forcedLook ?? lookCur
        let kb = forcedLook ?? (levelHolding ? lookCur : lookNext)
        let b = forcedLook != nil ? 0 : levelBlend()
        f.lookA = ka
        f.lookB = kb
        f.blend = b
        f.horror = horror
        let ca = kLevelCeilH[ka.base] * ka.ceilScale
        let cb = kLevelCeilH[kb.base] * kb.ceilScale
        f.ceilH = ca + (cb - ca) * b
        // Water rises late in the melt and drains early, as it did before
        let wa = ka.waterY, wb = kb.waterY
        let we = wb > wa ? powf(b, 1.5) : 1 - powf(1 - b, 1.5)
        f.waterY = wa + (wb - wa) * we

        let walker = pathPos(arc)
        f.motionCentre = walker
        f.motionFwd = SIMD2(smoothedFwd.x, smoothedFwd.z)
        f.entity = entPos
        f.entityAlpha = entAlpha
        f.entityType = entType
        f.entityScale = entScale
        f.entityPhase = entPhase

        // Occasional building-wide power sag, deeper the further the dial goes
        let dip = powf(max(0, sinf(time * 0.53) * sinf(time * 1.31 + 1.7) * sinf(time * 0.187 + 0.5)), 24)
        f.globalLight = 1 - (0.07 + 0.35 * horror) * dip + 0.008 * sinf(time * 2.3)
        if time < blackoutUntil { f.globalLight *= 0.03 }

        f.glitch = max(0, 1 - (time - glitchAt) / 0.35)

        let ft = time - fadeStart
        if ft < 1.5 {
            if ft < 0.5 { f.fade = 1 - smoothstep(0, 0.5, ft) }
            else if ft < 0.8 { f.fade = 0 }
            else { f.fade = smoothstep(0.8, 1.5, ft) }
        }

        let up0 = SIMD3<Float>(0, 1, 0)
        switch phase {
        case .drift:
            let p = pathPos(arc)
            f.eye = SIMD3(p.x, 1.55 + 0.02 * sinf(time * 0.9), p.y)
            let yaw = 0.16 * sinf(time * 0.11) + 0.09 * sinf(time * 0.043 + 2.1)
            let pitch = 0.05 * sinf(time * 0.07 + 0.8)
            var d = smoothedFwd
            let cy = cosf(yaw), sy = sinf(yaw)
            d = SIMD3(d.x * cy - d.z * sy, 0, d.x * sy + d.z * cy)
            d.y = pitch
            f.fwd = simd_normalize(d)
            f.tanX = 0.68
            f.cctv = 0
        case .cctv:
            f.eye = SIMD3(camXZ.x, f.ceilH - 0.42, camXZ.y)
            let target = SIMD3(camTargetXZ.x, camTargetY, camTargetXZ.y)
            var d = simd_normalize(target - f.eye)
            let pan = camPanAmp * sinf(time * camPanFreq + camPanPhase)
            let cy = cosf(pan), sy = sinf(pan)
            d = SIMD3(d.x * cy - d.z * sy, d.y, d.x * sy + d.z * cy)
            f.fwd = simd_normalize(d)
            f.tanX = 1.15
            f.cctv = 1

            var text = [UInt8](repeating: 12, count: 32)
            fill(&text, String(format: "CAM %02d", camLabel), at: 0, width: 8)
            let blink = time.truncatingRemainder(dividingBy: 1.6) < 1.0
            fill(&text, blink ? "\u{2022} REC" : "  REC", at: 8, width: 8)
            fill(&text, Director.timeFormatter.string(from: Date()), at: 16, width: 16)
            f.text = text
        }

        f.right = simd_normalize(simd_cross(f.fwd, up0))
        f.up = simd_cross(f.right, f.fwd)
        lastEyeXZ = SIMD2(f.eye.x, f.eye.z)
        return f
    }
}
