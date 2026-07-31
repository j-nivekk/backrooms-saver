import Metal
import MetalKit
import simd

enum RendererError: Error {
    case noDevice
    case shaderCompilation(String)
    case missingFunction(String)
}

struct GPUUniforms {
    var eyeTime: SIMD4<Float>
    var rightTanX: SIMD4<Float>
    var upTanY: SIMD4<Float>
    var fwdSeed: SIMD4<Float>
    var level: SIMD4<Float>
    var mode: SIMD4<Float>
}

struct GPUComposite {
    var params: SIMD4<Float>
    var cctv: SIMD4<Float>
    var res: SIMD4<Float>
    var textA: SIMD4<UInt32>
    var textB: SIMD4<UInt32>
}

struct GPUPostParams {
    var params: SIMD4<Float>
}

/// Owns the Metal device and the whole frame: the raymarch pass into an HDR
/// target (rendered at reduced internal resolution - the CCTV grade hides the
/// upscale), a two-level bloom chain, and the grading composite.
public final class BackroomsRenderer {
    static let maxFramesInFlight = 3
    static let hdrFormat: MTLPixelFormat = .rgba16Float

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let director: Director

    private let rayPipeline: MTLRenderPipelineState
    private let brightPipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState

    private var hdr: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private var bloomC: MTLTexture?
    private var bloomD: MTLTexture?
    private var outSize = SIMD2<Int>(0, 0)
    private var internalSize = SIMD2<Int>(0, 0)
    private let internalScale: Float

    private var time: Float = 0
    private var frameIndex = 0
    private let inFlight = DispatchSemaphore(value: maxFramesInFlight)

    private let wallTexture: MTLTexture
    private let hasWallTexture: Bool

    /// `wallTextureURL` points at the channel-packed wallpaper detail texture
    /// (R = clean woodchip relief, G = damaged relief, B = damage colour).
    /// Missing texture falls back to the fully procedural paper grain.
    public init(device: MTLDevice, targetPixelFormat: MTLPixelFormat,
                preview: Bool, seed: UInt32, wallTextureURL: URL? = nil) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noDevice }
        commandQueue = queue
        internalScale = preview ? 1.0 : 0.6
        director = Director(seed: seed, preview: preview)

        if let url = wallTextureURL,
           let tex = try? MTKTextureLoader(device: device).newTexture(URL: url, options: [
               .allocateMipmaps: true,
               .generateMipmaps: true,
               .SRGB: false,
               .textureStorageMode: MTLStorageMode.private.rawValue,
               .textureUsage: MTLTextureUsage.shaderRead.rawValue,
           ]) {
            wallTexture = tex
            hasWallTexture = true
        } else {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                             width: 4, height: 4, mipmapped: false)
            d.usage = .shaderRead
            let t = device.makeTexture(descriptor: d)!
            let grey = [UInt8](repeating: 128, count: 4 * 4 * 4)
            grey.withUnsafeBytes { p in
                t.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                          withBytes: p.baseAddress!, bytesPerRow: 16)
            }
            wallTexture = t
            hasWallTexture = false
            if wallTextureURL != nil {
                NSLog("[BackroomsSaver] wall texture failed to load; using procedural grain")
            }
        }

        let lib: MTLLibrary
        do {
            lib = try device.makeLibrary(source: kShaderSource, options: nil)
        } catch {
            throw RendererError.shaderCompilation("\(error)")
        }

        func pipeline(_ label: String, _ fragment: String, _ format: MTLPixelFormat) throws
            -> MTLRenderPipelineState {
            guard let vs = lib.makeFunction(name: "fullscreen_vs") else {
                throw RendererError.missingFunction("fullscreen_vs")
            }
            guard let fs = lib.makeFunction(name: fragment) else {
                throw RendererError.missingFunction(fragment)
            }
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = vs
            d.fragmentFunction = fs
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        rayPipeline = try pipeline("raymarch", "backrooms_fs", Self.hdrFormat)
        brightPipeline = try pipeline("bright", "bright_fs", Self.hdrFormat)
        downsamplePipeline = try pipeline("downsample", "downsample_fs", Self.hdrFormat)
        blurPipeline = try pipeline("blur", "blur_fs", Self.hdrFormat)
        compositePipeline = try pipeline("composite", "composite_fs", targetPixelFormat)
    }

    public func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard width != outSize.x || height != outSize.y else { return }
        outSize = SIMD2(width, height)
        let iw = max(Int(Float(width) * internalScale), 32)
        let ih = max(Int(Float(height) * internalScale), 32)
        internalSize = SIMD2(iw, ih)

        func target(_ w: Int, _ h: Int, _ label: String) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.hdrFormat,
                                                             width: max(w, 1), height: max(h, 1),
                                                             mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            let t = device.makeTexture(descriptor: d)!
            t.label = label
            return t
        }
        hdr = target(iw, ih, "hdr")
        bloomA = target(iw / 2, ih / 2, "bloomA")
        bloomB = target(iw / 2, ih / 2, "bloomB")
        bloomC = target(iw / 4, ih / 4, "bloomC")
        bloomD = target(iw / 4, ih / 4, "bloomD")
    }

    public func update(deltaTime: Float) {
        time += deltaTime
        director.update(deltaTime: deltaTime)
    }

    private func pass(_ cb: MTLCommandBuffer, label: String,
                      pipeline: MTLRenderPipelineState, target: MTLTexture,
                      inputs: [MTLTexture], setBytes: (MTLRenderCommandEncoder) -> Void) {
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = target
        desc.colorAttachments[0].loadAction = .dontCare
        desc.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.label = label
        enc.setRenderPipelineState(pipeline)
        for (i, t) in inputs.enumerated() { enc.setFragmentTexture(t, index: i) }
        setBytes(enc)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func postPass(_ cb: MTLCommandBuffer, label: String,
                          pipeline: MTLRenderPipelineState, target: MTLTexture,
                          inputs: [MTLTexture], params: SIMD4<Float>) {
        pass(cb, label: label, pipeline: pipeline, target: target, inputs: inputs) { enc in
            var p = GPUPostParams(params: params)
            enc.setFragmentBytes(&p, length: MemoryLayout<GPUPostParams>.stride, index: 0)
        }
    }

    private func packText(_ text: [UInt8]) -> (SIMD4<UInt32>, SIMD4<UInt32>) {
        var words = [UInt32](repeating: 0, count: 8)
        for i in 0..<min(text.count, 32) {
            words[i / 4] |= UInt32(text[i]) << ((i % 4) * 8)
        }
        return (SIMD4(words[0], words[1], words[2], words[3]),
                SIMD4(words[4], words[5], words[6], words[7]))
    }

    /// Encodes a whole frame into `target`. The caller commits and presents.
    public func draw(to target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        resize(width: target.width, height: target.height)
        guard let hdr, let bloomA, let bloomB, let bloomC, let bloomD else { return }

        let semaphore = inFlight
        semaphore.wait()
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        frameIndex = (frameIndex + 1) % Self.maxFramesInFlight

        let f = director.frame()
        let tanY = f.tanX * Float(internalSize.y) / Float(internalSize.x)
        var uniforms = GPUUniforms(
            eyeTime: SIMD4(f.eye.x, f.eye.y, f.eye.z, time),
            rightTanX: SIMD4(f.right.x, f.right.y, f.right.z, f.tanX),
            upTanY: SIMD4(f.up.x, f.up.y, f.up.z, tanY),
            fwdSeed: SIMD4(f.fwd.x, f.fwd.y, f.fwd.z, Float(bitPattern: director.seed)),
            level: SIMD4(f.weights.x, f.weights.y, f.weights.z, f.waterY),
            mode: SIMD4(f.cctv, f.globalLight, f.ceilH, hasWallTexture ? 1 : 0))

        pass(commandBuffer, label: "raymarch", pipeline: rayPipeline, target: hdr,
             inputs: [wallTexture]) { enc in
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
        }

        let halfTexel = SIMD2<Float>(1 / Float(bloomA.width), 1 / Float(bloomA.height))
        let quarterTexel = SIMD2<Float>(1 / Float(bloomC.width), 1 / Float(bloomC.height))
        postPass(commandBuffer, label: "bright", pipeline: brightPipeline, target: bloomA,
                 inputs: [hdr], params: SIMD4(halfTexel.x, halfTexel.y, 1.15, 0))
        postPass(commandBuffer, label: "blurH.half", pipeline: blurPipeline, target: bloomB,
                 inputs: [bloomA], params: SIMD4(halfTexel.x, 0, 0, 0))
        postPass(commandBuffer, label: "blurV.half", pipeline: blurPipeline, target: bloomA,
                 inputs: [bloomB], params: SIMD4(0, halfTexel.y, 0, 0))
        postPass(commandBuffer, label: "downsample", pipeline: downsamplePipeline, target: bloomC,
                 inputs: [bloomA], params: SIMD4(halfTexel.x * 0.5, halfTexel.y * 0.5, 0, 0))
        postPass(commandBuffer, label: "blurH.quarter", pipeline: blurPipeline, target: bloomD,
                 inputs: [bloomC], params: SIMD4(quarterTexel.x, 0, 0, 0))
        postPass(commandBuffer, label: "blurV.quarter", pipeline: blurPipeline, target: bloomC,
                 inputs: [bloomD], params: SIMD4(0, quarterTexel.y, 0, 0))

        let (ta, tb) = packText(f.text)
        var comp = GPUComposite(
            params: SIMD4(f.fade, 1.12, time * 61.7, 0.9),
            cctv: SIMD4(f.cctv, f.glitch, time, 0),
            res: SIMD4(Float(target.width), Float(target.height),
                       Float(internalSize.x), Float(internalSize.y)),
            textA: ta, textB: tb)
        pass(commandBuffer, label: "composite", pipeline: compositePipeline, target: target,
             inputs: [hdr, bloomA, bloomC]) { enc in
            enc.setFragmentBytes(&comp, length: MemoryLayout<GPUComposite>.stride, index: 0)
        }
    }
}
