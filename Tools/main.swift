import AppKit
import ImageIO
import MetalKit
import UniformTypeIdentifiers

// Development harness. Two modes:
//   backdev window [--seed 7] [--level 2] [--shot cctv]
//   backdev render out.png --at 120 --dump 1,300 [--seed 7]
// Render mode needs no display, so the look can be tuned over SSH / in agent
// sessions. --at pre-rolls the director N seconds before frame 1.

func writePNG(texture: MTLTexture, to path: String) {
    let width = texture.width, height = texture.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    pixels.withUnsafeMutableBytes { buf in
        texture.getBytes(buf.baseAddress!, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let info: CGBitmapInfo = [.byteOrder32Little,
                              CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
    guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: info, provider: provider, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent) else {
        FileHandle.standardError.write("failed to build CGImage\n".data(using: .utf8)!)
        return
    }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("failed to create \(path)\n".data(using: .utf8)!)
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path) (\(width)x\(height))")
}

var args = Array(CommandLine.arguments.dropFirst())
let mode = args.first ?? "window"
if !args.isEmpty { args.removeFirst() }

func flag(_ name: String, default def: String) -> String {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return def }
    return args[i + 1]
}

let width = Int(flag("--width", default: "1440")) ?? 1440
let height = Int(flag("--height", default: "900")) ?? 900
let seed = UInt32(flag("--seed", default: "7")) ?? 7
let preRoll = Float(flag("--at", default: "0")) ?? 0
let forcedLevel = Int(flag("--level", default: "-1")).flatMap { $0 >= 0 ? $0 : nil }
let forcedShot = ["drift", "cctv"].contains(flag("--shot", default: "")) ? flag("--shot", default: "") : nil
let preview = args.contains("--preview")
let horrorFlag = Float(flag("--horror", default: ""))

func findTexture(_ name: String) -> URL? {
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let candidates = [
        exeDir.appendingPathComponent("\(name).png"),
        URL(fileURLWithPath: "Sources/Resources/\(name).png"),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
}

func makeRenderer() -> BackroomsRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
    do {
        let r = try BackroomsRenderer(device: device, targetPixelFormat: .bgra8Unorm,
                                      preview: preview, seed: seed,
                                      wallTextureURL: findTexture("walltex"),
                                      woodTextureURL: findTexture("woodtex"))
        if args.contains("--fever") {
            let k = r.director.pinFever()
            FileHandle.standardError.write("fever (seed \(seed)): \(k.describe)\n"
                                            .data(using: .utf8)!)
        }
        else if let lv = forcedLevel { r.director.pin(level: lv) }
        r.director.forcedShot = forcedShot
        if let h = horrorFlag { r.director.horror = h }
        r.director.forcedEntity = Int(flag("--entity", default: ""))
        if preRoll > 0 {
            var t: Float = 0
            while t < preRoll { r.update(deltaTime: 1.0 / 30.0); t += 1.0 / 30.0 }
        }
        return r
    } catch {
        fatalError("renderer init failed: \(error)")
    }
}

func renderOffscreen(outputPath: String, dumpFrames: [Int]) {
    let renderer = makeRenderer()
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                        width: width, height: height,
                                                        mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .shared
    let target = renderer.device.makeTexture(descriptor: desc)!

    let last = dumpFrames.max() ?? 1
    let base = outputPath.hasSuffix(".png") ? String(outputPath.dropLast(4)) : outputPath

    for frame in 1...last {
        renderer.update(deltaTime: 1.0 / 60.0)
        let cb = renderer.commandQueue.makeCommandBuffer()!
        renderer.draw(to: target, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { fatalError("GPU error on frame \(frame): \(error)") }
        if dumpFrames.contains(frame) {
            let name = dumpFrames.count == 1 ? "\(base).png" : "\(base)-\(frame).png"
            writePNG(texture: target, to: name)
        }
    }
}

final class WindowDelegate: NSObject, MTKViewDelegate, NSApplicationDelegate {
    let renderer: BackroomsRenderer
    var lastTime: CFTimeInterval = 0

    init(renderer: BackroomsRenderer) { self.renderer = renderer }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.resize(width: Int(size.width), height: Int(size.height))
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let cb = renderer.commandQueue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 1.0 / 60.0 : min(max(now - lastTime, 0), 0.1)
        lastTime = now
        renderer.update(deltaTime: Float(dt))
        renderer.draw(to: drawable.texture, commandBuffer: cb)
        cb.present(drawable)
        cb.commit()
    }
}

func runWindow() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let renderer = makeRenderer()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
    window.title = "backrooms"
    let view = MTKView(frame: window.contentLayoutRect, device: renderer.device)
    view.colorPixelFormat = .bgra8Unorm
    view.preferredFramesPerSecond = 60
    let delegate = WindowDelegate(renderer: renderer)
    view.delegate = delegate
    window.contentView = view
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.delegate = delegate
    app.activate(ignoringOtherApps: true)
    app.run()
}

/// Drives the Director headlessly and prints the level timeline, so pacing and
/// transition types can be checked without watching for twenty minutes.
func printTimeline(minutes: Float) {
    let d = Director(seed: seed, preview: preview)
    if let h = horrorFlag { d.horror = h }
    let step: Float = 1.0 / 30.0
    var t: Float = 0
    var prev: Look?
    var start: Float = 0
    var peak: Float = 0
    var melts = 0, noclips = 0, fevers = 0
    while t < minutes * 60 {
        d.update(deltaTime: step)
        let f = d.frame()
        let cur = f.lookA
        let changed = prev.map { $0.base != cur.base || $0.isFever != cur.isFever
                                 || $0.floorSrc != cur.floorSrc || $0.wallSrc != cur.wallSrc
                                 || $0.ceilSrc != cur.ceilSrc } ?? true
        if changed {
            if let pv = prev {
                // A melt ramps the blend; a noclip swaps behind a blackout at 0.
                let kind = peak > 0.01 ? "melt  " : "NOCLIP"
                if peak > 0.01 { melts += 1 } else { noclips += 1 }
                if cur.isFever { fevers += 1 }
                print(String(format: "%6.1fs  %@  %@ -> %@ (%.0fs)",
                             t, kind, pv.describe, cur.describe, t - start))
            }
            prev = cur; start = t; peak = 0
        }
        peak = max(peak, f.blend)
        t += step
    }
    print("\n  \(melts) melts, \(noclips) noclips, \(fevers) fever levels")
}

switch mode {
case "timeline":
    printTimeline(minutes: Float(flag("--minutes", default: "30")) ?? 30)
case "render":
    let out = args.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "backrooms.png"
    let dump = flag("--dump", default: "60").split(separator: ",").compactMap { Int($0) }
    renderOffscreen(outputPath: out, dumpFrames: dump.isEmpty ? [60] : dump)
case "window":
    runWindow()
default:
    print("""
    usage: backdev [window|render <out.png>] [--seed N] [--at seconds]
                   [--level 0..5 | --fever] [--shot drift|cctv] [--horror 0..1]
                   [--width N] [--height N] [--dump f1,f2] [--preview]

    levels: 0 Lobby  1 Habitable  2 Poolrooms  3 Office  4 Hotel  5 MotionLights
    """)
}
