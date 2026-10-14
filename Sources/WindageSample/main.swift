//
//  main.swift
//  WindageSample
//
//  **A plain SwiftPM executable, on purpose.** `swift run WindageSample` and it opens — no Xcode
//  project, no scheme, no signing. That is how somebody who just cloned this repo will first try to
//  run it, and if that does not work the engine is not something other people can build with.
//

import AppKit
import MetalKit
import WindageEngine
import WindageSampleCore

/// The window's view: hands keyboard and mouse to `InputState` and the drawable to `FrameRenderer`.
///
/// The engine deliberately owns none of this. A window, a responder chain and a capture policy are
/// decisions an application makes, and an engine that made them for you would be a framework.
final class SampleView: MTKView {
    weak var game: SampleGame?

    override var acceptsFirstResponder: Bool { true }

    // **Three events, and the third is the one that was missing.** Shift, Control, Option and
    // Command never arrive as `keyDown`: they arrive as `flagsChanged`, and a view that does not
    // override it has no Shift at all — which is how this sample printed "shift sprint" on screen
    // with Shift doing nothing.
    //
    // **Where each goes is the game's decision, not the view's**, so the scripted walk can send keys
    // down exactly the same path and test what a keyboard would.
    //
    // **Not while a script plays**, which presses its own keys down this same path. The window takes
    // the keyboard when it opens, so whatever is typed elsewhere at that moment arrives here — and a
    // Tab puts the game in its editor, where the movement keys move the editor: two scripted walks
    // stood at the spawn for their whole length that way (2026-09-11), with every report printing.
    override func keyDown(with event: NSEvent) {
        guard game?.isScripted != true else { return }
        game?.keyPressed(KeyCode(rawValue: event.keyCode), command: event.modifierFlags.contains(.command))
    }
    override func keyUp(with event: NSEvent) {
        guard game?.isScripted != true else { return }
        game?.keyReleased(KeyCode(rawValue: event.keyCode))
    }
    override func flagsChanged(with event: NSEvent) {
        guard game?.isScripted != true else { return }
        game?.modifiersChanged(KeyCode(rawValue: event.keyCode), flags: event.modifierFlags)
    }

    override func mouseDown(with event: NSEvent) {
        guard game?.isScripted != true else { return }
        game?.mousePressed()
    }
    override func mouseMoved(with event: NSEvent) { deliver(event) }
    override func mouseDragged(with event: NSEvent) { deliver(event) }

    private func deliver(_ event: NSEvent) {
        game?.input.addMouseDelta(x: Float(event.deltaX), y: Float(event.deltaY))
    }
}

// **Unbuffered, so `swift run WindageSample | tee log` shows anything at all.** Swift's `print`
// goes to a fully-buffered stdout when it is not a terminal, and a sample whose diagnostics vanish
// the moment you pipe it is a sample that cannot be debugged by the person trying to learn from it.
setbuf(stdout, nil)

// **`WINDAGE_SAMPLE_MEASURE_AUDIO=1` renders the brazier's crackle offline and prints its level at
// distances, then exits** — no window, no speakers. How a sound this session could not hear was
// checked: the sample's own crackle.wav, through the engine's loops, at 1, 2, 4, 8 and 20 m.
if ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_MEASURE_AUDIO"] != nil {
    SampleGame.measureCrackle()
    exit(0)
}

let application = NSApplication.shared
// As a check (below) an accessory: a regular app is made active when it finishes launching, whatever
// it asks for — measured, the frontmost app became this one with no `activate` call at all.
application.setActivationPolicy(SampleGame.isCheck ? .accessory : .regular)

guard let device = MTLCreateSystemDefaultDevice() else {
    print("WindageSample: no Metal device")
    exit(1)
}

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable],
                      backing: .buffered, defer: false)
window.title = "\(Engine.name) \(Engine.version) — sample"
window.center()
window.acceptsMouseMovedEvents = true

let engine: FrameRenderer
do {
    engine = try FrameRenderer(device: device, simulationStepsPerSecond: SampleGame.stepsPerSecond)
} catch {
    print("WindageSample: \(error)")
    exit(1)
}

let view = SampleView(frame: window.contentLayoutRect, device: device)
view.colorPixelFormat = FrameRenderer.colorPixelFormat
view.depthStencilPixelFormat = FrameRenderer.depthPixelFormat
// **The view hosts the layer; it does not drive frames.** `CAMetalDisplayLink` does, and leaving
// MetalKit's own timer running as well would ask for two frames' worth of work per frame.
view.isPaused = true
view.enableSetNeedsDisplay = false
window.contentView = view

guard let game = SampleGame(engine: engine) else { exit(1) }
engine.game = game
// **Now covered by the sky pass, and kept as the fallback it is.** Every pixel is written by the
// environment cube, so this is only what shows if that pipeline fails to build — a scene with no sky
// at all being more useful than a black window.
engine.clearColor = MTLClearColor(red: 0.42, green: 0.55, blue: 0.70, alpha: 1)

view.game = game

guard let metalLayer = view.layer as? CAMetalLayer else {
    print("WindageSample: the view has no CAMetalLayer")
    exit(1)
}
let displayLink = engine.makeDisplayLink(for: metalLayer)
displayLink.add(to: .main, forMode: .common)

game.viewportSizeChanged(width: Int(view.drawableSize.width), height: Int(view.drawableSize.height))

// **A frame into a file, and nothing else** — for a frame comparison. Before any step, so the picture is the
// same every time, and before the window is ever shown.
if let path = SampleGame.frameWanted {
    exit(game.writeFrame(to: path) ? 0 : 1)
}

// Reported so an automated check can capture *this* window rather than the whole screen.
print("WindageSample: window \(window.windowNumber)")

// **As a check the window is never shown, and never takes the keyboard** — automated walks run
// while somebody works, and a window that jumps in front takes their next keystroke. A walk needs no
// pictures; the engine keeps time with no frames at all (`runsWhileHidden`, from its first tick).
if SampleGame.isCheck {
    // Not shown.
} else {
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
}
window.makeFirstResponder(view)
application.run()
