//
//  FrameRenderer.swift
//  WindageEngine
//

import Metal
import MetalKit
import QuartzCore
import simd

/// What a game supplies to the engine's frame loop.
///
/// The engine owns *when* things happen — pacing, frames in flight, the render pass. The game owns
/// *what* happens: its pipelines, its uniforms, its draws. The split is deliberately at that line
/// because everything above it was identical in every renderer this was extracted from, and
/// everything below it was not.
public protocol GameLoop: AnyObject {

    /// Once per displayed frame, before any simulation steps. Poll input here.
    func beginFrame()

    /// One fixed simulation step. Never called with a variable delta — see ``FixedTimestep``.
    func step(deltaTime: Float)

    /// The drawable changed size, **in pixels**. Rebuild anything that depends on aspect ratio.
    ///
    /// Called once before the first frame, and again whenever the size changes.
    func viewportSizeChanged(width: Int, height: Int)

    /// Encode any passes that must run *before* the main one — shadow maps, depth prepasses,
    /// offscreen effects.
    ///
    /// Deliberately general rather than a `encodeShadowPass` hook. The engine has no opinion about
    /// what a game renders into its own targets, and naming this after the first feature that
    /// needed it would bake one title's structure into every other title's engine.
    ///
    /// Default implementation does nothing.
    func encodePrePasses(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, interpolation: Float)

    /// Encode this frame's draws.
    ///
    /// - Parameters:
    ///   - frameSlot: which of the frames-in-flight slots this frame owns. Index per-frame resources
    ///     with it; the engine guarantees the GPU has finished with that slot.
    ///   - interpolation: how far between the last two simulation steps to draw, in `0..<1`.
    func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float)

    /// Encode the interface, **after** the scene.
    ///
    /// - Parameter interpolation: the same value ``encode(into:frameSlot:interpolation:)`` was given,
    ///   so a marker over a moving thing is drawn where the thing was drawn.
    ///
    /// Separate from ``encode(into:frameSlot:interpolation:)`` so the ordering is structural rather
    /// than a convention each title has to remember. Scene color is radiance and gets tone mapped;
    /// interface color is a specification and must not be. Draw HUD inside the scene's shading and
    /// a brand color arrives on screen desaturated, with nothing to say why.
    ///
    /// Default implementation does nothing.
    func encodeHUD(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float)
}

public extension GameLoop {
    func encodePrePasses(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, interpolation: Float) {}
    func encodeHUD(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
}

/// Why a ``FrameRenderer`` could not be made.
public enum FrameRendererError: Error, CustomStringConvertible, Sendable {
    /// The GPU is not in the Metal 4 family, which every part of the engine is written against.
    case metal4Unsupported
    /// The device would not create one of the objects every frame needs — named here.
    case couldNotCreate(String)

    public var description: String {
        switch self {
        case .metal4Unsupported: "this GPU does not support Metal 4"
        case .couldNotCreate(let what): "the device would not create the \(what)"
        }
    }
}

/// Drives frames, owns the Metal 4 objects every renderer needs, and enforces the engine's
/// reversed-Z depth convention.
///
/// **Why the depth convention lives here rather than in each game.** Reversed-Z needs the
/// projection, the compare function and the clear value to agree, and a mismatch renders *nothing at
/// all* rather than rendering badly. Three constants that must match, spread across three files, in
/// every title, is a trap that will be sprung. Here, a game that uses `FrameRenderer` and
/// ``simd_float4x4/init(perspectiveFovY:aspectRatio:nearZ:depthRange:)`` gets a consistent set by construction, and
/// ``makeDepthStencilState()`` hands back the matching depth state.
public final class FrameRenderer {

    /// Frames the CPU may run ahead of the GPU.
    public static let maxFramesInFlight = 3

    /// What the **drawable** is: what a view's layer must be set to, and what an interface pipeline
    /// draws into. `_srgb`, so the GPU encodes linear values for the display on write.
    public static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb

    /// What the **scene** is drawn into, and therefore what a game's scene pipelines must declare.
    ///
    /// **Sixteen-bit float, because shading does not stop at 1.** A surface lit by the sun with a
    /// specular highlight on it is genuinely brighter than white paper; written straight to an 8-bit target
    /// every value above 1 clips to the same white, and the brightest part of the image becomes the
    /// part carrying no information. The scene is drawn here and ``ToneMapping`` fits it into what a
    /// display can show.
    ///
    /// Half float rather than full: it holds far more range than a frame needs and costs half the
    /// bandwidth of `rgba32Float`, which on a full-screen target is the whole cost of this pass.
    public static let sceneColorPixelFormat: MTLPixelFormat = .rgba16Float

    public static let depthPixelFormat: MTLPixelFormat = .depth32Float_stencil8

    /// Reversed-Z: 0 is infinitely far, so that is what an untouched pixel starts at.
    public static let reversedZClearDepth: Double = 0.0

    public let device: MTLDevice
    /// The engine's own: a game encodes into the command buffer and encoders it is handed, and never
    /// commits work of its own on these.
    let commandQueue: MTL4CommandQueue
    let commandBuffer: MTL4CommandBuffer

    /// Everything the GPU touches must be in here. Add allocations as they are created, then
    /// ``commitResidency()``.
    public let residencySet: MTLResidencySet

    public private(set) var timestep: FixedTimestep

    /// What an untouched pixel is, **in radiance** — the scene target is HDR, so this is a linear
    /// value that will be tone mapped like everything else rather than a color that reaches the
    /// screen unchanged.
    public var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// The exposure and curve applied between the scene and the display. Change it whenever.
    public var toneMapping = ToneMapping.default

    public weak var game: GameLoop?

    private let commandAllocators: [MTL4CommandAllocator]
    private let endFrameEvent: MTLSharedEvent
    private var frameIndex: Int
    private var depthTexture: MTLTexture?
    private var sceneTexture: MTLTexture?
    private var toneMapPipeline: MTLRenderPipelineState?
    private let toneMapArgumentTable: MTL4ArgumentTable
    private let toneMapUniformBuffer: MTLBuffer
    /// Per frame in flight, because the GPU may still be reading last frame's exposure.
    private static let toneMapStride = (MemoryLayout<ToneMapping.Packed>.stride + 255) & ~255

    /// Whether the simulation keeps running while nothing is being drawn — the window hidden,
    /// minimized, covered or on another Space. **Off by default: hidden is frozen.**
    ///
    /// **The display link is the clock, and a hidden window has none.** macOS stops delivering its
    /// frames, so the simulation stops with them; when the window returns, the first frame reports the
    /// whole absence and ``FixedTimestep/maxFrameTime`` throws all but a quarter of a second of it
    /// away. Measured: hidden for 10.2 s, one frame back of 10.23 s, 30 steps run for it. That is a fair
    /// pause for a single-player game, and wrong for anything that has to keep time — a match with
    /// other players in it, a timed run, a check scripted to finish.
    ///
    /// On, the simulation is stepped from a timer while the display link is quiet: the same fixed
    /// steps, the same clock — credited once, whichever of the two credits it — with no frame drawn
    /// and ``GameLoop/beginFrame()`` not called, because no frame begins. **And the app is kept out of
    /// App Nap** while it is on (2026-09-11), which otherwise coalesces that timer a minute into hiding.
    public var runsWhileHidden = false {
        didSet {
            guard runsWhileHidden != oldValue else { return }
            hiddenTimer?.invalidate()
            hiddenTimer = nil
            hiddenActivity.map(ProcessInfo.processInfo.endActivity)
            hiddenActivity = nil
            guard runsWhileHidden else { return }
            // **And no App Nap — which needs both options, measured.** A bundled app with no sound
            // playing, hidden two minutes, the longest wait between steps each second: with no activity,
            // steady 17 ms for about a minute and then ragged, up to 120 ms (steps still 120 a second,
            // in bursts). A user-initiated activity alone left it ragged, milder — up to 54 ms. Adding
            // `latencyCritical`, "the highest timer precision available", held it at 16–17 ms the whole
            // two minutes, twice: as steady as an app playing sound, which macOS exempts anyway. Idle
            // sleep is still allowed — keeping time is not keeping the machine awake — and the cost, the
            // timer precision's power, is paid only while a game has asked for this.
            hiddenActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "A game keeping time while its window is hidden")
            // Weakly: a timer keeps its target alive, and a renderer is not kept alive by a switch.
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.stepWhileHidden() }
            }
            RunLoop.main.add(timer, forMode: .common)
            hiddenTimer = timer
        }
    }

    private var hiddenTimer: Timer?
    private var hiddenActivity: NSObjectProtocol?
    private var clock = FrameClock()

    /// Receives the display link's frames, so the renderer itself need not be an `NSObject` or show the
    /// delegate method in its API. Holds the renderer weakly: the caller owns the link, and the link
    /// owning the renderer would keep both alive after the window closed.
    private final class DisplayLinkTarget: NSObject, CAMetalDisplayLinkDelegate {
        weak var renderer: FrameRenderer?

        init(renderer: FrameRenderer) { self.renderer = renderer }

        func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
            renderer?.frame(update)
        }
    }

    private var displayLinkTarget: DisplayLinkTarget?

    isolated deinit {
        hiddenTimer?.invalidate()
        hiddenActivity.map(ProcessInfo.processInfo.endActivity)
    }

    private func stepWhileHidden() {
        guard let elapsed = clock.tick(now: CACurrentMediaTime()) else { return }
        let steps = timestep.advance(by: elapsed)
        for _ in 0..<steps {
            game?.step(deltaTime: Float(timestep.stepDuration))
        }
    }

    /// - Throws: ``FrameRendererError`` when the GPU is not Metal 4 or will not make what a frame needs.
    public init(device: MTLDevice, simulationStepsPerSecond: Double = 120) throws {
        guard device.supportsFamily(.metal4) else { throw FrameRendererError.metal4Unsupported }
        guard let queue = device.makeMTL4CommandQueue() else {
            throw FrameRendererError.couldNotCreate("command queue")
        }
        guard let buffer = device.makeCommandBuffer() else {
            throw FrameRendererError.couldNotCreate("command buffer")
        }
        guard let event = device.makeSharedEvent() else { throw FrameRendererError.couldNotCreate("frame event") }
        var allocators: [MTL4CommandAllocator] = []
        for _ in 0..<FrameRenderer.maxFramesInFlight {
            guard let allocator = device.makeCommandAllocator() else {
                throw FrameRendererError.couldNotCreate("command allocator")
            }
            allocators.append(allocator)
        }

        self.device = device
        self.commandQueue = queue
        self.commandBuffer = buffer
        self.endFrameEvent = event
        self.timestep = FixedTimestep(stepsPerSecond: simulationStepsPerSecond)
        self.commandAllocators = allocators

        let descriptor = MTLResidencySetDescriptor()
        descriptor.initialCapacity = 64
        guard let set = try? device.makeResidencySet(descriptor: descriptor) else {
            throw FrameRendererError.couldNotCreate("residency set")
        }
        self.residencySet = set

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 1      // 0: the exposure and curve
        tableDescriptor.maxTextureBindCount = 1     // 0: the scene, in radiance
        guard let table = try? device.makeArgumentTable(descriptor: tableDescriptor) else {
            throw FrameRendererError.couldNotCreate("tone-map argument table")
        }
        guard let uniforms = device.makeBuffer(
                length: FrameRenderer.toneMapStride * FrameRenderer.maxFramesInFlight,
                options: .storageModeShared) else {
            throw FrameRendererError.couldNotCreate("tone-map uniform buffer")
        }
        uniforms.label = "Tone Mapping"
        self.toneMapArgumentTable = table
        self.toneMapUniformBuffer = uniforms

        self.frameIndex = FrameRenderer.maxFramesInFlight
        event.signaledValue = UInt64(FrameRenderer.maxFramesInFlight - 1)

        queue.addResidencySet(set)
        residencySet.addAllocations([uniforms])
        residencySet.commit()

        // **Built here rather than lazily, so a failure is reported once at start-up** instead of
        // per frame from inside the render loop.
        do {
            let library = try ShaderLibrary.make(device: device, bundle: .module,
                                                 sourceNamed: "ToneMapShaders")
            let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())

            let vertexFunction = MTL4LibraryFunctionDescriptor()
            vertexFunction.library = library
            vertexFunction.name = "toneMapVertex"
            let fragmentFunction = MTL4LibraryFunctionDescriptor()
            fragmentFunction.library = library
            fragmentFunction.name = "toneMapFragment"

            let descriptor = MTL4RenderPipelineDescriptor()
            descriptor.label = "Tone Map"
            descriptor.vertexFunctionDescriptor = vertexFunction
            descriptor.fragmentFunctionDescriptor = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = FrameRenderer.colorPixelFormat
            toneMapPipeline = try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            // **Not fatal, and the fallback is a black screen rather than a crash.** A machine that
            // cannot build this pipeline is one where nothing else will work either, and saying so
            // is more use than a trap.
            NSLog("\(Engine.name): tone mapping unavailable — \(error)")
        }
    }

    /// Publishes residency changes to the GPU. Call after adding allocations.
    public func commitResidency() {
        residencySet.commit()
    }

    /// The depth-stencil state matching the engine's reversed-Z convention: nearer is *greater*.
    public func makeDepthStencilState() -> MTLDepthStencilState? {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .greater
        descriptor.isDepthWriteEnabled = true
        return device.makeDepthStencilState(descriptor: descriptor)
    }

    /// Builds a display link that drives this renderer. The caller owns it and must invalidate it.
    ///
    /// - Parameter frameRateRange: what to ask the display for. The default, 30 to 120 preferring 120,
    ///   suits a game that wants every frame a ProMotion display offers; a game holding a steady 60
    ///   asks for that instead. The simulation's rate is not this — see ``FixedTimestep``.
    public func makeDisplayLink(
        for layer: CAMetalLayer,
        frameRateRange: CAFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    ) -> CAMetalDisplayLink {
        let link = CAMetalDisplayLink(metalLayer: layer)
        let target = displayLinkTarget ?? DisplayLinkTarget(renderer: self)
        displayLinkTarget = target
        link.delegate = target
        link.preferredFrameRateRange = frameRateRange
        return link
    }

    // MARK: - Frame

    private func frame(_ update: CAMetalDisplayLink.Update) {
        let drawable = update.drawable
        let presentationTime = update.targetPresentationTimestamp

        // The display link reports when the frame will be *shown*, which is the clock animation and
        // ballistics belong on. The first frame has no predecessor and contributes no time.
        let frameTime = clock.frame(presented: presentationTime, now: CACurrentMediaTime())

        game?.beginFrame()

        let steps = timestep.advance(by: frameTime)
        for _ in 0..<steps {
            game?.step(deltaTime: Float(timestep.stepDuration))
        }

        render(to: drawable, interpolation: timestep.interpolation)
    }

    private func updateRenderTargets(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if let depthTexture, depthTexture.width == width, depthTexture.height == height { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: FrameRenderer.depthPixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        // Nothing reads depth after the pass ends, so it never needs to exist in main memory. On
        // Apple silicon a memoryless attachment lives only in tile memory: no allocation, no
        // write-out, and nothing for the residency set to track.
        descriptor.storageMode = .memoryless
        depthTexture = device.makeTexture(descriptor: descriptor)
        depthTexture?.label = "Depth"

        // **The scene target cannot be memoryless**, unlike depth: the tone map pass reads it after
        // the scene pass has ended, so it has to survive into main memory.
        let sceneDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: FrameRenderer.sceneColorPixelFormat, width: width, height: height,
            mipmapped: false)
        sceneDescriptor.usage = [.renderTarget, .shaderRead]
        sceneDescriptor.storageMode = .private
        let previous = sceneTexture
        sceneTexture = device.makeTexture(descriptor: sceneDescriptor)
        sceneTexture?.label = "Scene Colour (HDR)"

        // **Removed as well as added.** A window dragged between displays resizes repeatedly, and a
        // residency set that only ever grows holds every intermediate size resident for the life of
        // the process.
        if let previous { residencySet.removeAllocations([previous]) }
        if let sceneTexture { residencySet.addAllocations([sceneTexture]) }
        residencySet.commit()

        game?.viewportSizeChanged(width: width, height: height)
    }

    /// Pass two: the scene fitted to the display, then the interface on top of it.
    ///
    /// **The interface is drawn here, after the curve, and that is the whole reason the two are one
    /// pass.** Scene color is radiance and gets tone mapped; interface color is a *specification* —
    /// a brand red is that red, not "that red as it would look lit by this sun". Tone map the HUD as
    /// well and every interface color arrives desaturated with nothing to say why.
    private func encodeToneMapAndInterface(to target: MTLTexture,
                                           scene: MTLTexture,
                                           frameSlot: Int,
                                           interpolation: Float,
                                           game: GameLoop) {
        let descriptor = MTL4RenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        // Every pixel is written by the full-screen triangle, so there is nothing worth loading.
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        // **No depth attachment.** Nothing here is occluded by anything, and a depth buffer would
        // only be a state for the tone map and the HUD to disagree about.

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "Tone Map and Interface"
        // The scene target was written by the pass before this one, and is read here as a texture.
        encoder.barrier(afterQueueStages: .fragment, beforeStages: .fragment, visibilityOptions: .device)

        if let toneMapPipeline {
            encoder.setRenderPipelineState(toneMapPipeline)
            encoder.setArgumentTable(toneMapArgumentTable, stages: [.vertex, .fragment])
            var uniforms = toneMapping.packed
            let offset = frameSlot * FrameRenderer.toneMapStride
            toneMapUniformBuffer.contents().advanced(by: offset)
                .copyMemory(from: &uniforms, byteCount: MemoryLayout<ToneMapping.Packed>.size)
            toneMapArgumentTable.setAddress(toneMapUniformBuffer.gpuAddress + UInt64(offset), index: 0)
            toneMapArgumentTable.setTexture(scene.gpuResourceID, index: 0)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        }

        game.encodeHUD(into: encoder, frameSlot: frameSlot, interpolation: interpolation)
        encoder.endEncoding()
    }

    /// Draws one frame into a texture of your own instead of a window's drawable, and **waits for the
    /// GPU**, so what is in it can be read the moment this returns.
    ///
    /// **A frame is not only for a screen.** A check that compares this frame against a recorded one, a
    /// thumbnail, a photograph a game saves: each wants the frame the game draws, and none of them has a
    /// drawable to draw it into. The texture wants ``colorPixelFormat`` and `.renderTarget`; to read it
    /// afterwards it wants a shared or managed storage mode too.
    ///
    /// The same passes in the same order as a displayed frame — the pre-passes, the scene into its HDR
    /// target, the tone map and the interface — so what comes out is what a player would have seen.
    public func render(into texture: MTLTexture, interpolation: Float = 0) {
        guard let game else { return }
        updateRenderTargets(width: texture.width, height: texture.height)
        guard let depthTexture, let sceneTexture else { return }

        let previousValueToWaitFor = frameIndex - FrameRenderer.maxFramesInFlight
        while !endFrameEvent.wait(untilSignaledValue: UInt64(previousValueToWaitFor), timeoutMS: 1000) {
            NSLog("\(Engine.name): GPU has not completed frame \(previousValueToWaitFor) after 1 s; still waiting.")
        }
        let frameSlot = frameIndex % FrameRenderer.maxFramesInFlight
        let allocator = commandAllocators[frameSlot]
        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)

        game.encodePrePasses(into: commandBuffer, frameSlot: frameSlot, interpolation: interpolation)

        let passDescriptor = MTL4RenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = sceneTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = clearColor
        passDescriptor.colorAttachments[0].storeAction = .store
        let depthAttachment = MTLRenderPassDepthAttachmentDescriptor()
        depthAttachment.texture = depthTexture
        depthAttachment.loadAction = .clear
        depthAttachment.clearDepth = FrameRenderer.reversedZClearDepth
        depthAttachment.storeAction = .dontCare
        passDescriptor.depthAttachment = depthAttachment

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        encoder.label = "Scene, into a texture"
        encoder.barrier(afterQueueStages: .fragment, beforeStages: .fragment, visibilityOptions: .device)
        game.encode(into: encoder, frameSlot: frameSlot, interpolation: interpolation)
        encoder.endEncoding()

        encodeToneMapAndInterface(to: texture, scene: sceneTexture, frameSlot: frameSlot,
                                  interpolation: interpolation, game: game)
        commandBuffer.endCommandBuffer()
        commandQueue.commit([commandBuffer])
        commandQueue.signalEvent(endFrameEvent, value: UInt64(frameIndex))
        frameIndex += 1
        // Nothing presents this one, so nothing else will wait for it: wait here.
        while !endFrameEvent.wait(untilSignaledValue: UInt64(frameIndex - 1), timeoutMS: 5000) {
            NSLog("\(Engine.name): the GPU has not finished the frame asked for into a texture.")
        }
    }

    private func render(to drawable: CAMetalDrawable, interpolation alpha: Float) {
        updateRenderTargets(width: drawable.texture.width, height: drawable.texture.height)
        guard let depthTexture, let sceneTexture, let game else { return }

        // Block until the frame that last used this slot has actually finished on the GPU. Apple's
        // template waits once with a 10 ms timeout and ignores the result, so on expiry it falls
        // through and resets an allocator whose commands may still be executing — undefined
        // behaviour rather than a dropped frame.
        let previousValueToWaitFor = frameIndex - FrameRenderer.maxFramesInFlight
        while !endFrameEvent.wait(untilSignaledValue: UInt64(previousValueToWaitFor), timeoutMS: 1000) {
            NSLog("WindageEngine: GPU has not completed frame \(previousValueToWaitFor) after 1 s; still waiting.")
        }

        let frameSlot = frameIndex % FrameRenderer.maxFramesInFlight
        let allocator = commandAllocators[frameSlot]
        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)

        game.encodePrePasses(into: commandBuffer, frameSlot: frameSlot, interpolation: alpha)

        // **Pass one: the scene, into an HDR target.** Not into the drawable — see
        // `sceneColorPixelFormat`.
        let passDescriptor = MTL4RenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = sceneTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = clearColor
        passDescriptor.colorAttachments[0].storeAction = .store

        // Built fresh rather than mutated in place: `depthAttachment` is a `copy` property, so
        // whether edits to the returned object stick is not something to rely on.
        let depthAttachment = MTLRenderPassDepthAttachmentDescriptor()
        depthAttachment.texture = depthTexture
        depthAttachment.loadAction = .clear
        depthAttachment.clearDepth = FrameRenderer.reversedZClearDepth
        depthAttachment.storeAction = .dontCare
        passDescriptor.depthAttachment = depthAttachment

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            fatalError("Failed to create render command encoder")
        }
        encoder.label = "Scene"
        // **Wait for what the pre-passes wrote.** Shadow maps are drawn into by a pass in this very
        // command buffer and sampled here, and Metal 4 tracks no hazard for you: without this the scene
        // may sample a shadow map the shadow pass has not finished writing. It looked right in play —
        // the previous frame's maps are there to sample — and the first frame of all, with nothing in
        // them yet, came out differently on every run: shadows from another run's memory, or a black
        // scene. Found by drawing a frame into a texture with no window (2026-09-11).
        encoder.barrier(afterQueueStages: .fragment, beforeStages: .fragment, visibilityOptions: .device)
        game.encode(into: encoder, frameSlot: frameSlot, interpolation: alpha)
        encoder.endEncoding()

        encodeToneMapAndInterface(to: drawable.texture, scene: sceneTexture, frameSlot: frameSlot,
                                  interpolation: alpha, game: game)

        if let layerResidencySet = (drawable.layer as CAMetalLayer?)?.residencySet {
            commandBuffer.useResidencySet(layerResidencySet)
        }
        commandBuffer.endCommandBuffer()

        commandQueue.waitForDrawable(drawable)
        commandQueue.commit([commandBuffer])
        commandQueue.signalDrawable(drawable)
        commandQueue.signalEvent(endFrameEvent, value: UInt64(frameIndex))
        frameIndex += 1
        drawable.present()
    }
}
