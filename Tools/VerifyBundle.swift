import AppKit
import MetalKit
import ScreenSaver

// Smoke test: load the built .saver the way ScreenSaverEngine does, instantiate
// the principal class in both preview and full-screen modes, and confirm it got
// as far as standing up a live MTKView. Catches Info.plist mistakes, missing
// @objc names, and shader compilation failures without touching System Settings.

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: verify-bundle <path/to/Pipes.saver>\n".data(using: .utf8)!)
    exit(2)
}
let path = CommandLine.arguments[1]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
    exit(1)
}

guard let bundle = Bundle(path: path) else { fail("cannot open bundle at \(path)") }
guard bundle.load() else { fail("bundle failed to load (check code signature and architecture)") }
guard let principal = bundle.principalClass else { fail("no principal class") }
guard let saverClass = principal as? ScreenSaverView.Type else {
    fail("principal class \(principal) is not a ScreenSaverView subclass")
}

for isPreview in [false, true] {
    let size = isPreview ? NSRect(x: 0, y: 0, width: 296, height: 185)
                         : NSRect(x: 0, y: 0, width: 1728, height: 1117)
    guard let view = saverClass.init(frame: size, isPreview: isPreview) else {
        fail("init(frame:isPreview: \(isPreview)) returned nil")
    }
    guard view.subviews.contains(where: { $0 is MTKView }) else {
        fail("no MTKView was created (isPreview: \(isPreview)) - the renderer failed to start")
    }
    view.startAnimation()
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    view.stopAnimation()
    print("  ok: isPreview=\(isPreview) \(Int(size.width))x\(Int(size.height))")
}

print("  \(saverClass) loaded and initialised Metal successfully")
