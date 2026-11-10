import Foundation
import MetalKit
import ScreenSaver
import os

/// Rare lifecycle events only (layer rebuilds, host exits). Read with:
///   /usr/bin/log show --last 1h --predicate 'subsystem == "dev.kevin.saver.backrooms"'
private let log = Logger(subsystem: "dev.kevin.saver.backrooms", category: "lifecycle")

/// Works around the macOS 14+ screen saver host. Legacy savers run inside a
/// `legacyScreenSaver` process that lingers for ~20-40 s after a dismissal and
/// is reused if the saver is triggered again in that window. The host never
/// calls `stopAnimation()` and never releases old views, so they pile up.
///
/// Once a session has ended and none of our full-screen views is in a window
/// any more, quit the host, so every activation starts in a clean process.
private enum HostLifecycle {
    /// Full-screen views currently in a window.
    static var attached = Set<ObjectIdentifier>()
    /// Live preview instances (System Settings thumbnail). Never quit under one.
    static var previews = 0
    /// At least one full-screen view has been on screen in this process.
    static var everAttached = false
    /// `com.apple.screensaver.willstop` seen since the last `didstart`.
    static var sessionEnding = false
    /// Teardown without a willstop (e.g. the display slept): quit after a grace period.
    static var fallback: DispatchWorkItem?
    static let fallbackDelay: TimeInterval = 3

    private static var observers: [NSObjectProtocol] = []

    static func installObservers() {
        guard observers.isEmpty else { return }
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screensaver.willstop"),
                                         object: nil, queue: .main) { _ in
            sessionEnding = true
            // Normally the views are still attached here and detach just after;
            // if they already left, nothing else will prompt the exit.
            if everAttached && attached.isEmpty {
                DispatchQueue.main.async { quitIfIdle(reason: "willstop after detach") }
            }
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"),
                                         object: nil, queue: .main) { _ in
            sessionEnding = false
        })
    }

    static func didAttach(_ view: NSView) {
        attached.insert(ObjectIdentifier(view))
        everAttached = true
        fallback?.cancel()
        fallback = nil
    }

    static func didDetach(_ view: NSView) {
        guard attached.remove(ObjectIdentifier(view)) != nil, attached.isEmpty else { return }
        if sessionEnding {
            // Async so the host finishes the teardown it is in the middle of. Any
            // new-session work arriving later queues behind this on the main queue.
            DispatchQueue.main.async { quitIfIdle(reason: "session ended") }
        } else {
            let work = DispatchWorkItem { quitIfIdle(reason: "detached without willstop") }
            fallback = work
            DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay, execute: work)
        }
    }

    static func quitIfIdle(reason: String) {
        guard attached.isEmpty, previews == 0 else { return }
        log.notice("quitting legacyScreenSaver (\(reason, privacy: .public)) so the next activation starts fresh")
        exit(0)
    }
}

/// Hosts an `MTKView` that drives the renderer from its own display link, so
/// `animateOneFrame` has nothing to do.
@objc(BackroomsSaverView)
public final class BackroomsSaverView: ScreenSaverView, MTKViewDelegate {
    private var metalView: MTKView?
    private var renderer: BackroomsRenderer?
    private var lastTime: CFTimeInterval = 0
    private var failureText: String?
    /// Thumbnail in System Settings. `isPreview` alone is not trusted on the
    /// modern host, so a tiny frame counts as a preview too.
    private let actsAsPreview: Bool
    private var willStopObserver: NSObjectProtocol?

    /// The host sometimes attaches this view to its window before that window
    /// is on a screen. An MTKView set up then never gets a single frame onto
    /// the display, even after the window lands on a screen: it renders at
    /// full rate behind a black lock screen. Replacing the MTKView once the
    /// window has a screen fixes the binding.
    private var attachedWithoutScreen = false
    private var screenObserver: NSObjectProtocol?

    /// Backstop for any other way the layer ends up detached from the display:
    /// until a frame from the current MTKView is seen on screen, count the
    /// ones that never were, and replace the view if none get through.
    private var layerGeneration = 0
    private var layerConfirmed = false
    private var layerUnshown = 0
    private var rebuilds = 0
    private var rebuildPending = false
    private static let maxRebuilds = 3
    private static let unshownBeforeRebuild = 30

    public override init?(frame: NSRect, isPreview: Bool) {
        actsAsPreview = isPreview || frame.width < 400
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        setUpMetal(isPreview: isPreview)

        if actsAsPreview {
            HostLifecycle.previews += 1
        } else {
            HostLifecycle.installObservers()
            // The host never calls stopAnimation(); this is the stop signal it does send.
            willStopObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screensaver.willstop"),
                object: nil, queue: .main) { [weak self] _ in
                    self?.metalView?.isPaused = true
                }
        }
    }

    deinit {
        if actsAsPreview { HostLifecycle.previews -= 1 }
        if let willStopObserver { DistributedNotificationCenter.default().removeObserver(willStopObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
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

        let view = makeMetalView(device: device)

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

    private func makeMetalView(device: MTLDevice) -> MTKView {
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
        return view
    }

    /// Swaps in a fresh MTKView (and so a fresh CAMetalLayer) bound to the
    /// window as it is now. The renderer, and the world state, carry over.
    private func rebuildMetalView(reason: String) {
        rebuildPending = false
        guard let old = metalView, let device = old.device, window != nil else { return }
        old.isPaused = true
        old.delegate = nil
        old.removeFromSuperview()
        let view = makeMetalView(device: device)
        view.delegate = self
        addSubview(view)
        metalView = view
        layerGeneration += 1
        layerConfirmed = false
        layerUnshown = 0
        view.isPaused = !isAnimating
        log.notice("rebuilt MTKView: \(reason, privacy: .public)")
    }

    private func rebuildIfAttachedWithoutScreen(_ trigger: String) {
        guard attachedWithoutScreen, window?.screen != nil else { return }
        attachedWithoutScreen = false
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        rebuildMetalView(reason: "window reached a screen (\(trigger))")
    }

    /// Called on the main queue as each frame of the current MTKView is retired.
    private func frameRetired(shown: Bool, generation: Int) {
        guard generation == layerGeneration, !layerConfirmed else { return }
        if shown {
            layerConfirmed = true
            return
        }
        layerUnshown += 1
        guard !actsAsPreview, !rebuildPending, layerUnshown >= Self.unshownBeforeRebuild,
              rebuilds < Self.maxRebuilds, window != nil, isAnimating else { return }
        rebuilds += 1
        rebuildPending = true
        let attempt = rebuilds
        // Async: never tear the view down from inside one of its own callbacks.
        DispatchQueue.main.async { [weak self] in
            self?.rebuildMetalView(reason: "no frame reached the screen (attempt \(attempt))")
        }
    }

    // MARK: - ScreenSaverView

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !actsAsPreview else { return }
        if let window {
            HostLifecycle.didAttach(self)
            if window.screen == nil {
                attachedWithoutScreen = true
                if screenObserver == nil {
                    screenObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.didChangeScreenNotification, object: window,
                        queue: .main) { [weak self] _ in
                            self?.rebuildIfAttachedWithoutScreen("didChangeScreen")
                        }
                }
            }
        } else {
            metalView?.isPaused = true
            HostLifecycle.didDetach(self)
        }
    }

    public override func startAnimation() {
        super.startAnimation()
        lastTime = CACurrentMediaTime()
        rebuildIfAttachedWithoutScreen("startAnimation")
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
        if !layerConfirmed && !actsAsPreview {
            // presentedTime == 0 means the compositor never put this frame on screen.
            let generation = layerGeneration
            drawable.addPresentedHandler { [weak self] d in
                let shown = d.presentedTime > 0
                DispatchQueue.main.async { self?.frameRetired(shown: shown, generation: generation) }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
