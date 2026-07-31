import Foundation
import MetalKit
import ScreenSaver

/// Hosts an `MTKView` that drives the renderer from its own display link, so
/// `animateOneFrame` has nothing to do.
@objc(BackroomsSaverView)
public final class BackroomsSaverView: ScreenSaverView, MTKViewDelegate {
    private var metalView: MTKView?
    private var renderer: BackroomsRenderer?
    private var lastTime: CFTimeInterval = 0
    private var failureText: String?

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        setUpMetal(isPreview: isPreview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used by ScreenSaverEngine")
    }

    private func setUpMetal(isPreview: Bool) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            failureText = "No Metal device available."
            return
        }

        let view = MTKView(frame: bounds, device: device)
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.layer?.isOpaque = true

        do {
            let bundle = Bundle(for: BackroomsSaverView.self)
            renderer = try BackroomsRenderer(device: device,
                                             targetPixelFormat: view.colorPixelFormat,
                                             preview: isPreview,
                                             seed: UInt32.random(in: 0..<UInt32.max),
                                             wallTextureURL: bundle.url(forResource: "walltex",
                                                                        withExtension: "png"),
                                             woodTextureURL: bundle.url(forResource: "woodtex",
                                                                       withExtension: "png"))
        } catch {
            failureText = "Backrooms renderer failed: \(error)"
            NSLog("[BackroomsSaver] %@", failureText!)
            return
        }

        view.delegate = self
        addSubview(view)
        metalView = view
    }

    // MARK: - ScreenSaverView

    public override func startAnimation() {
        super.startAnimation()
        lastTime = CACurrentMediaTime()
        metalView?.isPaused = false
    }

    public override func stopAnimation() {
        metalView?.isPaused = true
        super.stopAnimation()
    }

    public override func animateOneFrame() {
        // Intentionally empty: MTKView drives its own redraws.
    }

    public override var hasConfigureSheet: Bool { false }
    public override var configureSheet: NSWindow? { nil }

    public override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
        guard let failureText else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        ]
        NSString(string: failureText).draw(at: NSPoint(x: 24, y: 24), withAttributes: attrs)
    }

    public override func layout() {
        super.layout()
        metalView?.frame = bounds
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer?.resize(width: Int(size.width), height: Int(size.height))
    }

    public func draw(in view: MTKView) {
        guard let renderer,
              let drawable = view.currentDrawable,
              let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 1.0 / 60.0 : min(max(now - lastTime, 0), 0.1)
        lastTime = now

        renderer.update(deltaTime: Float(dt))
        renderer.draw(to: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
