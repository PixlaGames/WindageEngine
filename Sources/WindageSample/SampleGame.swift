//
//  SampleGame.swift
//  WindageSample
//

import AppKit
import Metal
import MetalKit
import GameController
import simd
import WindageEngine
import WindageSampleCore

extension InputAction {
    /// **The sample's own action, and it does nothing.** It is here to show a game adding an action the
    /// engine has never heard of: it is bound to B and L1, rebinds, swaps and saves like the engine's
    /// own, and the settings screen lists it. It was the engine's until the engine's actions became
    /// only the ones it acts on, and a player's saved key for it is still found.
    nonisolated static let brace = InputAction("brace")
}

/// **The whole game.** Walk around a level you can edit, with a line of text saying where you are.
///
/// It is deliberately dull. Its job is not to be a good game; it is to be the thing that proves the
/// engine can be built against **using only its public API**, by somebody who is not the person who
/// wrote it. Every gap it hits is an engine bug — the first one it found was that `swift build`
/// compiles no Metal at all, so the HUD could not start outside Xcode. See ``ShaderLibrary``.
final class SampleGame: GameLoop {

    /// One description of the vertex layout, shared by the pipeline and the mesh loader. **They must
    /// agree**: Model I/O will convert a file to whatever layout it is handed, so a mismatch draws
    /// garbage rather than failing.
    static let semantics: [Int: String] = [
        0: MDLVertexAttributePosition,
        1: MDLVertexAttributeNormal,
        2: MDLVertexAttributeTextureCoordinate,
        3: MDLVertexAttributeTangent,
    ]

    static func vertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].format = .float3
        descriptor.attributes[1].offset = 12
        descriptor.attributes[1].bufferIndex = 0
        descriptor.attributes[2].format = .float2
        descriptor.attributes[2].offset = 24
        descriptor.attributes[2].bufferIndex = 0
        // **A `float4`, and the fourth component is not padding.** It is the handedness of the
        // bitangent, ±1, and a mirrored UV island — which is most of any character, whose two halves
        // share one texture — is lit from the wrong side without it.
        descriptor.attributes[3].format = .float4
        descriptor.attributes[3].offset = 32
        descriptor.attributes[3].bufferIndex = 0
        descriptor.layouts[0].stride = 48
        descriptor.layouts[0].stepFunction = .perVertex
        return descriptor
    }

    /// The same, plus the two attributes that make a mesh skinnable.
    ///
    /// **A separate layout and therefore a separate pipeline.** Putting joints and weights on every
    /// vertex in the level would double the size of a courtyard's geometry to say "no joint" 40,000
    /// times.
    static let skinnedSemantics: [Int: String] = [
        0: MDLVertexAttributePosition,
        1: MDLVertexAttributeNormal,
        2: MDLVertexAttributeTextureCoordinate,
        3: MDLVertexAttributeTangent,
        4: MDLVertexAttributeJointIndices,
        5: MDLVertexAttributeJointWeights,
    ]

    /// **Four influences per vertex, whatever the file holds.** The sample's figure is authored with
    /// two; Model I/O pads the rest with a joint index of 0 and a weight of 0, which contributes
    /// nothing — measured, not assumed. Four is what a bought character will bring.
    static func skinnedVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = vertexDescriptor()
        // **Weights before joints, which is not the order the shader declares them in.** A `float4`
        // wants a 16-byte-aligned offset; putting the 8-byte joint indices first would land the
        // weights at 56. Attribute *index* and byte *offset* are independent, so the layout can be
        // packed correctly and still read in the order the shader finds natural.
        descriptor.attributes[5].format = .float4
        descriptor.attributes[5].offset = 48
        descriptor.attributes[5].bufferIndex = 0
        descriptor.attributes[4].format = .ushort4
        descriptor.attributes[4].offset = 64
        descriptor.attributes[4].bufferIndex = 0
        descriptor.layouts[0].stride = 72
        return descriptor
    }

    /// One animated character: the rig, where it stands, and where it is in its two clips.
    ///
    /// **The pose is kept between frames rather than rebuilt**, because it owns its arrays — posing
    /// a character allocates nothing, and that only holds if the character keeps its pose.
    private struct Figure {
        var pose: SkeletonPose
        var idle: AnimationPlayhead
        var wave: AnimationPlayhead
        /// How much of the wave is showing, 0…1. Eased toward a target so a player walking past
        /// does not switch a character between clips in one frame.
        var waveWeight: Float = 0
        let transform: matrix_float4x4
        let position: SIMD3<Float>
    }

    /// See `scriptedWalk`.
    ///
    /// **Keys, pressed and released through the same path a keyboard uses** — `keyPressed`, which
    /// gives the game first refusal and then `InputState`. It used to hand the body a movement
    /// directly, which tested the controller and skipped everything in front of it: the bindings,
    /// the menu, and the Shift that was never wired up.
    private struct ScriptedWalk {
        struct Segment {
            let label: String
            let keys: [KeyCode]
            /// Controller elements by name — `south`, `menu`, `up` — pressed on a virtual pad.
            var pads: [String] = []
            /// Whether the segment begins with a mouse click — the same `mousePressed` the view calls.
            var clicks = false
            let seconds: Float
            var yaw: Float? = nil
            var pitch: Float? = nil
            /// A mouse movement, in points, made the moment the segment begins — through the same
            /// path a real mouse's movement takes.
            var mouse: SIMD2<Float>? = nil
            var isLook: Bool { yaw != nil || pitch != nil || mouse != nil }
        }
        enum Event {
            case begin(Segment)
            case end(Segment, report: String?)
        }

        private let segments: [Segment]
        private var index = 0
        /// Time since the script began, in whole steps.
        private var clock: Float = 0
        /// When the segment in progress is due to end, counted from the script's start.
        private var due: Float = 0
        private var peak: Float = -.greatestFiniteMagnitude
        private var begun = false

        init?(_ script: String?) {
            guard let script, !script.isEmpty else { return nil }
            var parsed: [Segment] = []
            for token in script.split(whereSeparator: \.isWhitespace) {
                let parts = token.split(separator: ":")
                guard parts.count == 2, let number = Float(parts[1]) else {
                    print("WindageSample: WINDAGE_SAMPLE_WALK wants keys:seconds — ignoring '\(token)'")
                    continue
                }
                // `yaw:` and `pitch:` take degrees and no time: they turn the view, which is the
                // one thing a replayed walk otherwise cannot do, since it ignores the mouse.
                if parts[0] == "yaw" || parts[0] == "pitch" {
                    let radians = Float.radians(fromDegrees: number)
                    parsed.append(parts[0] == "yaw"
                        ? Segment(label: String(token), keys: [], seconds: 0, yaw: radians)
                        : Segment(label: String(token), keys: [], seconds: 0, pitch: radians))
                    continue
                }
                // `mousex:` and `mousey:` take points, and no time: a mouse movement is a
                // displacement, not something held.
                if parts[0] == "mousex" || parts[0] == "mousey" {
                    let delta = parts[0] == "mousex" ? SIMD2(number, 0) : SIMD2(0, number)
                    parsed.append(Segment(label: String(token), keys: [], seconds: 0, mouse: delta))
                    continue
                }
                var keys: [KeyCode] = []
                var pads: [String] = []
                var clicks = false
                for name in parts[0].split(separator: "+") where name != "wait" {
                    if name == "click" {
                        clicks = true
                    } else if name.hasPrefix("pad.") {
                        pads.append(String(name.dropFirst(4)))
                    } else if let key = KeyCode(named: String(name)) {
                        keys.append(key)
                    } else {
                        print("WindageSample: WINDAGE_SAMPLE_WALK does not know the key '\(name)'")
                    }
                }
                parsed.append(Segment(label: String(token), keys: keys, pads: pads, clicks: clicks, seconds: number))
            }
            guard !parsed.isEmpty else { return nil }
            segments = parsed
        }

        var isRunning: Bool { index < segments.count }

        /// Whether any segment presses a controller button — in which case the game supplies a
        /// virtual pad for the whole script, and it counts as connected.
        var usesPad: Bool { segments.contains { !$0.pads.isEmpty } }

        /// What happens this step, in order: a segment whose time is up ends — its keys come up —
        /// and the next begins — its keys go down. **Checked before the body moves**, so a segment of
        /// n seconds holds its keys for the steps that fit in n.
        ///
        /// **Every boundary is a time from the script's start, not a length of its own segment** — the
        /// difference only shows when a script is run at more than one step rate, which is what the
        /// course walk does. A key can only be held for a whole number of steps, so a boundary lands on
        /// the nearest one; measuring each segment from the last boundary let those roundings *add up*,
        /// half a step at a time, over a script with forty segments in it. Counted from the start,
        /// every boundary is within half a step of where it belongs however many came before.
        ///
        /// **And a walk to be run at several rates has its segments in whole steps of the slowest** —
        /// a multiple of 1/30 s here. Nothing can make a 0.75 s press land anywhere but 0.733 or 0.767
        /// at thirty steps a second, and 10 cm of walking is what that costs.
        mutating func advance(by seconds: Float, body: CharacterController) -> [Event] {
            var events: [Event] = []
            while index < segments.count {
                let segment = segments[index]
                if !begun {
                    begun = true
                    due += segment.seconds
                    peak = body.feet.y
                    events.append(.begin(segment))
                }
                peak = max(peak, body.feet.y)
                // **Half a step of slack**, because `clock` is a sum of step lengths: sixty steps of
                // 1/120 s add to a hair under 0.5 in a Float, and a half-second segment held for a
                // sixty-first step — found when a scripted stick turn came out one step's worth long.
                guard clock >= due - seconds / 2 else {
                    clock += seconds
                    break
                }
                let f = body.feet
                let report = segment.isLook ? nil : String(
                    format: "WindageSample: walk '%@' → feet (%.2f, %.2f, %.2f), highest %.2f, %@, eye %.2f m up%@",
                    segment.label, f.x, f.y, f.z, peak, body.isGrounded ? "on the ground" : "in the air",
                    body.eye.y - f.y, body.isCrouchForced ? ", no room to stand" : "")
                events.append(.end(segment, report: report))
                index += 1
                begun = false
            }
            return events
        }
    }

    /// The settings screen's state while it is open.
    private struct SettingsMenu {
        enum Row: Equatable {
            /// A keyboard binding.
            case bind(InputAction)
            /// A controller binding — shown only while a pad is connected.
            case pad(InputAction)
            case mouseSensitivity, invertMouse
            /// The stick's own look settings — shown only while a pad is connected, beside its buttons.
            case stickSensitivity, invertStick, moveDeadzone, lookDeadzone
            case headBob, volume, ambienceVolume, brightness, reset
        }

        /// **Rebuilt every frame from whether a pad is connected**, so picking one up mid-screen adds
        /// its rows, and putting it down takes them away rather than leaving rows that do nothing.
        static func rows(withPad pad: Bool) -> [Row] {
            SampleGame.defaultSettings.bindings.actions.map { .bind($0) } + [.mouseSensitivity, .invertMouse]
                + (pad ? SampleGame.defaultSettings.padBindings.actions.map { .pad($0) }
                    + [.stickSensitivity, .invertStick, .moveDeadzone, .lookDeadzone] : [])
                + [.headBob, .volume, .ambienceVolume, .brightness, .reset]
        }

        var rows = SettingsMenu.rows(withPad: false)
        var selected = 0
        /// The row waiting for a key or a button, while the screen says "press".
        var capturing: Row?
        /// What the last change did — "Jump swapped with Forward", "P is the pause key".
        var message: String?
        /// Whether opening the screen paused the run, so closing it only resumes what it paused.
        var pausedTheRun = false

        var row: Row { rows[min(selected, rows.count - 1)] }
    }

    /// What the settings screen can be told to do, **from either device**. The keyboard's keys and
    /// the pad's buttons are two ways of saying the same six things, and one handler for the six is
    /// what keeps the two from behaving differently.
    private enum MenuCommand { case up, down, left, right, activate, close }

    /// One lamp as the shader reads it: **`w` carries the range**, so a `float3` and a scalar pack
    /// into one `float4` and there is no padding for the two sides to disagree about.
    private struct PackedLight {
        var positionAndRange: SIMD4<Float> = .zero
        var colorAndAngleOffset: SIMD4<Float> = .zero
        var directionAndAngleScale: SIMD4<Float> = .zero
        /// xy atlas offset, z scale, **w whether this light has a map at all**.
        var shadowTile: SIMD4<Float> = .zero
        /// x cube-array slice, y near plane, **w whether this light has a cube at all**.
        ///
        /// **A separate field from `shadowTile` rather than a kind flag sharing it.** The two are
        /// mutually exclusive in practice — a lamp is either aimed or it is not — but packing them
        /// into one `float4` means the shader reads `x` as a *uv offset* or as a *slice index*
        /// depending on a number in `w`, and a field whose meaning depends on another field is the
        /// kind of thing that survives every test and fails once a level mixes the two.
        var shadowCube: SIMD4<Float> = .zero
        var shadowViewProjection: matrix_float4x4 = matrix_identity_float4x4

        init() {}
        init(_ light: PunctualLight) {
            positionAndRange = SIMD4(light.position, light.range)
            // **A point light is a spot with scale 0 and offset 1**, which makes the shader's angular
            // term exactly 1 everywhere. One code path, no branch, and nothing that behaves
            // differently depending on which kind of lamp a level happens to hold.
            let cone = light.cone
            colorAndAngleOffset = SIMD4(light.color, cone?.angleOffset ?? 1)
            directionAndAngleScale = SIMD4(cone?.direction ?? SIMD3(0, -1, 0), cone?.angleScale ?? 0)
        }
    }

    private struct Uniforms {
        var viewProjection: matrix_float4x4
        var model: matrix_float4x4
        var normalMatrix: matrix_float3x3
        /// The *game's* tint — objective state, editor selection. Multiplied with the material's.
        var albedo: SIMD3<Float>
        var sunDirection: SIMD3<Float>
        /// From the file's material.
        var materialBaseColor: SIMD4<Float>
        /// **Packed into a `float4` rather than left as two loose floats.** Both sides have to agree
        /// on the padding between a `float3` and whatever follows, and a `float4` has no argument.
        var materialParams: SIMD4<Float>
        /// The level's sun, in radiance. **`w` unused** — a `float4` so neither side has to reason
        /// about the padding after a `float3`.
        var sunColor: SIMD4<Float>
        /// What this surface emits, in radiance: the material's own emission times whatever the game
        /// wants of it right now. **`w` unused**, for the same padding reason.
        var emissive: SIMD4<Float>

        init(viewProjection: matrix_float4x4,
             model: matrix_float4x4,
             normalMatrix: matrix_float3x3,
             albedo: SIMD3<Float>,
             sunDirection: SIMD3<Float>,
             material: Material,
             specularLOD: Float,
             sunColor: SIMD3<Float>,
             emissive: SIMD3<Float>) {
            self.viewProjection = viewProjection
            self.model = model
            self.normalMatrix = normalMatrix
            self.albedo = albedo
            self.sunDirection = sunDirection
            self.materialBaseColor = material.baseColor
            self.materialParams = SIMD4(material.metallic, material.roughness, specularLOD, 0)
            self.sunColor = SIMD4(sunColor, 0)
            // **The game's value, not the material's times the game's.** Multiplying them was the
            // first attempt and it silently produced nothing: an OBJ material's emission is always
            // zero — Model I/O reads neither `Ke` nor `map_Ke` — so a crate the game wanted lit was
            // zero times whatever the game asked for. The material's emission is a *default* the game
            // may use, override or ignore, and defaulting is the caller's job because only the caller
            // knows whether this surface is currently powered.
            self.emissive = SIMD4(emissive, 0)
        }
    }

    /// Mirrors `FrameUniforms` in `SampleShaders.metal`. **Frame-wide, so it is written once** — four
    /// matrices copied into every drawable's uniforms would multiply them by the object count for
    /// nothing.
    private struct FrameUniforms {
        var cascadeViewProjection: (matrix_float4x4, matrix_float4x4, matrix_float4x4, matrix_float4x4)
        /// Takes a clip-space point back to the world — how the sky pass turns a pixel into a ray.
        var inverseViewProjection: matrix_float4x4
        /// World to view. **The planar depth a cluster slice is chosen by** — the shadow cascades use
        /// radial distance, which is a different number and would pick a different cell.
        var view: matrix_float4x4
        var cascadeSplits: SIMD4<Float>
        var cascadeBlendStart: SIMD4<Float>
        var cascadeDepthBias: SIMD4<Float>
        var cameraPosition: SIMD3<Float>
        var texelSize: Float
        var viewportSize: SIMD2<Float>
        var framePadding: SIMD2<Float> = .zero
        var clusters: PackedClusterGrid
    }

    /// Mirrors `ClusterUniforms` in the shader, which mirrors `ClusterGrid`. **The slicing on both
    /// sides must be the same expression**, or a light is binned into a cell no fragment reads.
    private struct PackedClusterGrid {
        var tilesX: UInt32 = 0
        var tilesY: UInt32 = 0
        var slices: UInt32 = 0
        var sliceScale: Float = 0
        var sliceBias: Float = 0
        // **Three separate floats, not a `SIMD3`.** A `SIMD3<Float>` has 16-byte alignment in Swift
        // and the shader's three trailing scalars have four — so the struct came out 48 bytes on one
        // side and 32 on the other, and every field after it in `FrameUniforms` was read from the
        // wrong place. It rendered as the local lights simply not existing.
        var padding0: Float = 0
        var padding1: Float = 0
        var padding2: Float = 0

        init() {}
        init(_ grid: ClusterGrid) {
            tilesX = UInt32(grid.tilesX)
            tilesY = UInt32(grid.tilesY)
            slices = UInt32(grid.slices)
            sliceScale = grid.sliceScale
            sliceBias = grid.sliceBias
        }
    }
    private static let shadowFrameStride = (MemoryLayout<FrameUniforms>.stride + 255) & ~255

    private let engine: FrameRenderer
    private let pipeline: MTLRenderPipelineState
    /// **Optional: no skinned pipeline means no characters, not no sample.**
    private let skinnedPipeline: MTLRenderPipelineState?
    /// Debris, drawn instanced. **Optional, the same way: no pipeline means no debris.**
    private let instancedPipeline: MTLRenderPipelineState?
    /// The debris's shadows: a batch that encodes its own instanced draws (`ShadowBatch(pipeline:encode:)`).
    private let instancedShadowPipeline: MTLRenderPipelineState?
    /// This frame's debris transforms, written before the shadow passes so they and the scene draw the
    /// same copies.
    private var rubbleCopies: MTLBuffer?
    /// The debris lying round this level's buildings — ``SampleRubble`` — as one batch of the box mesh.
    private var rubble = InstanceBatches<String>()
    private let rubbleBuffer: InstanceBuffer
    private let depthState: MTLDepthStencilState
    private let hud: HUDRenderer?

    /// **Optional, and the game runs without it.** A machine with no output device, or an audio
    /// engine that will not start, must not stop somebody seeing the sample — sound is the first
    /// thing to go wrong on someone else's hardware and the last thing that should be fatal.
    private let audio: AudioEngine?
    private let argumentTable: MTL4ArgumentTable
    private let uniformBuffer: MTLBuffer

    /// **Optional like the audio.** A machine that cannot build the shadow pipeline should still
    /// show the sample, unlit rather than not at all.
    ///
    /// **The pass itself is the engine's now** — `ShadowMap` owns the texture, the reversed-Z depth
    /// state, the per-cascade descriptors and the encoder loop. What is left here is the part the
    /// engine genuinely cannot own: two pipelines, compiled against *this game's* shaders and *this
    /// game's* vertex layouts.
    private let shadowMap: ShadowMap?

    /// Shadow maps for the lamps, packed into one texture. **Optional like the cascades**: a machine
    /// that cannot allocate it should still show the scene, with lamps that reach through walls.
    private let shadowAtlas: ShadowAtlas?
    /// Which lights have a tile this frame, recomputed with the light set.
    private var shadowCasters: [(lightIndex: Int, caster: ShadowAtlas.Caster)] = []

    // MARK: - Settings

    /// **Where settings live, beside the progress file and separate from it** — resetting progress
    /// must not reset a player's keys, and the reverse.
    private static let settingsStore = SaveStore<PlayerSettings>(container: container, name: "settings")

    /// **`WINDAGE_SAMPLE_CHECK=1`: run as a check** — what an automated walk uses. No window (main.swift), no
    /// keyboard, no sound, and **saves of its own, cleared at launch**: a walk presses keys by name, so a
    /// player's rebinding would fail it for nothing to do with the engine, and a walk that collects a
    /// crate would otherwise write their best times.
    ///
    /// **Anything but `1` names the saves**, `WindageSample-check-<that>` — so walks running at the same
    /// time do not clear each other's: one of them sets the head bob on the settings screen, and another
    /// launching beside it would wipe that as it started. The same lesson as `SampleRun.store`, which was
    /// one shared static until tests ran in parallel.
    /// **`WINDAGE_SAMPLE_FRAME=<path>` draws one frame into a file and quits** — what a frame comparison uses,
    /// it for every viewpoint it keeps, and compares each against the frame recorded for it. No window
    /// and no drawable: the engine draws into a texture (`FrameRenderer.render(into:)`), which is read
    /// and written out as a PNG.
    ///
    /// **Drawn before a single step**, so it is the same picture every time: the clock full, no crate
    /// collected, the lifts and the turntable where the level puts them.
    static let frameWanted = ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_FRAME"]

    /// **`WINDAGE_SAMPLE_RATE=<steps per second>` steps the simulation that often** — the default is the
    /// engine's 120. A game picks its own rate once and lives with it; what a *sample* is for is showing
    /// that the choice does not change the game. The course walk is run at 30, 60, 120 and
    /// 240 and requires one set of numbers.
    static let stepsPerSecond = ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_RATE"]
        .flatMap(Double.init) ?? 120

    /// **`WINDAGE_SAMPLE_SPLASH=1|0` shows or hides the engine's splash.**
    ///
    /// Unset means **on in ordinary play and off in a check or a recorded frame**, which is not
    /// squeamishness: a recorded frame is a picture of the *scene*, and a splash over it would be
    /// checking the splash in four places and the scene in none. The splash gets a recorded frame of
    /// its own, and a walk of its own that runs behind it.
    static let showsSplash = switch ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_SPLASH"] {
    case "0": false
    case .some: true
    case nil: frameWanted == nil && checkName == nil
    }

    static let checkName = ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_CHECK"]
    static var isCheck: Bool { checkName != nil }
    private static let container = switch checkName {
    case nil: "WindageSample"
    case "1": "WindageSample-check"
    case let name?: "WindageSample-check-\(name)"
    }
    /// **Where the editor's copy of a level goes**: the player's own folder in ordinary play — `nil`, which is
    /// `SampleLevel`'s own — and a check's own container in a check, emptied of edited levels as the check starts. With
    /// one place for both, a check that edited a level would have saved into the player's folder, and the sample would
    /// then have loaded the check's edits in ordinary play.
    static let levelDirectory: URL? = {
        guard isCheck else { return nil }
        let folder = SaveStore<SampleRun.Progress>(container: container, name: "progress").url.deletingLastPathComponent()
        for index in SampleLevel.names.indices { SampleLevel.discardEdits(index, in: folder) }
        return folder
    }()

    private static let progressStore: SaveStore<SampleRun.Progress> = {
        let store = isCheck ? SaveStore<SampleRun.Progress>(container: container, name: "progress") : SampleRun.sharedStore
        if isCheck { try? store.clear(); try? settingsStore.clear() }
        return store
    }()
    private var settings = SampleGame.isCheck ? SampleGame.defaultSettings : SampleGame.savedSettings()

    /// The player's saved settings, or the defaults — **said in the log when a file is there and will not
    /// read**, so a player whose keys reset knows it was the file, not them.
    private static func savedSettings() -> PlayerSettings {
        do {
            return try settingsStore.load().map(withSampleActions) ?? defaultSettings
        } catch {
            print("WindageSample: settings could not be read, using the defaults — \(error)")
            return defaultSettings
        }
    }

    /// The engine's settings with the sample's own action added — see `InputAction.brace`. **After
    /// loading**, so a key the player gave it is found in the file and kept.
    nonisolated private static func withSampleActions(_ loaded: PlayerSettings) -> PlayerSettings {
        var settings = loaded
        settings.bindings = settings.bindings.adding(.brace, defaultKey: .b)
        settings.padBindings = settings.padBindings.adding(.brace, defaultButton: .leftShoulder)
        return settings
    }
    private static let defaultSettings = withSampleActions(PlayerSettings())

    /// What the settings screen calls each action. **The game's words, not the engine's**: an action's
    /// name is an identifier a file stores, and what a player reads is the game's to say.
    private static func title(of action: InputAction) -> String {
        let titles: [InputAction: String] = [
            .forward: "Forward", .back: "Back", .left: "Left", .right: "Right",
            .jump: "Jump", .crouch: "Crouch", .sprint: "Sprint", .brace: "Brace",
        ]
        return titles[action] ?? action.name
    }
    private var menu: SettingsMenu?

    /// The game's own exposure, before the player's brightness. **The game's dial**: ACES lifts
    /// midtones by about a fifth, and half a stop down puts a scene authored before there was a curve
    /// back where it was.
    private static let baseExposure: Float = -0.5

    /// Keys this game takes before `InputState` sees them, whatever it is doing — so they cannot be
    /// bound to anything, or the binding would never fire. Tab and Escape are refused by the engine.
    private static let reservedKeys: Set<KeyCode> = [.p, .r, .n, .m, .o]

    // MARK: - Particles

    /// Embers, a burst for a collected crate, and dust when the player lands.
    ///
    /// **The sample's three recipes, and they are the sample's.** The engine has no idea what an ember
    /// is; it knows what a recipe is. Two of these glow and one does not, which is the point of having
    /// three: one blend has to serve light and matter both.
    private static let emberRecipe = 0, pickupRecipe = 1, dustRecipe = 2
    private var particles = ParticleSystem(recipes: [
        // **Rising, not falling** — gravity is per recipe, and heat lifts an ember. Well above 1 in
        // colour so it reads as hot, and tiny, because a spark the size of a coin is a firefly.
        ParticleRecipe(count: 1, speed: 0.9, spread: 0.35, lifetime: 1.6, size: 0.07,
                       gravity: 1.4, drag: 0.9, color: SIMD3(5.0, 1.1, 0.12), fade: 1.5, glows: true),
        // The crate's own green, thrown outward and falling back: a moment, not a firework.
        ParticleRecipe(count: 48, speed: 4.5, spread: 2.2, lifetime: 0.9, size: 0.12,
                       gravity: -7, drag: 1.8, color: SIMD3(0.5, 5.0, 2.2), glows: true),
        // **Matter**: it covers what is behind it, spreads as it thins, and does not glow.
        ParticleRecipe(count: 14, speed: 0.6, spread: 1.4, lifetime: 0.9, size: 0.35, growth: 1.8,
                       gravity: -1, drag: 3, color: SIMD3(0.50, 0.46, 0.40), opacity: 0.45, fade: 2),
    ], capacity: SampleGame.particleCapacity)
    /// **One number for the pool and what draws it**: a renderer smaller than its system leaves live
    /// particles undrawn.
    private static let particleCapacity = 1024
    private let particleRenderer: ParticleRenderer?
    /// Where a stream of embers comes from.
    private enum EmberSource {
        /// A fixed point — the coals of a brazier the level placed.
        case point(SIMD3<Float>)
        /// A light, by index into `lightSet.lights` — a lantern, which moves, so the embers follow
        /// the light because the light follows the hand.
        case light(Int)
    }
    private var emberEmitters: [(source: EmberSource, emitter: ParticleEmitter)] = []

    /// **How brightly a mesh's emissive map glows**, by the mesh's name.
    ///
    /// A file connecting `emissiveColor` to a texture has no scalar, so the map arrives at 1 — lit
    /// coals as bright as white paper. **The game owns the strength**, as it owns a collected crate's,
    /// and it lives in a table rather than in a check for one name so the next glowing thing is a line.
    private static let glowStrength: [String: Float] = ["brazier": 2.5]

    /// **Which meshes are round** — collided as the disc inside their box, not the box. A box cannot
    /// say it holds a circle, so the game that made the mesh says it. The turntable's square let a body
    /// step up onto air 0.83 m past its rim.
    private static let roundMeshes: Set<String> = ["turntable"]

    /// A solid's plan: its disc if its mesh is round, else its turned rectangle.
    private func footprint(of volume: Volume, mesh: String) -> CharacterController.Surroundings.Footprint? {
        SampleGame.roundMeshes.contains(mesh) ? .init(discOf: volume) : .init(of: volume)
    }
    /// Drawable index to its glow strength, rebuilt with the level.
    private var glowingDrawables: [Int: Float] = [:]

    /// Where a brazier's coals are, above its origin: just under the rim of `brazier.usda`. Embers
    /// come off the coals, not off the light the level placed above them.
    private static let brazierCoals: Float = 1.0
    /// Steps taken since launch. **The seed for anything a step throws**, which is what keeps a
    /// scripted walk's dust landing the same way every time.
    private var stepCount = 0

    // MARK: - Something in a hand

    /// The lanterns the figures carry.
    ///
    /// **The canonical use of a hierarchy, and the one the engine's own notes named**: a thing hung
    /// off a joint, of a pose, of an object. One node per figure, each attached externally, so the
    /// only thing that changes per frame is the array of hands.
    private var lanterns: TransformHierarchy?
    /// Where each lantern sits in `drawables` — and therefore in `volumes`, which is the same order.
    private var lanternDrawables: [Int] = []
    /// Where each lantern's light sits in `lightSet.lights`.
    private var lanternLights: [Int] = []
    /// Which joint they hang off in whatever rig actually loaded.
    private var lanternJoint: Int?
    /// How many of `volumes` came from the level, before the lanterns were appended.
    private var levelVolumeCount: Int { volumes.count - lanternDrawables.count }

    /// A 16 cm box, held just off the joint it hangs from.
    ///
    /// **In the joint's frame, not the world's, which is what makes this a grip rather than a
    /// follow.** The offset turns with the joint, so the lantern tips as the arm does; a version that
    /// merely copied the hand's *position* would stay upright and read as a balloon on a string.
    ///
    /// > **The offset is small, and picking it took several attempts.** The bind pose puts this joint
    /// > 48 cm out along the arm and the arm mesh reaches 74, so 26 cm along the joint's +X reads as
    /// > "the hand" — and with the arm down it is exactly that, verified by looking. **Raised, it is
    /// > not:** the drawn limb stops a hand's length short of where that arithmetic says the hand
    /// > went, and the lantern floats above the figure's head.
    /// >
    /// > **A joint's frame is where the rig says the joint is. It is not a promise about where the
    /// > mesh got drawn**, and the gap between the two is the asset's business rather than the
    /// > engine's. A rig with a real hand joint would not have the question; this one ends at a
    /// > forearm, so the grip is a number set by looking — which is what an attachment point in a
    /// > tool is for, and this sample has no tool.
    private static let lanternGrip: matrix_float4x4 = {
        let size: Float = 0.16
        return matrix_float4x4(columns: (SIMD4(size, 0, 0, 0),
                                         SIMD4(0, size, 0, 0),
                                         SIMD4(0, 0, size, 0),
                                         SIMD4(0.05, -0.09, 0, 1)))
    }()

    /// Cubes for the lamps that point nowhere. **Fewer of these than tiles, and deliberately** — six
    /// passes each is the cost, so the sample takes the engine's mean default rather than dressing
    /// it up.
    private let shadowCubes: ShadowCubes?
    /// Which point lights have a cube this frame.
    private var cubeCasters: [(lightIndex: Int, caster: ShadowCubes.Caster)] = []
    private let shadowPipeline: MTLRenderPipelineState?
    private let skinnedShadowPipeline: MTLRenderPipelineState?

    /// A courtyard seventy metres across, not a sniper range. **These are the sample's numbers, and
    /// that they are nothing like a long-range game's is exactly why `ShadowCascades` takes them as
    /// arguments.** `lightDepthRange` is 200 rather than the 1500 default for the same reason: it is
    /// how far along the light axis the recorded box reaches, and a courtyard needs a fraction of
    /// what a world kilometres deep does.
    private static let cascades = ShadowCascades(splits: [8, 22, 55, 120],
                                                 resolution: 1024,
                                                 lightDepthRange: 200)
    /// Frame-wide shadow data — written once a frame, not once per object.
    private let shadowFrameBuffer: MTLBuffer

    /// The level, and the editing on top of it. **The engine owns what an edit *means*** — see
    /// `LevelEditor`; this file only turns clicks and keys into those operations and draws the result.
    private var editor: LevelEditor
    /// **`WINDAGE_SAMPLE_EDITING=1` starts with the editor open** — for a recorded frame of its overlay, which is drawn
    /// before any step and so before any key could open it.
    private(set) var isEditing = ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_EDITING"] == "1"
    var isEditingLevel: Bool { isEditing }
    private var level: Level { editor.level }
    /// Which level is loaded. **`var`, and that is the whole point of this pass** — everything about
    /// this game assumed one level, loaded once, because there had only ever been one.
    private var levelIndex = 0

    /// This sample's ground: a plane at zero. What anchors resolve against and carried lights are
    /// placed on.
    private static let ground = Level.Ground(height: { _, _ in 0 })

    /// Where the placements' lamps were at the last rebuild, so the log can say when one moved.
    private var lastCarriedLights: [SIMD3<Float>] = []

    /// The loops playing for the level's carried sounds: what, where, for which placement.
    private var soundLoops: [(placement: Int, name: String, position: SIMD3<Float>, loop: AudioEngine.Loop)] = []

    /// **Reconciled, not restarted**: a rebuild happens on every edit and every crate collected, and a
    /// loop stopped and started each time is a fire that hiccups whenever anything else happens.
    ///
    /// **Matched by what and where first, and by placement only for one that moved.** Placements have
    /// no identity but their index, and an index is not stable: copying a brazier inserts a placement,
    /// and every one after it moves up by one. Keyed by index alone — the first version — the *other*
    /// brazier's loop was stopped and restarted by an edit to this one.
    private func syncSoundLoops() {
        guard let audio else { return }
        let wanted = level.carriedSounds(on: SampleGame.ground)
        var unclaimed = soundLoops
        var kept: [(placement: Int, name: String, position: SIMD3<Float>, loop: AudioEngine.Loop)] = []
        var waiting: [Level.CarriedSoundInWorld] = []
        // Untouched: the same sound in the same place, whatever its placement is numbered now.
        for sound in wanted {
            if let i = unclaimed.firstIndex(where: { $0.name == sound.name && simd_distance($0.position, sound.position) < 1e-4 }) {
                kept.append((sound.placement, sound.name, sound.position, unclaimed.remove(at: i).loop))
            } else {
                waiting.append(sound)
            }
        }
        // Moved: the same placement, somewhere new.
        var changed = false
        for sound in waiting {
            if let i = unclaimed.firstIndex(where: { $0.placement == sound.placement && $0.name == sound.name }) {
                let loop = unclaimed.remove(at: i).loop
                audio.moveLoop(loop, to: sound.position)
                kept.append((sound.placement, sound.name, sound.position, loop))
            } else if let loop = audio.startLoop(sound.name, at: sound.position, volume: sound.volume) {
                kept.append((sound.placement, sound.name, sound.position, loop))
                soundLoopStarts += 1
                changed = true
            }
        }
        for gone in unclaimed { audio.stopLoop(gone.loop); changed = true }
        soundLoops = kept
        let positions = wanted.map(\.position)
        if changed || positions != lastSoundPositions {
            print("WindageSample: \(audio.loopCount) sounds looping (\(soundLoopStarts) started so far) — "
                  + wanted.map { String(format: "%@ at (%.2f, %.2f, %.2f)", $0.name, $0.position.x, $0.position.y, $0.position.z) }
                    .joined(separator: ", "))
            lastSoundPositions = positions
        }
    }

    /// How many loops have ever been started — so a log can show that an edit restarted nothing.
    private var soundLoopStarts = 0
    private var lastSoundPositions: [SIMD3<Float>] = []

    /// See `WINDAGE_SAMPLE_MEASURE_AUDIO` in main.swift. **The sample's own crackle, through the
    /// engine's own loop path**, with the listener facing it so both ears hear it alike.
    static func measureCrackle() {
        let audio: AudioEngine
        do {
            audio = try AudioEngine(offlineSampleRate: 44_100)
            try audio.load("crackle", bundle: .module)
            try audio.load("step_stone_0", bundle: .module)
        } catch {
            print("WindageSample: could not make an offline audio engine — \(error)")
            return
        }
        audio.updateListener(position: .zero, forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        func rms(_ seconds: Float) -> Float {
            let all = (audio.renderOffline(seconds: seconds) ?? []).flatMap { $0 }
            return (all.reduce(0) { $0 + $1 * $1 } / Float(max(all.count, 1))).squareRoot()
        }
        func dB(_ level: Float) -> Float { 20 * log10(max(level, 1e-9)) }
        /// The crackle at a distance: settled, then two whole loops.
        func crackle(at metres: Float) -> Float {
            guard let loop = audio.startLoop("crackle", at: SIMD3(0, 0, -metres)) else { return 0 }
            _ = rms(0.3)
            let level = rms(6)
            audio.stopLoop(loop)
            _ = rms(0.2)
            return level
        }
        /// A footstep the way the game plays one — to the player, at a walk's volume — over its length.
        func footstep() -> Float {
            audio.play("step_stone_0", volume: 0.55)
            let level = rms(0.14)
            _ = rms(0.3)
            return level
        }

        let reference = crackle(at: 2)
        for metres: Float in [1, 2, 4, 8, 20] {
            let level = crackle(at: metres)
            print(String(format: "WindageSample: crackle at %4.0f m — RMS %.4f (%.1f dBFS), %.3f of its level at 2 m",
                         metres, level, dB(level), level / max(reference, 1e-9)))
        }
        // **The ambience setting, measured the same way**: the fire at 2 m should fall 6 dB at half, and a
        // footstep — which is not ambience — should not move.
        for ambience: Float in [1, 0.5] {
            audio.loopVolume = ambience
            print(String(format: "WindageSample: ambience %3.0f%% — crackle at 2 m %.2f dBFS, a walking footstep %.2f dBFS",
                         ambience * 100, dB(crackle(at: 2)), dB(footstep())))
        }
    }

    /// **Two environment overrides, and they exist so a picture can be taken twice.**
    ///
    /// Judging a rendering change means comparing two frames, and two frames are only comparable if
    /// they are the *same* frame — which a sample that always opens on level one at the spawn point,
    /// and is then walked to the interesting corner by hand, cannot give you. Everything this sample
    /// has that is worth photographing was found by comparing a before against an after.
    ///
    /// - `WINDAGE_SAMPLE_LEVEL=1` — open on that level rather than the first.
    /// - `WINDAGE_SAMPLE_SILENT=1` — no audio engine at all, so App Nap can be measured without the
    ///   exemption macOS gives an app playing sound (the sample run as a bundled app).
    /// - `WINDAGE_SAMPLE_CAMERA=x,y,z,yaw,pitch` — stand there instead of at the spawn. Angles in
    ///   degrees, because they are numbers a person types.
    ///
    /// **Placing the camera this way makes it fly.** A screenshot position is a viewpoint, not
    /// somewhere to stand: with a body under it, gravity would have pulled a raised camera to the
    /// ground before the first frame was drawn, and the picture would be of the floor.
    /// A walk read from `WINDAGE_SAMPLE_WALK`, played back in place of the keyboard.
    ///
    /// **The same argument as the two overrides above, for movement.** A character controller is
    /// judged by walking it somewhere, and "I walked up the steps and it felt right" is not
    /// something anybody else can repeat. A script is: the same keys for the same seconds from the
    /// same spawn reach the same place, and the log says where that was.
    ///
    /// `WINDAGE_SAMPLE_WALK="d:0.75 w:1.6 w+space:0.1"` — segments of key names and seconds, joined
    /// with `+`: any name `KeyCode(named:)` knows, `shift` included, or `wait` for none. **Held for
    /// the segment and released at its end, through `keyPressed`** — the game's keys, the settings
    /// screen and the bindings all see them exactly as they would a keyboard's. `yaw:90` and
    /// `pitch:-40` turn the view to that many degrees, taking no time. Each segment's end is printed with where the feet are,
    /// the highest they got during it, and whether they are on the ground.
    private var scriptedWalk = ScriptedWalk(ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_WALK"])

    private static var startingLevel: Int {
        guard let value = ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_LEVEL"],
              let index = Int(value) else { return 0 }
        return min(max(index, 0), SampleLevel.names.count - 1)
    }

    private static var startingCamera: Camera? {
        guard let value = ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_CAMERA"] else { return nil }
        let parts = value.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 5 else {
            print("WindageSample: WINDAGE_SAMPLE_CAMERA wants x,y,z,yaw,pitch — ignoring '\(value)'")
            return nil
        }
        return Camera(position: SIMD3(parts[0], parts[1], parts[2]),
                      yaw: Float.radians(fromDegrees: parts[3]),
                      pitch: Float.radians(fromDegrees: parts[4]))
    }
    private var levelURL: URL { SampleLevel.writableURL(levelIndex, in: SampleGame.levelDirectory) }
    private var levelPath: String

    /// The player's body. **The camera sits at its eye and no longer moves the player itself** —
    /// `Camera.advance` flies along the look direction, which is right for a photo mode and wrong
    /// for somebody with feet.
    private var body: CharacterController
    /// What the body stands on and walks into. **Rebuilt with the level**, from the same `solid` tag
    /// the level file already carried — in edit mode that is every change.
    private var surroundings = CharacterController.Surroundings()
    /// Whether the camera flies instead of walking. Set by `WINDAGE_SAMPLE_CAMERA`; see
    /// `startingCamera` for why a screenshot position cannot be somewhere to stand.
    private let isPhotoMode: Bool
    private var meshes: [String: LoadedMesh] = [:]
    /// Resolved from the level — anchors against this game's ground, which is simply y = 0.
    /// **Rebuilt whenever the level changes**, because in edit mode it changes constantly.
    /// **The base-colour maps travel with the drawable, not looked up by index.** `drawables` skips
    /// any placement whose mesh failed to load, so its indices are not the level's — reaching back
    /// into `level.placements` by the same index draws one object with another's texture, and only
    /// once something fails to load.
    private var drawables: [(mesh: LoadedMesh,
                             transform: matrix_float4x4,
                             albedo: SIMD3<Float>,
                             maps: [MTLTexture],
                             normals: [MTLTexture],
                             orm: [MTLTexture],
                             glow: [MTLTexture])] = []

    /// What the player cannot walk through, and what a click can pick.
    ///
    /// **Both from the same list, on purpose.** Two descriptions of "what is there" drift, and the
    /// day they do you are pointing at something you cannot touch.
    private var volumes: [Volume] = []

    /// The level's lifts — placements tagged `"lift"` — as rebuilt: which drawable each is (the same
    /// index in `volumes`), which solid if it is one, and where the level put it.
    private var lifts: [(drawable: Int, solid: Int?, base: matrix_float4x4)] = []
    /// The level's sliders — placements tagged `"slider"` — as the lifts are: drawable, solid, where
    /// the level put it. They go back and forth along their facing (`SampleLevel.SlideRun`), pushing
    /// whoever stands in the way.
    ///
    /// **And pistons** — `"piston"` — which go the same way but do not ease (`SampleLevel.pistonOffset`).
    /// Both go along their own facing: the placement's yaw turns the way they run.
    private var sliders: [(drawable: Int, solid: Int?, base: matrix_float4x4, facing: SIMD2<Float>, piston: Bool)] = []
    /// **The sliders' run, which a pinned player turns back** (`SampleLevel.SlideRun`) — kept here rather
    /// than with the rebuilt list, because collecting a crate rebuilds the level and must not send the
    /// slider home. A level's sliders move together.
    private var slideRun = SampleLevel.SlideRun()
    private var pistonClock: Float = 0, pistonOffset: Float = 0

    /// Moves every slider and piston a step along its run. **After the lifts**, which set every solid's
    /// `motion`; a mover's own are its own.
    private func advanceSliders(_ dt: Float) {
        guard !sliders.isEmpty else { return }
        let slideDelta = slideRun.advance(by: dt)
        pistonClock = (pistonClock + dt).truncatingRemainder(dividingBy: SampleLevel.pistonCycle)
        let piston = SampleLevel.pistonOffset(at: pistonClock)
        placeSliders(slide: slideRun.offset, slideDelta: slideDelta, piston: piston, pistonDelta: piston - pistonOffset)
        pistonOffset = piston
    }

    private func placeSliders(slide: Float, slideDelta: Float, piston: Float, pistonDelta: Float) {
        for slider in sliders {
            let offset = slider.facing * (slider.piston ? piston : slide)
            let delta = slider.facing * (slider.piston ? pistonDelta : slideDelta)
            var transform = slider.base
            transform.columns.3.x += offset.x
            transform.columns.3.z += offset.y
            drawables[slider.drawable].transform = transform
            volumes[slider.drawable].transform = transform
            if let solid = slider.solid {
                surroundings.solids[solid].bounds = volumes[slider.drawable].worldBounds
                surroundings.solids[solid].footprint = .init(of: volumes[slider.drawable])
                surroundings.solids[solid].motion = SIMD3(delta.x, 0, delta.y)
            }
        }
    }

    /// Where the feet last left the ground, for the report of where they came down.
    private var leftGroundAt: SIMD3<Float>?

    /// Where the feet were before the last step — so a report can say how fast the body went.
    private var previousFeet = SIMD3<Float>.zero

    /// The level's turntables — placements tagged `"turntable"`: drawable, solid, where the level put
    /// it, and its yaw there. They turn about their own origin, which is their centre.
    private var turntables: [(drawable: Int, solid: Int?, position: SIMD3<Float>, yaw: Float, scale: Float)] = []
    /// How far the turntables have turned since the level loaded, radians.
    private var turntableAngle: Float = 0

    /// Turns every turntable a step, and tells the body how far each solid turned and about where.
    /// **After the lifts**, which set every solid's `motion`; a turntable does not move, so it only sets
    /// its `turn`.
    private func advanceTurntables(_ dt: Float) {
        guard !turntables.isEmpty else { return }
        let step = SampleLevel.turntableRate * dt
        turntableAngle = (turntableAngle + step).truncatingRemainder(dividingBy: 2 * .pi)
        placeTurntables(turnedBy: step)
    }

    private func placeTurntables(turnedBy step: Float) {
        for index in surroundings.solids.indices { surroundings.solids[index].turn = nil }
        for table in turntables {
            let transform = Level.transform(yaw: table.yaw + turntableAngle, scale: table.scale, at: table.position)
            drawables[table.drawable].transform = transform
            volumes[table.drawable].transform = transform
            if let solid = table.solid {
                surroundings.solids[solid].bounds = volumes[table.drawable].worldBounds
                surroundings.solids[solid].footprint = footprint(of: volumes[table.drawable],
                                                                 mesh: level.placements[solidPlacements[solid]].mesh)
                surroundings.solids[solid].turn = .init(about: SIMD2(table.position.x, table.position.z), by: step)
            }
        }
    }

    /// Seconds into the lifts' cycle, and how high they stand above where the level put them.
    private var liftClock: Float = 0
    private var liftOffset: Float = 0

    /// Moves every lift a step along its cycle, and tells the body how far each solid went.
    private func advanceLifts(_ dt: Float) {
        guard !lifts.isEmpty else { return }
        let cycle = SampleLevel.liftCycle
        liftClock = (liftClock + dt).truncatingRemainder(dividingBy: cycle)
        let next = SampleLevel.liftHeight(at: liftClock)
        placeLifts(offset: next, delta: next - liftOffset)
        liftOffset = next
    }

    /// Puts the lifts at `offset` above where the level has them — the drawable, the volume and the
    /// solid the body stands on — and says each solid moved by `delta`.
    private func placeLifts(offset: Float, delta: Float) {
        for index in surroundings.solids.indices { surroundings.solids[index].motion = .zero }
        for lift in lifts {
            var transform = lift.base
            transform.columns.3.y += offset
            drawables[lift.drawable].transform = transform
            volumes[lift.drawable].transform = transform
            if let solid = lift.solid {
                surroundings.solids[solid].bounds = volumes[lift.drawable].worldBounds
                surroundings.solids[solid].footprint = .init(of: volumes[lift.drawable])
                surroundings.solids[solid].motion = SIMD3(0, delta, 0)
            }
        }
    }
    private var solidVolumes: [Volume] = []
    /// Which placement each of `solidVolumes` came from — so the controller's `groundSolid`, an
    /// index into the solids, can be asked what it is made of.
    private var solidPlacements: [Int] = []
    /// Placements already reported for naming no surface, so the log says it once.
    private var unnamedSurfaces = Set<Int>()
    /// Which drawables are objectives, so a collected one can go dark without searching the level.
    private var objectiveDrawables: [Int] = []

    /// The character mesh and the rig it wears — loaded once, shared by every figure in the level.
    ///
    /// **A `Skeleton` is structure, not pose**, so one of these serves any number of characters; what
    /// is per-character is the ``SkeletonPose`` inside each ``Figure``.
    /// **One store for the whole game, not one per mesh.** Every crate names the same file; loading
    /// it per mesh would decode, upload and mipmap it again and hold N copies on the GPU.
    private let textures: TextureStore?

    /// The sky, prefiltered: what surfaces reflect and what the player sees, from one source.
    ///
    /// **Rebuilt when the level changes**, because each level names its own sun and an environment
    /// lit from somewhere the sun is not is the kind of wrong that looks like a bug in the shading.
    private var environment: EnvironmentMap?
    private let skyPipeline: MTLRenderPipelineState?
    private let skyDepthState: MTLDepthStencilState?
    /// The base-colour and normal map for each of a mesh's submeshes, resolved once at load.
    private var baseColorMaps: [String: [MTLTexture]] = [:]
    private var normalMaps: [String: [MTLTexture]] = [:]
    private var emissiveMaps: [String: [MTLTexture]] = [:]
    /// Occlusion, roughness and metalness in one texture — R, G, B, which is glTF's packing.
    ///
    /// **Taken from the roughness slot, because all three name the same file.** A packed map is one
    /// file three slots point at, so `TextureStore` loads it once and any of the three would do.
    private var ormMaps: [String: [MTLTexture]] = [:]
    private var figureMaps: [MTLTexture] = []
    private var figureNormalMaps: [MTLTexture] = []
    private var figureORMMaps: [MTLTexture] = []
    private var figureEmissiveMaps: [MTLTexture] = []

    /// The up axis the figure's file declares. Identity for the built-in one, and not necessarily
    /// for a bought Z-up asset.
    private var figureOrientation: AssetOrientation = .identity

    /// Whether the figure came from `WINDAGE_SAMPLE_CHARACTER` rather than from the repository.
    private var usingExternalCharacter = false

    private var figureMesh: LoadedMesh?
    private var figureRig: Rig?
    private var figures: [Figure] = []

    private var run: SampleRun
    /// Seconds left on the pause between winning and the next level, or nil.
    private var advanceAfterWinning: Double?
    private var camera: Camera
    private var previousCamera: Camera
    private var aspectRatio: Float = 1
    private var viewportSize = SIMD2<Float>(1, 1)
    let input = InputState()

    /// Slots for uniforms: one per drawable per frame in flight, so a frame never overwrites one the
    /// GPU is still reading.
    /// Uniform slots per frame, and therefore the hard ceiling on things drawn.
    ///
    /// **Being over it silently drops the tail of the scene** — the same fault that once made
    /// a viewmodel disappear from the player's hands and read as a rendering bug. `rebuild()`
    /// says so out loud rather than leaving it to be discovered.
    private static let maxDrawables = 128
    private static let uniformStride = (MemoryLayout<Uniforms>.stride + 255) & ~255

    /// Figures take uniform slots after the level's drawables, in the same buffer.
    private static let maxFigures = 8
    /// One more for the debris, whose uniforms are written once for the whole batch.
    private static let uniformSlots = maxDrawables + maxFigures + 1
    private static var rubbleSlot: Int { maxDrawables + maxFigures }

    /// **A ceiling, not the rig's joint count.** The buffer is allocated before any rig is loaded,
    /// so it has to be sized for a plausible character rather than for the one that turns up. A
    /// hundred joints is a humanoid with fingers.
    /// How much brighter than white the figure's seams burn.
    private static let figureGlow: Float = 2.2

    private static let maxJoints = 128
    private static let jointPaletteStride =
        (MemoryLayout<matrix_float4x4>.stride * maxJoints + 255) & ~255
    private let jointBuffer: MTLBuffer

    init?(engine: FrameRenderer) {
        self.engine = engine
        let device = engine.device
        // **A scripted walk keeps time with its window hidden.** It is a check that has to finish —
        // and the player's own game is paused by hiding it, the engine's default.
        engine.runsWhileHidden = ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_WALK"] != nil

        levelIndex = SampleGame.startingLevel
        let loaded = SampleLevel.load(levelIndex, savedIn: SampleGame.levelDirectory)
        editor = LevelEditor(level: loaded.level)
        addKind = 0                                         // each level has its own kinds
        levelPath = loaded.report

        run = SampleRun(objectives: loaded.level.markers(ofKind: "objective").map(\.position),
                        levelName: loaded.level.name, store: SampleGame.progressStore)

        // Spawn where the level says, looking where it says.
        let spawn = loaded.level.markers(ofKind: "spawn").first
        var camera = Camera(position: (spawn?.position ?? SIMD3(0, 0, 12)) + SIMD3(0, 1.7, 0))
        camera.yaw = spawn?.yaw ?? 0
        camera.pitch = Float.radians(fromDegrees: Float(spawn?.values["pitch"] ?? 0))
        // **A viewpoint the environment can override**, so a screenshot is reproducible. See
        // `startingCamera`.
        if let placed = SampleGame.startingCamera { camera = placed }
        self.isPhotoMode = SampleGame.startingCamera != nil
        // Feet on the spawn marker. The camera starts at their eye unless a photo put it elsewhere.
        self.body = CharacterController(feet: spawn?.position ?? SIMD3(0, 0, 12))
        if !isPhotoMode { camera.position = body.eye }
        self.camera = camera
        self.previousCamera = camera

        let vertexDescriptor = SampleGame.vertexDescriptor()
        var sky: MTLRenderPipelineState?
        var instanced: MTLRenderPipelineState?

        let shaderLibrary: MTLLibrary
        do {
            shaderLibrary = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "SampleShaders")
        } catch {
            print("WindageSample: shader library failed — \(error)")
            return nil
        }

        do {
            let library = shaderLibrary
            let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())

            let vertexFunction = MTL4LibraryFunctionDescriptor()
            vertexFunction.library = library
            vertexFunction.name = "sampleVertex"
            let fragmentFunction = MTL4LibraryFunctionDescriptor()
            fragmentFunction.library = library
            fragmentFunction.name = "sampleFragment"

            let descriptor = MTL4RenderPipelineDescriptor()
            descriptor.label = "SamplePipeline"
            descriptor.vertexFunctionDescriptor = vertexFunction
            descriptor.fragmentFunctionDescriptor = fragmentFunction
            descriptor.vertexDescriptor = vertexDescriptor
            // **The scene target, not the drawable.** The scene is drawn into an HDR texture and
            // fitted to the display by the engine's tone map pass; a pipeline declaring the
            // drawable's format here would not match the attachment it is given.
            descriptor.colorAttachments[0].pixelFormat = FrameRenderer.sceneColorPixelFormat
                pipeline = try compiler.makeRenderPipelineState(descriptor: descriptor, compilerTaskOptions: nil)

            // The instanced pipeline differs only in its vertex function — same layout, same fragment
            // shader, so a piece of debris is lit and shadowed exactly as the crate it was cut from.
            let instancedVertex = MTL4LibraryFunctionDescriptor()
            instancedVertex.library = library
            instancedVertex.name = "sampleInstancedVertex"
            descriptor.label = "SampleInstancedPipeline"
            descriptor.vertexFunctionDescriptor = instancedVertex
            instanced = try? compiler.makeRenderPipelineState(descriptor: descriptor, compilerTaskOptions: nil)
            descriptor.vertexFunctionDescriptor = vertexFunction

            // The skinned pipeline differs only in its vertex function and its layout — same
            // fragment shader, so a character is lit and shadowed by exactly the code the rest of
            // the scene is. Two fragment shaders that are meant to match is how a character ends up
            // subtly the wrong brightness.
            let skinnedVertex = MTL4LibraryFunctionDescriptor()
            skinnedVertex.library = library
            skinnedVertex.name = "sampleSkinnedVertex"
            descriptor.label = "SampleSkinnedPipeline"
            descriptor.vertexFunctionDescriptor = skinnedVertex
            descriptor.vertexDescriptor = SampleGame.skinnedVertexDescriptor()
            skinnedPipeline = try compiler.makeRenderPipelineState(descriptor: descriptor,
                                                                   compilerTaskOptions: nil)

            let skyVertex = MTL4LibraryFunctionDescriptor()
            skyVertex.library = library
            skyVertex.name = "sampleSkyVertex"
            let skyFragment = MTL4LibraryFunctionDescriptor()
            skyFragment.library = library
            skyFragment.name = "sampleSkyFragment"
            descriptor.label = "SampleSkyPipeline"
            descriptor.vertexFunctionDescriptor = skyVertex
            descriptor.fragmentFunctionDescriptor = skyFragment
            // **No vertex descriptor**: the sky is a full-screen triangle built from its vertex id.
            descriptor.vertexDescriptor = nil
            sky = try compiler.makeRenderPipelineState(descriptor: descriptor, compilerTaskOptions: nil)
        } catch {
            print("WindageSample: pipeline failed — \(error)")
            return nil
        }

        guard let depthState = engine.makeDepthStencilState() else {
            print("WindageSample: depth state failed")
            return nil
        }
        self.depthState = depthState
        skyPipeline = sky
        instancedPipeline = instanced
        rubbleBuffer = InstanceBuffer(renderer: engine)

        // **The sky writes no depth and tests none.** It is drawn first and everything else covers
        // it; writing depth would put the far plane in front of the scene, and testing it would need
        // a cleared buffer the engine has only just handed over.
        let skyDepth = MTLDepthStencilDescriptor()
        skyDepth.depthCompareFunction = .always
        skyDepth.isDepthWriteEnabled = false
        skyDepthState = device.makeDepthStencilState(descriptor: skyDepth)

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        // 0: vertices · 1: per-object uniforms · 2: frame data · 3: joints
        // 4: every light in the scene · 5: cluster ranges · 6: cluster light indices · 7: instance transforms.
        tableDescriptor.maxBufferBindCount = 8
        // 0: cascades · 1: base colour · 2: normal · 3: environment · 4: irradiance · 5: ORM
        // 6: glow · 7: the lamps' shadow atlas.
        tableDescriptor.maxTextureBindCount = 9
        guard let table = try? device.makeArgumentTable(descriptor: tableDescriptor) else {
            print("WindageSample: argument table failed")
            return nil
        }
        argumentTable = table

        guard let buffer = device.makeBuffer(
            length: SampleGame.uniformStride * SampleGame.uniformSlots * FrameRenderer.maxFramesInFlight,
            options: .storageModeShared) else {
            print("WindageSample: uniform buffer failed")
            return nil
        }
        uniformBuffer = buffer

        // One palette per figure per frame in flight — **per frame in flight**, because the GPU is
        // still reading the previous frame's pose while this one is written. Sharing one palette
        // across frames is the animation version of tearing.
        guard let joints = device.makeBuffer(
            length: SampleGame.jointPaletteStride * SampleGame.maxFigures * FrameRenderer.maxFramesInFlight,
            options: .storageModeShared) else {
            print("WindageSample: joint palette buffer failed")
            return nil
        }
        joints.label = "Joint Palettes"
        jointBuffer = joints

        // Per frame in flight, like everything else the GPU reads while the CPU writes the next one.
        guard let sceneLights = device.makeBuffer(
                length: SampleGame.sceneLightStride * SampleGame.maxSceneLights
                      * FrameRenderer.maxFramesInFlight, options: .storageModeShared),
              let clusterRanges = device.makeBuffer(
                length: SampleGame.clusterRangeStride * SampleGame.clusterGrid.clusterCount
                      * FrameRenderer.maxFramesInFlight, options: .storageModeShared),
              let clusterIndices = device.makeBuffer(
                length: MemoryLayout<UInt32>.stride * SampleGame.maxClusterIndices
                      * FrameRenderer.maxFramesInFlight, options: .storageModeShared) else {
            print("WindageSample: cluster buffers failed")
            return nil
        }
        sceneLights.label = "Scene Lights"
        clusterRanges.label = "Cluster Ranges"
        clusterIndices.label = "Cluster Light Indices"
        sceneLightBuffer = sceneLights
        clusterRangeBuffer = clusterRanges
        clusterIndexBuffer = clusterIndices

        guard let shadowFrames = device.makeBuffer(
            length: SampleGame.shadowFrameStride * FrameRenderer.maxFramesInFlight,
            options: .storageModeShared) else {
            print("WindageSample: shadow frame buffer failed")
            return nil
        }
        shadowFrameBuffer = shadowFrames

        do {
            textures = try TextureStore(device: device)
        } catch {
            textures = nil
            print("WindageSample: no texture store — surfaces will be flat colours (\(error))")
        }

        do {
            shadowMap = try ShadowMap(device: device, cascades: SampleGame.cascades)
        } catch {
            shadowMap = nil
            print("WindageSample: no shadow map (\(error))")
        }
        do {
            shadowAtlas = try ShadowAtlas(device: device, resolution: 2048, tilesPerSide: 4)
        } catch {
            shadowAtlas = nil
            print("WindageSample: no shadow atlas — lamps will reach through walls (\(error))")
        }
        // **Four rather than the engine's two.** The ruins holds two braziers and the figures carry
        // lanterns, which is exactly the "a level should be choosing" case the default is mean about
        // — so the sample chooses, out loud, instead of inheriting a number.
        // **Six smaller cubes rather than two large ones.** The ruins holds two braziers and three
        // carried lanterns, which is exactly the "a level should be choosing" case the engine's
        // default is mean about — so the sample chooses, out loud, and pays for it in resolution
        // rather than in lamps that do not cast. Six faces at 384² is 21 MB.
        do {
            shadowCubes = try ShadowCubes(device: device, resolution: 384, slotCount: 6)
        } catch {
            shadowCubes = nil
            print("WindageSample: no shadow cubes — point lights will reach through walls (\(error))")
        }
        do {
            particleRenderer = try ParticleRenderer(device: device, capacity: SampleGame.particleCapacity)
        } catch {
            particleRenderer = nil
            print("WindageSample: no particle renderer — nothing will spark (\(error))")
        }

        // **Two pipelines, because a skinned mesh has a different vertex layout.** Everything else
        // about a shadow pass — depth only, no colour attachment, one raster sample, the matching
        // depth format — comes from `ShadowMap.pipelineDescriptor`, which is the set of things that
        // have to be right and none of which is obvious.
        var shadow: MTLRenderPipelineState?
        var skinnedShadow: MTLRenderPipelineState?
        var instancedShadow: MTLRenderPipelineState?
        if shadowMap != nil {
            do {
                let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())

                let staticFunction = MTL4LibraryFunctionDescriptor()
                staticFunction.library = shaderLibrary
                staticFunction.name = "sampleShadowVertex"
                shadow = try compiler.makeRenderPipelineState(
                    descriptor: ShadowMap.pipelineDescriptor(vertexFunction: staticFunction,
                                                             vertexDescriptor: vertexDescriptor,
                                                             label: "SampleShadow"))

                let instancedFunction = MTL4LibraryFunctionDescriptor()
                instancedFunction.library = shaderLibrary
                instancedFunction.name = "sampleInstancedShadowVertex"
                instancedShadow = try? compiler.makeRenderPipelineState(
                    descriptor: ShadowMap.pipelineDescriptor(vertexFunction: instancedFunction,
                                                             vertexDescriptor: vertexDescriptor,
                                                             label: "SampleInstancedShadow"))

                let skinnedFunction = MTL4LibraryFunctionDescriptor()
                skinnedFunction.library = shaderLibrary
                skinnedFunction.name = "sampleSkinnedShadowVertex"
                skinnedShadow = try compiler.makeRenderPipelineState(
                    descriptor: ShadowMap.pipelineDescriptor(
                        vertexFunction: skinnedFunction,
                        vertexDescriptor: SampleGame.skinnedVertexDescriptor(),
                        label: "SampleSkinnedShadow"))
            } catch {
                print("WindageSample: shadow pipelines failed — \(error)")
            }
        }
        shadowPipeline = shadow
        skinnedShadowPipeline = skinnedShadow
        instancedShadowPipeline = instancedShadow
        if shadowMap == nil || shadowPipeline == nil {
            print("WindageSample: no shadows — the scene will be flat-lit")
        }

        // **The hint lines use keyboard symbols, so the atlas has to carry them.** It is ASCII by
        // default, and a character it does not carry draws nothing at all — which is how these
        // hints spent several sessions reading "S save  Z undo" with the ⌘ silently missing.
        do {
            hud = try HUDRenderer(device: device, additionalCharacters: ["⌘", "⌫", "·", "°", "•", "—"])
        } catch {
            hud = nil
            print("WindageSample: no HUD — \(error)")
        }

        // **`WINDAGE_SAMPLE_SILENT=1` runs with no audio engine at all** — not muted, absent. macOS
        // exempts an app playing sound from App Nap, and a running `AVAudioEngine` is playing sound
        // whether or not anything is audible, so measuring whether a hidden game is napped needs the
        // sample without one: a game's worst case is the one with nothing playing.
        if ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_SILENT"] == nil && !SampleGame.isCheck {
            do {
                audio = try AudioEngine()
            } catch {
                audio = nil
                print("WindageSample: no audio — the game runs, it is just quiet — \(error)")
            }
        } else {
            audio = nil
            print("WindageSample: no audio — the game runs, it is just quiet")
        }
        if let audio {
            // **From this module's bundle, not `.main`.** For a SwiftPM executable `.main` is the
            // executable itself and holds no resources — the sounds live in the target's own bundle.
            let feet = SampleLevel.footstepSurfaces.flatMap { surface in
                (0..<3).map { "step_\(surface)_\($0)" } + ["land_\(surface)"]
            }
            for sound in ["pickup", "win", "lose", "crackle"] + feet {
                do { try audio.load(sound, bundle: .module) } catch { print("WindageSample: \(error)") }
            }
        }

        // **Everything the GPU reads has to be in the residency set.** A buffer or texture that is
        // not is read as whatever memory happens to be there — which is not a black screen, it is
        // garbage that looks like a shader bug.
        engine.residencySet.addAllocations([uniformBuffer, shadowFrameBuffer, jointBuffer,
                                            sceneLightBuffer, clusterRangeBuffer, clusterIndexBuffer])
        if let shadowMap { engine.residencySet.addAllocations(shadowMap.allocations) }
        if let shadowAtlas { engine.residencySet.addAllocations(shadowAtlas.allocations) }
        if let shadowCubes { engine.residencySet.addAllocations(shadowCubes.allocations) }
        if let particleRenderer { engine.residencySet.addAllocations(particleRenderer.allocations) }
        if let hud { engine.residencySet.addAllocations(hud.allocations) }

        // Meshes, then the level resolved against them.
        loadMissingMeshes()
        loadFigureAsset()
        rebuildEnvironment()
        engine.commitResidency()

        rebuild()
        print("WindageSample: '\(level.name)' — \(drawables.count) drawables from \(levelPath)")

        // **The player's settings, from last time.** Applied here rather than read at each use, so
        // the three things they reach — the bindings, the mixer and the exposure — are set once.
        engine.toneMapping = ToneMapping(curve: .aces, exposureStops: SampleGame.baseExposure)
        applySettings()
        // Controllers connecting and going away, from here on — the engine starts nothing on its own.
        input.start()
        print("WindageSample: settings from \(SampleGame.settingsStore.url.path) — forward "
              + "\(settings.bindings[.forward]?.name ?? ""), jump \(settings.bindings[.jump]?.name ?? ""), "
              + "pad jump \(settings.padBindings[.jump]?.rawValue ?? "")")
    }

    /// Loads the rigged figure: one mesh, one skeleton, two clips, all from one USD file.
    ///
    /// **Everything about the rig comes out of the file** — the joint hierarchy, the bind pose and
    /// both clips. Nothing about this figure is written into this game, which is the check that
    /// matters: a loader that only works on a rig the programmer already knows is not a loader.
    /// A character from outside the repository, when one is pointed at.
    ///
    /// **`WINDAGE_SAMPLE_CHARACTER=/path/to/RobotPlayer`** — a path with no extension. The sample
    /// loads `<path>.usdc` for the rig and mesh, every `<path>_*.usdc` beside it as a clip, and
    /// `<path>_ColorMap.png` as the base colour if it is there.
    ///
    /// ### Why an environment variable rather than an asset in the repository
    ///
    /// A real character is tens of megabytes and belongs to whoever made it; this repository is meant
    /// to build and run with nothing checked out beside it. But **loading one is the only way to find
    /// what a generated fixture cannot predict** — and probing one with a script, rather than running
    /// it, is exactly what produced the one wrong diagnosis this engine has had to correct. So: not
    /// shipped, and one variable away from being run.
    private func loadExternalCharacter() -> Bool {
        guard let base = ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_CHARACTER"],
              !base.isEmpty else { return false }

        let baseURL = URL(fileURLWithPath: base)
        let rigURL = baseURL.appendingPathExtension("usdc")
        guard FileManager.default.fileExists(atPath: rigURL.path) else {
            print("WindageSample: no character at \(rigURL.path)")
            return false
        }

        // Every sibling `<stem>_*.usdc` is a clip file. **Sorted, so the same two clips are picked
        // every run** — a directory listing is not ordered, and a demo that cross-fades into a
        // different animation each launch is not a demo of anything.
        let stem = baseURL.lastPathComponent
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: baseURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        let clipURLs = siblings
            .filter { $0.pathExtension == "usdc" && $0.deletingPathExtension().lastPathComponent != stem
                      && $0.lastPathComponent.hasPrefix(stem + "_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        do {
            figureRig = try RigLoader.load(url: rigURL, clipURLs: clipURLs) {
                print("WindageSample: character clips — \($0)")
            }
        } catch {
            print("WindageSample: character rig failed — \(error)")
            return false
        }

        guard let mesh = try? MeshLoader.load(url: rigURL, device: engine.device,
                                              vertexDescriptor: SampleGame.skinnedVertexDescriptor(),
                                              semantics: SampleGame.skinnedSemantics).first else {
            print("WindageSample: character mesh failed")
            figureRig = nil
            return false
        }
        figureMesh = mesh
        figureOrientation = AssetOrientation(asset: MDLAsset(url: rigURL))

        // **The material names no texture, and that is normal.** The tool builds the colour map in
        // memory, so there is no file for the exporter to reference; it is written beside the model
        // instead and bound by name.
        let colorMap = baseURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem)_ColorMap.png")
        if let textures, FileManager.default.fileExists(atPath: colorMap.path),
           let texture = try? textures.texture(.url(colorMap), isColor: true) {
            figureMaps = Array(repeating: texture, count: mesh.mesh.submeshes.count)
        } else {
            figureMaps = resolveBaseColorMaps(of: mesh, named: stem)
        }
        figureNormalMaps = resolveMaps(of: mesh, slot: .normal, named: stem)
        figureORMMaps = resolveMaps(of: mesh, slot: .roughness, named: stem)
        figureEmissiveMaps = resolveMaps(of: mesh, slot: .emissive, named: stem)

        engine.residencySet.addAllocations(mesh.mesh.vertexBuffers.map(\.buffer))
        engine.residencySet.addAllocations(mesh.mesh.submeshes.map(\.indexBuffer.buffer))
        if let textures { engine.residencySet.addAllocations(textures.allocations) }

        if let rig = figureRig {
            print("WindageSample: character '\(stem)' — \(rig.skeleton.jointCount) joints, "
                  + "\(mesh.mesh.vertexCount) vertices, \(figureOrientation.upAxis)-up, clips: "
                  + rig.clips.map(\.name).joined(separator: ", "))
            if rig.skeleton.jointCount > SampleGame.maxJoints {
                print("WindageSample: WARNING the rig has more joints than the palette holds")
                figureRig = nil
                return false
            }
        }
        usingExternalCharacter = figureRig != nil
        return usingExternalCharacter
    }

    private func loadFigureAsset() {
        guard skinnedPipeline != nil else { return }
        if loadExternalCharacter() { return }
        do {
            // **The rig from one file, the second animation from another.** That is how a character
            // exported one clip at a time arrives, and the clip file's own copy of the skeleton is
            // ignored — its rest pose is wherever the exporter left the rig, not the rig's.
            figureRig = try RigLoader.load(named: "figure", withExtension: "usda",
                                           clipFiles: ["figure-wave"], bundle: .module) {
                print("WindageSample: figure clips — \($0)")
            }
        } catch {
            print("WindageSample: no figure rig — \(error)")
            return
        }
        guard let mesh = try? MeshLoader.load(named: "figure", withExtension: "usda",
                                              device: engine.device,
                                              vertexDescriptor: SampleGame.skinnedVertexDescriptor(),
                                              semantics: SampleGame.skinnedSemantics,
                                              bundle: .module).first else {
            print("WindageSample: no figure mesh")
            figureRig = nil
            return
        }
        figureMesh = mesh
        figureMaps = resolveBaseColorMaps(of: mesh, named: "figure")
        figureNormalMaps = resolveMaps(of: mesh, slot: .normal, named: "figure")
        figureORMMaps = resolveMaps(of: mesh, slot: .roughness, named: "figure")
        figureEmissiveMaps = resolveMaps(of: mesh, slot: .emissive, named: "figure")
        engine.residencySet.addAllocations(mesh.mesh.vertexBuffers.map(\.buffer))
        engine.residencySet.addAllocations(mesh.mesh.submeshes.map(\.indexBuffer.buffer))
        if let textures { engine.residencySet.addAllocations(textures.allocations) }

        // **Honour the up axis the file declares.** This one says Y, so the correction is the
        // identity — but a USD out of a Blender or Unreal pipeline that did not pass through the
        // studio's own exporter says Z, and a consumer that never asks lays that character on its
        // side. Asking costs a matrix multiply at load.
        if let url = Bundle.module.url(forResource: "figure", withExtension: "usda") {
            figureOrientation = AssetOrientation(asset: MDLAsset(url: url))
            print("WindageSample: figure asset is \(figureOrientation.upAxis)-up")
        }

        if let rig = figureRig {
            print("WindageSample: figure rig — \(rig.skeleton.jointCount) joints, clips: "
                  + rig.clips.map(\.name).joined(separator: ", "))
            if rig.skeleton.jointCount > SampleGame.maxJoints {
                print("WindageSample: WARNING the rig has more joints than the palette holds")
                figureRig = nil
            }
        }
    }

    /// Places a figure wherever the level puts a `figure` marker.
    ///
    /// **From the level file, like everything else in the scene.** A character hard-coded into the
    /// game would not prove the level format can carry one, and moving it would mean a rebuild.
    private func rebuildFigures() {
        figures.removeAll(keepingCapacity: true)
        // **First and second clip, whatever they are called.** The built-in figure names them `Idle`
        // and `figure-wave`; an external character names them whatever its exporter did. Asking for a
        // name would work for one of those and silently produce a statue for the other — so the pair
        // is positional, and printed, because "which two is it blending" is otherwise a guess.
        guard let rig = figureRig, let idleClip = rig.clips.first else { return }
        let waveClip = rig.clips.count > 1 ? rig.clips[1] : idleClip
        if figures.isEmpty {
            print("WindageSample: figures blend '\(idleClip.name)' into '\(waveClip.name)'")
        }

        for marker in level.markers(ofKind: "figure").prefix(SampleGame.maxFigures) {
            let yaw = marker.yaw
            // **Plus a half turn for an external character, and this is the finding that was
            // predicted.** Which way an asset faces is not in the file: the built-in figure is
            // symmetric front to back, and a bought character has a definite front that its own
            // toolchain points wherever it likes. It is a per-asset yaw, applied where the thing is
            // placed — which is somewhere a game already has to think.
            let facing = yaw + (usingExternalCharacter ? .pi : 0)
            let fc = cos(facing), fs = sin(facing)
            let placement = matrix_float4x4(columns: (SIMD4(fc, 0, -fs, 0),
                                                     SIMD4(0, 1, 0, 0),
                                                     SIMD4(fs, 0, fc, 0),
                                                     SIMD4(marker.position, 1)))
            // **Two corrections, both inside the placement.** The file's declared up axis, and the
            // mesh's own place in the file's node hierarchy — which is where an exported character's
            // centimetre-to-metre scale lives. Either one outside the placement would scale or rotate
            // the marker's position too, and the figure would appear in the next county.
            let node = figureMesh?.nodeTransform ?? matrix_identity_float4x4
            let transform = placement * figureOrientation.transform * node
            var figure = Figure(pose: SkeletonPose(skeleton: rig.skeleton),
                                idle: AnimationPlayhead(clip: idleClip, skeleton: rig.skeleton),
                                wave: AnimationPlayhead(clip: waveClip, skeleton: rig.skeleton),
                                transform: transform,
                                position: marker.position)
            // **Started at different points in the clip.** A row of characters moving in lockstep
            // reads as one object drawn several times, which is exactly what it is.
            figure.idle.advance(by: Float(figures.count) * 0.9)
            figures.append(figure)
        }
    }

    /// Gives every figure something to carry.
    ///
    /// **The lanterns are ordinary drawables**, appended after the level's. That is not a shortcut —
    /// it is what makes the point: a thing placed by a hierarchy is drawn, shadowed, culled and lit
    /// by exactly the same code as a thing placed by a level file, because the hierarchy produces a
    /// world transform and nothing else.
    private func rebuildLanterns() {
        lanterns = nil
        lanternJoint = nil
        lanternDrawables.removeAll(keepingCapacity: true)
        guard !figures.isEmpty, let rig = figureRig, let mesh = meshes["box"] else { return }
        guard let joint = SampleGame.lanternJoint(in: rig.skeleton) else {
            print("WindageSample: no hand-shaped joint in this rig — nobody is carrying anything")
            return
        }
        lanternJoint = joint
        print("WindageSample: lanterns hang off '\(rig.skeleton.jointPaths[joint])'")

        for _ in figures.indices {
            drawables.append((mesh, matrix_identity_float4x4, SIMD3(repeating: 1),
                              baseColorMaps["box"] ?? [], normalMaps["box"] ?? [],
                              ormMaps["box"] ?? [], emissiveMaps["box"] ?? []))
            lanternDrawables.append(drawables.count - 1)
            // **Appended to `volumes` in the same breath**, because the two are index-aligned and the
            // shadow passes cull against `volumes`. A lantern missing from it would be drawn and cast
            // nothing, which reads as the cube being broken.
            volumes.append(Volume(localBounds: mesh.bounds, transform: matrix_identity_float4x4))
        }

        lanterns = try? TransformHierarchy(
            attachments: figures.indices.map { .external($0) },
            localTransforms: Array(repeating: SampleGame.lanternGrip, count: figures.count),
            externalCount: figures.count)
    }

    /// The joint a lantern hangs off, in whatever rig actually loaded.
    ///
    /// **The built-in figure's waving arm is its left one, and that is a fact about the clip rather
    /// than about rigs.** An external character names its joints whatever its own toolchain did, so
    /// the exact path is tried first and then a few shapes of name — and if none of them match, the
    /// figures carry nothing and say so, rather than hanging a lantern off a shin.
    private static func lanternJoint(in skeleton: Skeleton) -> Int? {
        if let index = skeleton.index(ofJoint: "root/spine/arm_l/forearm_l") { return index }
        func leaf(_ path: String) -> String {
            (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        }
        for shape in ["hand_l", "lefthand", "hand", "forearm_l", "forearm", "wrist"] {
            if let index = skeleton.jointPaths.firstIndex(where: { leaf($0).contains(shape) }) {
                return index
            }
        }
        return nil
    }

    /// Puts every lantern where its hand is, and its light with it.
    ///
    /// ### The scale, which is the whole finding
    ///
    /// **A child inherits its parent's scale, and a rig authored in centimetres hands its wrist a
    /// hundredfold one.** That factor belongs to the arm — the forearm genuinely is fifty units long
    /// in the rig's own space — and it is exactly wrong for something merely *hung* there: the
    /// lantern comes out at one percent of its size, in a position that is otherwise correct, which
    /// reads as the wrong mesh rather than as the wrong space.
    ///
    /// `withoutScale` at the call site rather than a flag inside the hierarchy, because this
    /// is a decision about *what is being attached*, and only the caller can see that.
    private func placeLanterns() {
        guard var rig = lanterns, let joint = lanternJoint, !lanternDrawables.isEmpty else { return }
        rig.refresh(attachedTo: figures.map {
            ($0.transform * $0.pose.modelTransform(ofJoint: joint)).withoutScale
        })
        for (slot, index) in lanternDrawables.enumerated() {
            let world = rig.worldTransform(of: slot)
            drawables[index].transform = world
            volumes[index].transform = world
            if slot < lanternLights.count, lanternLights[slot] < lightSet.lights.count {
                lightSet.lights[lanternLights[slot]].position = SIMD3(world.columns.3.x,
                                                                      world.columns.3.y,
                                                                      world.columns.3.z)
            }
        }
        lanterns = rig
        // **Every frame now, because a light that moves changes which cube it deserves** — and, more
        // to the point, a cube recorded from where the lamp was last is a shadow that lags the hand.
        cubeCasters = assignShadowCubes()
    }

    /// Prefilters the level's sky into the two cubes image-based lighting needs.
    ///
    /// **The sun here is the level's sun.** An environment lit from somewhere the sun is not reads as
    /// a bug in the shading rather than as a mismatched sky, so the two come from one place.
    private func rebuildEnvironment() {
        matterLight = level.resolvedSky.matterLight
        // **Nothing to reflect in, as a walk's check** — which draws no frame at all — and prefiltering
        // the sky is the slowest thing at start-up: 2.6 s of the 3.3 a walk waits before its first step.
        // A frame's check draws, so it builds the sky like anything else.
        guard !SampleGame.isCheck || SampleGame.frameWanted != nil else { return }
        let started = CFAbsoluteTimeGetCurrent()
        let built: EnvironmentMap
        do {
            built = try EnvironmentMap(device: engine.device, sky: level.resolvedSky)
        } catch {
            print("WindageSample: no environment — metal will have nothing to reflect (\(error))")
            return
        }
        if let previous = environment {
            engine.residencySet.removeAllocations(previous.allocations)
        }
        environment = built
        engine.residencySet.addAllocations(built.allocations)
        engine.commitResidency()
        print(String(format: "WindageSample: environment prefiltered in %.0f ms (%d mips)",
                     (CFAbsoluteTimeGetCurrent() - started) * 1000, built.specularMipCount))
    }

    /// Turn the level into things to draw, walk into and click on.
    ///
    /// The sample's ground is a plane at zero, so the anchor resolver has a trivial job — but it is
    /// still the *engine's* resolver, because what an anchor means is not this game's to reinvent.
    private func rebuild() {
        drawables.removeAll(keepingCapacity: true)
        volumes.removeAll(keepingCapacity: true)
        solidVolumes.removeAll(keepingCapacity: true)
        solidPlacements.removeAll(keepingCapacity: true)
        lifts.removeAll(keepingCapacity: true)
        sliders.removeAll(keepingCapacity: true)
        turntables.removeAll(keepingCapacity: true)
        objectiveDrawables.removeAll(keepingCapacity: true)
        glowingDrawables.removeAll(keepingCapacity: true)
        let ground = SampleGame.ground
        var buildings: [BoundingBox] = []
        for (placementIndex, placement) in level.placements.enumerated() {
            guard let mesh = meshes[placement.mesh] else { continue }
            // **The engine's placement transform, not one built here.** This file used to build the
            // matrix itself; so did a game, twice; and the engine's own bedding turned the other way
            // from all of them. `Level.transform(of:on:)` is the one definition now.
            //
            // **Times the mesh's node transform**, which is the identity for these hand-written OBJs
            // and would not be for anything exported. Composing it unconditionally is what stops a
            // level looking correct until the first asset that has one.
            let transform = level.transform(of: placement, on: ground) * mesh.nodeTransform
            drawables.append((mesh, transform, SampleGame.albedo(for: placement),
                              baseColorMaps[placement.mesh] ?? [],
                              normalMaps[placement.mesh] ?? [],
                              ormMaps[placement.mesh] ?? [],
                              emissiveMaps[placement.mesh] ?? []))
            if placement.tags.contains("objective") { objectiveDrawables.append(drawables.count - 1) }
            if let glow = SampleGame.glowStrength[placement.mesh] { glowingDrawables[drawables.count - 1] = glow }
            let volume = Volume(localBounds: mesh.bounds, transform: transform)
            volumes.append(volume)
            if !placement.tags.contains("ground") { buildings.append(volume.worldBounds) }
            // **The level's own tag decides.** The engine has no idea what "solid" means; this game
            // does. Shipping the tag and then ignoring it — which this sample did on its first
            // run — is worse than not having it, because the file says something untrue.
            if placement.tags.contains("solid") {
                solidVolumes.append(volume)
                solidPlacements.append(placementIndex)
            }
            if placement.tags.contains("turntable") {
                let at = level.transform(of: placement, on: ground).columns.3
                turntables.append((drawables.count - 1,
                                   placement.tags.contains("solid") ? solidVolumes.count - 1 : nil,
                                   SIMD3(at.x, at.y, at.z), placement.yaw, placement.scale))
            }
            if placement.tags.contains("lift") {
                lifts.append((drawables.count - 1,
                              placement.tags.contains("solid") ? solidVolumes.count - 1 : nil, transform))
            }
            if placement.tags.contains("slider") || placement.tags.contains("piston") {
                sliders.append((drawables.count - 1,
                                placement.tags.contains("solid") ? solidVolumes.count - 1 : nil, transform,
                                Level.turned(SIMD2(1, 0), by: placement.yaw), placement.tags.contains("piston")))
            }
        }
        // **The world box says how high each solid reaches; its footprint says where it stands.** With
        // the box alone a crate at 45° held the player up three quarters of a metre short of its face,
        // and let them slide along a wall of air. Every placement turns only about the vertical, so
        // every one has a footprint.
        surroundings = CharacterController.Surroundings(
            groundHeight: { _, _ in 0 },
            solids: zip(solidVolumes, solidPlacements).map {
                .init(bounds: $0.worldBounds, footprint: footprint(of: $0, mesh: level.placements[$1].mesh))
            })
        // A rebuild puts everything back where the level has it; the lifts go back to where they
        // had got to, without a jump for anyone riding one.
        placeLifts(offset: liftOffset, delta: 0)
        placeSliders(slide: slideRun.offset, slideDelta: 0, piston: pistonOffset, pistonDelta: 0)
        placeTurntables(turnedBy: 0)
        // Debris among the buildings, one batch of the box mesh — instanced, through the engine.
        rubble = InstanceBatches(SampleRubble.transforms(around: buildings).map { ("box", $0) })
        rebuildFigures()
        rebuildLanterns()
        rebuildLights()
        syncSoundLoops()
        placeLanterns()
        reportClustersNextFrame = true
        reportCubeDrawsNextFrame = true
        if drawables.count > SampleGame.maxDrawables {
            print("WindageSample: WARNING \(drawables.count) drawables against a cap of "
                  + "\(SampleGame.maxDrawables) — the rest of the level will not be drawn")
        }
    }

    /// The game's own tint, multiplied on top of the material.
    ///
    /// **It used to say what a thing *was* — earth for ground, ochre for a landmark — and now it says
    /// what a thing's *state* is.** That was not a preference: the moment surfaces carry textures,
    /// an identity tint multiplies the texture it was meant to replace, and a ground tint of 0.32
    /// takes an already-dark map down to a sixth of its brightness. Identity is the material's job
    /// now; the tint is left to the things a file cannot know — an objective that has been reached,
    /// and whatever is selected in the editor.
    private static func albedo(for placement: Level.Placement) -> SIMD3<Float> {
        SIMD3(repeating: 1)
    }

    /// **From the level's own sky.** This used to compute a direction from two `settings` keys, which
    /// meant the sun and the sky it belongs to were two separate facts that could disagree — and one
    /// of them was not in the file at all.
    private var sunDirection: SIMD3<Float> { level.resolvedSky.sunDirection }

    /// The level's lamps, plus whatever the game is lighting right now.
    ///
    /// **Rebuilt when the run changes, not every frame.** Selection is a sort over the level's lights
    /// per drawable, which is cheap — but rebuilding the *list* every frame would allocate for a set
    /// that changes only when a crate is collected.
    private var lightSet = LightSet()

    /// This frame's binning, rebuilt as the camera moves.
    private let sceneLightBuffer: MTLBuffer
    private let clusterRangeBuffer: MTLBuffer
    private let clusterIndexBuffer: MTLBuffer
    private static let sceneLightStride = MemoryLayout<PackedLight>.stride
    private static let clusterRangeStride = MemoryLayout<SIMD2<UInt32>>.stride

    /// Assembles the level's lamps and the ones the game owns.
    ///
    /// **An uncollected objective is a light as well as a glow.** Emission alone makes a crate look
    /// lit and leaves the ground beneath it dark, which is the tell that a glowing thing is a texture
    /// rather than a lamp. This is the sample's one dynamic light, and it goes out when the crate is
    /// taken.
    private func rebuildLights() {
        // **The level's lights and the ones its placements carry**, resolved through the placements'
        // own transforms — so a brazier moved in the editor takes its flame with it. They were two
        // separate entries in the file until 2026-09-11, and moving one left the other behind.
        var lights = level.resolvedLights(on: SampleGame.ground)
        let carried = level.carriedLights(on: SampleGame.ground).map(\.light.position)
        if carried != lastCarriedLights {
            if !lastCarriedLights.isEmpty {
                print("WindageSample: lamps carried by placements now at "
                      + carried.map { String(format: "(%.2f, %.2f, %.2f)", $0.x, $0.y, $0.z) }
                        .joined(separator: ", "))
            }
            lastCarriedLights = carried
        }
        for (slot, position) in run.objectives.enumerated() {
            let taken = run.collected.indices.contains(slot) && run.collected[slot]
            guard !taken else { continue }
            lights.append(PunctualLight(position: position + SIMD3(0, 0.6, 0),
                                        color: SIMD3(0.6, 6.0, 2.6), range: 4.5))
        }
        // **A lamp per lantern, seeded from where the lantern already is.** `rebuildLights` runs
        // again every time an objective is collected, and a light that spent one frame at the world
        // origin is a flash in the corner of the level nobody can explain afterwards.
        lanternLights.removeAll(keepingCapacity: true)
        for index in lanternDrawables {
            let at = drawables[index].transform.columns.3
            lanternLights.append(lights.count)
            lights.append(PunctualLight(position: SIMD3(at.x, at.y, at.z),
                                        color: SIMD3(1.0, 0.72, 0.42) * 26, range: 6.5))
        }

        // **The budget is only used for the report now.** Clustering removed the per-draw limit; what
        // is left is the warning that a level has crowded a point, which is still worth knowing.
        lightSet = LightSet(lights: lights, budget: 4)

        // **Embers off the braziers' coals and the lanterns** — off the things that burn, not off
        // the lights. They used to come off the level's coneless lights, which had nothing drawn at
        // them, so the embers rose out of thin air; the particles are what made that obvious.
        // Rebuilt whenever the lights are, which is every collected crate — so the seed base comes
        // from what the emitter is, and a brazier keeps throwing the same embers.
        let braziers = drawables.indices.filter { glowingDrawables[$0] != nil }.map { index -> EmberSource in
            let base = drawables[index].transform.columns.3
            return .point(SIMD3(base.x, base.y + SampleGame.brazierCoals, base.z))
        }
        emberEmitters = (braziers + lanternLights.map { EmberSource.light($0) }).enumerated().map { n, source in
            let rate: Float = if case .light = source { 6 } else { 14 }
            return (source, ParticleEmitter(recipe: SampleGame.emberRecipe, rate: rate, seedBase: n &* 104_729))
        }
        shadowCasters = assignShadowTiles()
        cubeCasters = assignShadowCubes()
        if lights.count > SampleGame.maxSceneLights {
            print("WindageSample: WARNING \(lights.count) lights against a buffer of "
                  + "\(SampleGame.maxSceneLights) — the rest will not be lit")
        }
    }

    /// Says out loud where this level has more lights than the budget can carry.
    ///
    /// **This is the probe's finding made operational.** A hard budget cannot promise a smooth
    /// hand-over in an arbitrary level; where no more than the budget are meaningfully lit, nothing
    /// visible is ever dropped. That is a condition on the level, and a condition nobody checks is a
    /// condition nobody meets — so the sample checks it at load, on the places a player actually goes.
    private func reportOverSubscription() {
        var points = run.objectives.map { $0 + SIMD3<Float>(0, 1.7, 0) }
        points += level.markers(ofKind: "spawn").map { $0.position + SIMD3(0, 1.7, 0) }
        let crowded = lightSet.overSubscribedPoints(among: points)
        guard !crowded.isEmpty else { return }
        print("WindageSample: \(crowded.count) of \(points.count) points are over-subscribed — "
              + "more than four lights are meaningfully lit there")
    }

    /// **A courtyard's numbers, not an engine's.** Sixteen by eight tiles is roughly square cells on
    /// a wide screen; twenty-four slices over a hundred and twenty metres is where the sample's lamps
    /// stop mattering.
    private static let clusterGrid = ClusterGrid(tilesX: 16, tilesY: 8, slices: 24,
                                                 nearPlane: 0.1, lightRange: 120)

    /// The most lights a level may hold at once, and the most cluster entries a frame may produce.
    /// **Ceilings on buffers rather than on what any one fragment sees** — that number is whatever
    /// the busiest cluster came out at, and clustering is what keeps it small.
    private static let maxSceneLights = 64
    private static let maxClusterIndices = 1 << 15

    /// The light the sun actually delivers — its radiance times the solid angle its disc subtends,
    /// which is a very small number and is why the two are not interchangeable.
    ///
    /// **An overcast level says so by having a dim sun and a bright sky**, which is a thing a level
    /// can now express and previously could not.
    private var sunIrradiance: SIMD3<Float> { level.resolvedSky.sunIrradiance }

    /// What lights dust under this level's sky. Computed once per level, since the sky is the
    /// level's — see `ProceduralSky.matterLight`.
    private var matterLight = SIMD3<Float>(repeating: 1)

    // MARK: - Levels

    /// Load a different level **while the game is running**.
    ///
    /// **Three things here were assumptions, not code, until there was a second level.** Meshes were
    /// loaded once in `init` from the first level's list, so a level using anything new drew nothing.
    /// The camera was placed in `init`, so a new spawn was ignored. And the run was sized once, so a
    /// level with a different number of objectives could not be finished. None of them would have
    /// been found by a second *copy* of the first level — only by one that differs.
    func load(level index: Int) {
        levelIndex = (index + SampleLevel.names.count) % SampleLevel.names.count
        let loaded = SampleLevel.load(levelIndex, savedIn: SampleGame.levelDirectory)
        editor = LevelEditor(level: loaded.level)
        levelPath = loaded.report

        loadMissingMeshes()
        rebuild()

        // Spawn where *this* level says, not where the last one did.
        let spawn = level.markers(ofKind: "spawn").first
        // Teleported, which drops everything the body was doing — last level's fall, crouch or slide has
        // no business arriving in this one — and keeps its tuning.
        body.teleport(to: spawn?.position ?? SIMD3(0, 0, 12))
        camera.position = body.eye
        camera.yaw = spawn?.yaw ?? 0
        camera.pitch = Float.radians(fromDegrees: Float(spawn?.values["pitch"] ?? 0))
        previousCamera = camera

        // A fresh run, sized from this level's objectives — and keeping the progress, which is the
        // player's rather than the level's.
        run = SampleRun(objectives: level.markers(ofKind: "objective").map(\.position),
                        levelName: level.name, store: SampleGame.progressStore)
        rebuildEnvironment()
        print("WindageSample: '\(level.name)' — \(drawables.count) drawables from \(levelPath)")
    }

    /// Loads any mesh this level needs that is not already in memory.
    ///
    /// **Additive rather than a reload.** Levels share most of their meshes, and throwing the lot away
    /// on every switch would stall for no reason — but a mesh has to be in the residency set before
    /// the GPU can reach it, so a newly loaded one joins it and the set is committed again.
    ///
    /// > **The one path for every level mesh, and there used to be two.** `init` loaded the first
    /// > level's meshes and resolved their textures; this loaded the next level's and **did not**. So
    /// > the ruins, reached the way a player reaches them — from the courtyard — had flat white pillars
    /// > and white steps. Every screenshot for a week had opened the ruins directly with
    /// > `WINDAGE_SAMPLE_LEVEL=1`, which went through `init`, and the override written to make pictures
    /// > repeatable was exactly what kept this one out of them.
    ///
    /// **OBJ first, then USD.** A level names a mesh without an extension. Emission is USD-only through
    /// Model I/O, so an object that glows — the brazier — cannot be an OBJ, and a loader that only
    /// looked for one would draw nothing where the level put it.
    private func loadMissingMeshes() {
        var added: [any MTLAllocation] = []
        for name in Set(level.placements.map(\.mesh)) where meshes[name] == nil {
            let found = ["obj", "usda"].lazy.compactMap { format in
                try? MeshLoader.load(named: name, withExtension: format, device: self.engine.device,
                                     vertexDescriptor: SampleGame.vertexDescriptor(),
                                     semantics: SampleGame.semantics, bundle: .module).first
            }.first
            guard let mesh = found else {
                print("WindageSample: no mesh named \(name)")
                continue
            }
            meshes[name] = mesh
            baseColorMaps[name] = resolveBaseColorMaps(of: mesh, named: name)
            normalMaps[name] = resolveMaps(of: mesh, slot: .normal, named: name)
            ormMaps[name] = resolveMaps(of: mesh, slot: .roughness, named: name)
            emissiveMaps[name] = resolveMaps(of: mesh, slot: .emissive, named: name)
            added += mesh.mesh.vertexBuffers.map(\.buffer)
            added += mesh.mesh.submeshes.map(\.indexBuffer.buffer)
        }
        if !added.isEmpty {
            engine.residencySet.addAllocations(added)
            // **Textures too, and this is easy to forget** — a texture the GPU cannot reach is not a
            // black surface, it is whatever memory happens to be there, and it reads as a shader bug.
            if let textures { engine.residencySet.addAllocations(textures.allocations) }
            engine.commitResidency()
        }
    }

    /// The base-colour map for every submesh of a mesh, in submesh order.
    ///
    /// **From the file's own material**, not assigned here — `box.obj` names `crate.png` through its
    /// `.mtl`, and the figure names `figure.png` through its `UsdPreviewSurface`. A game that wired
    /// textures up in code would leave the loader's whole reason for existing untested.
    private func resolveMaps(of mesh: LoadedMesh, slot: TextureSlot, named name: String) -> [MTLTexture] {
        guard let textures else { return [] }
        return (0..<mesh.mesh.submeshes.count).map { index in
            let material = mesh.material(forSubmesh: index)
            guard let source = material.textures[slot] else { return textures.fallback(for: slot) }
            do {
                // **`isColor` from the slot, never from the call site.** A normal map decoded as sRGB
                // has every value bent, and the result looks like bad lighting rather than like a
                // texture loaded wrongly.
                return try textures.texture(source, isColor: slot.isColor, bundle: .module)
            } catch {
                print("WindageSample: \(name) \(slot.rawValue) — \(error)")
                return textures.fallback(for: slot)
            }
        }
    }

    private func resolveBaseColorMaps(of mesh: LoadedMesh, named name: String) -> [MTLTexture] {
        resolveMaps(of: mesh, slot: .baseColor, named: name)
    }

    // MARK: - Editing

    /// Keys the editor takes, by macOS key code. Returns whether it consumed the event.
    ///
    /// **Consumed keys never reach `InputState`**, so `D` nudges rather than strafing. Routing every
    /// key to both and hoping they do not collide is how an editor ends up walking the camera into a
    /// wall while you are trying to move a crate.
    // MARK: - Keys in

    /// Draws one frame into `path` as a PNG, at the size a recorded frame is kept at, and says so.
    ///
    /// **Bottom-up and BGRA out of Metal**, top-down and RGBA into a bitmap: the rows are copied in
    /// reverse and the two colour channels swapped, which is the whole of the difference.
    func writeFrame(to path: String) -> Bool {
        let width = 640, height = 400
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: FrameRenderer.colorPixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = engine.device.makeTexture(descriptor: descriptor) else { return false }
        engine.residencySet.addAllocation(texture)
        engine.commitResidency()
        viewportSizeChanged(width: width, height: height)
        // **A frame of the splash is taken at its fullest.** It is drawn before any step, so its clock
        // reads zero and its fade has not begun — a picture of a ramp at an arbitrary point is a picture
        // of a number nobody chose. Run it to the middle of its hold instead.
        if var shown = splash {
            shown.advance(by: shown.fadeIn + shown.hold / 2)
            splash = shown
        }
        engine.render(into: texture)

        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        bgra.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: width * 4, bitsPerPixel: 32),
              let rgba = bitmap.bitmapData else { return false }
        for y in 0..<height {
            for x in 0..<width {
                let from = (y * width + x) * 4, to = (y * width + x) * 4
                rgba[to] = bgra[from + 2]
                rgba[to + 1] = bgra[from + 1]
                rgba[to + 2] = bgra[from]
                rgba[to + 3] = 255
            }
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("WindageSample: frame \(width)×\(height) written to \(path)")
            return true
        } catch {
            print("WindageSample: could not write \(path) — \(error)")
            return false
        }
    }

    /// Whether a scripted walk is playing — and so the real keyboard and mouse are not listened to.
    var isScripted: Bool { scriptedWalk?.isRunning == true }

    /// A key went down. **The game gets first refusal, then `InputState`** — a key the editor or the
    /// settings screen takes must not also walk the player.
    func keyPressed(_ key: KeyCode, command: Bool) {
        skipSplash()
        // Escape is the settings screen's first — it cancels a capture or closes the screen — and
        // otherwise the pointer's, which it releases. Never a binding: see `InputBindings.fixed`.
        if key == .escape {
            if !handleKey(key, command: false) { input.setMouseCaptured(false) }
            return
        }
        if handleKey(key, command: command) { return }
        input.keyDown(key)
    }

    func keyReleased(_ key: KeyCode) { input.keyUp(key) }

    /// A modifier changed — Shift, Control, Option, Command. **A key like any other once it gets
    /// here**, which is what lets the settings screen bind one and `InputState` sprint on one.
    func modifiersChanged(_ key: KeyCode, flags: NSEvent.ModifierFlags) {
        if menu != nil {
            // Captured on the way down; everything else a modifier does is swallowed while the
            // screen is open, or a held Shift would carry a sprint out of it.
            if key.isDown(inModifierFlags: flags), case .bind(let action) = menu?.capturing { bind(action, to: key) }
            if !key.isDown(inModifierFlags: flags) { input.flagsChanged(key: key, modifierFlags: flags) }
            return
        }
        input.flagsChanged(key: key, modifierFlags: flags)
    }

    func handleKey(_ key: KeyCode, command: Bool) -> Bool {
        if menu != nil { return handleMenuKey(key) }
        if key == .escape { return false }
        if key == .o && !isEditing { openMenu(); return true }
        if key == .tab {                                    // in and out of edit mode
            isEditing.toggle()
            input.setMouseCaptured(!isEditing)
            return true
        }
        // These work whether or not the editor is open, because a paused game you cannot unpause
        // is a hang with a label on it.
        switch key {
        case .p: run.togglePause(); return true
        case .r: if !command { run.restart(); return true }  // but ⌘R is redo
        case .n: load(level: levelIndex + 1); return true    // next level
        case .m: cycleToneMapping(); return true             // clamp, Reinhard, ACES
        default: break
        }

        guard isEditing else { return false }

        if command {
            switch key {
            case .s:                                         // save
                do {
                    try editor.save(to: levelURL)
                    print("WindageSample: saved \(levelURL.path)")
                } catch { print("WindageSample: save failed — \(error)") }
            case .z: editor.undo(); rebuild()
            case .r: editor.redo(); rebuild()
            case .delete:                                    // throw the edited copy away
                // **The way back to the level this repository ships.** Once the editor has saved,
                // that copy shadows the shipped file for ever, so editing `courtyard.json` in the
                // source tree appears to do nothing. Without this the only cure is knowing where
                // Application Support is.
                if SampleLevel.discardEdits(levelIndex, in: SampleGame.levelDirectory) {
                    print("WindageSample: discarded the edited copy")
                } else {
                    print("WindageSample: there was no edited copy to discard")
                }
                load(level: levelIndex)
            default: return false
            }
            return true
        }

        // Nudges are along the world axes rather than the camera's, so a number typed into the file
        // afterwards means the same thing as a key pressed here.
        let d = editor.configuration.nudge
        switch key {
        case .left: editor.move(by: SIMD3(-d, 0, 0))
        case .right: editor.move(by: SIMD3(d, 0, 0))
        case .up: editor.move(by: SIMD3(0, 0, -d))           // away, down the -z the camera faces
        case .down: editor.move(by: SIMD3(0, 0, d))
        case .q: editor.move(by: SIMD3(0, d, 0))             // up
        case .e: editor.move(by: SIMD3(0, -d, 0))            // down
        case .a: editor.rotate(by: -editor.configuration.turn)
        case .d: editor.rotate(by: editor.configuration.turn)
        case .minus: editor.scale(by: 1 / 1.25)
        case .equal: editor.scale(by: 1.25)
        case .delete, .forwardDelete: editor.delete()
        case .b: editor.duplicate()
        case .space: pickUnderCrosshair(); return true       // pick, for hands already on
                                                             // the keys and for automated checks
        // The selection's lamp: give or take away, hang it higher or lower, brighter or dimmer.
        case .l:                                             // lamp on / off
            guard let selected = editor.selected else { return true }
            editor.setLight(selected.light == nil ? newLamp(for: selected.mesh) : nil)
            reportLamp()
        case .rightBracket: editor.raiseLight(by: editor.configuration.lampRaise); reportLamp()
        case .leftBracket: editor.raiseLight(by: -editor.configuration.lampRaise); reportLamp()
        case .period: editor.brightenLight(by: editor.configuration.lampBrighten); reportLamp()
        case .comma: editor.brightenLight(by: 1 / editor.configuration.lampBrighten); reportLamp()
        // Adding: t steps through the kinds of thing this level already has, i drops one.
        case .t:                                             // the next kind to add
            let kinds = addableKinds
            guard !kinds.isEmpty else { return true }
            addKind = (addKind + 1) % kinds.count
            print("WindageSample: next to add is \(kindName(kinds[addKind]))")
            return true
        case .i: addUnderCrosshair()                         // insert it at the crosshair
        default: return false
        }
        rebuild()
        return true
    }

    /// Which of `addableKinds` the next **i** adds.
    private var addKind = 0

    /// What the editor can add here: **one of each kind of thing the level already has** — the
    /// engine's `LevelEditor.kinds()` — less the floor and the objectives. An objective crate is a
    /// crate *and* a marker the run counts; adding the crate alone makes one that glows and can never be taken.
    private var addableKinds: [Level.Placement] {
        editor.kinds().filter { !$0.tags.contains("ground") && !$0.tags.contains("objective") }
    }

    private func kindName(_ kind: Level.Placement) -> String {
        // The lamp's brightness in the name, because two braziers whose lamps differ are two kinds —
        // and a palette that shows "brazier with its lamp" twice cannot be told apart.
        kind.mesh + (kind.light.map { String(format: " with a lamp at %.0f", $0.color.max()) } ?? "")
            // **"scale", not "×"**: the HUD's font is printable ASCII, and a "×" is silently dropped —
            // the line read "box at 2.4" the first time it was drawn.
            + (kind.scale == 1 ? "" : String(format: ", scale %.1f", kind.scale))
            // **And whether it moves**: the courtyard's sliding block is a box at 1.5, and named only that it read as a
            // crate — dropped, it slid away. A kind is everything about a placement, and moving is the part that shows.
            + ["slider", "piston", "lift"].filter(kind.tags.contains).map { ", " + $0 }.joined()
    }

    /// Drops the chosen kind **where the crosshair meets the ground**, which is what "put one there"
    /// means with no mouse cursor to put anything under. Not on whatever the crosshair touches first:
    /// a crate dropped onto the side of a pillar is a crate inside it.
    private func addUnderCrosshair() {
        let kinds = addableKinds
        guard !kinds.isEmpty else { return }
        let kind = kinds[min(addKind, kinds.count - 1)]
        let origin = camera.position, direction = camera.forward
        // The sample's ground is the plane y = 0. Looking level or up, the crosshair never meets it.
        guard direction.y < -0.01 else {
            print("WindageSample: aim at the ground to add something")
            return
        }
        let distance = -origin.y / direction.y
        guard distance < 60 else {
            print("WindageSample: that ground is \(Int(distance)) m away — come closer to add something")
            return
        }
        let hit = origin + direction * distance
        editor.add(kind, at: SIMD2(hit.x, hit.z))
        rebuild()
        let index = editor.selection!
        let at = level.transform(of: level.placements[index], on: SampleGame.ground).columns.3
        var line = String(format: "WindageSample: added %@ #%d at (%.2f, %.2f, %.2f), the crosshair met the ground at (%.2f, 0, %.2f)",
                          kindName(kind), index, at.x, at.y, at.z, hit.x, hit.z)
        if let lamp = level.carriedLights(on: SampleGame.ground).first(where: { $0.placement == index })?.light {
            line += String(format: "; lamp at (%.2f, %.2f, %.2f)", lamp.position.x, lamp.position.y, lamp.position.z)
        }
        print(line)
    }

    /// The lamp the editor gives something that has none: warm, hanging a little above the top of
    /// the mesh. **Above the mesh, not at its middle** — a lamp inside a crate lights the inside of
    /// the crate, and its shadow cube sees nothing but walls.
    private func newLamp(for mesh: String) -> PunctualLight {
        let top = meshes[mesh]?.bounds.maximum.y ?? 1
        return PunctualLight(position: SIMD3(0, top + 0.6, 0), color: SIMD3(1, 0.72, 0.42) * 45, range: 12)
    }

    /// Says where the selection's lamp is **in the world** — through the level's own resolution, the
    /// one the renderer lights with — so a scripted edit can be checked against where it should be.
    private func reportLamp() {
        guard let index = editor.selection, let placement = editor.selected else { return }
        guard let lamp = level.carriedLights(on: SampleGame.ground).first(where: { $0.placement == index })?.light else {
            print("WindageSample: \(placement.mesh) #\(index) has no lamp")
            return
        }
        print(String(format: "WindageSample: lamp on %@ #%d at (%.2f, %.2f, %.2f), intensity %.1f, range %.0f",
                     placement.mesh, index, lamp.position.x, lamp.position.y, lamp.position.z,
                     lamp.color.max(), lamp.range))
    }

    /// Steps through the tone map curves, so the difference can be looked at rather than argued
    /// about.
    ///
    /// **`clamp` is the one worth pressing.** It is what a renderer does with no tone mapping at all,
    /// and on a lit scene the sunlit faces go flat: everything above 1 becomes the same white, so a
    /// bright surface and a *very* bright surface arrive identical.
    // MARK: - Settings screen

    private func drawSettings(_ menu: SettingsMenu, on hud: HUDRenderer, scale: Float) {
        let size = 22 * scale, line = size * 1.55
        let width = 700 * scale
        let height = line * Float(menu.rows.count + 5)
        let left = (viewportSize.x - width) / 2, top = (viewportSize.y - height) / 2
        let white = InterfaceColor(srgb: SIMD4(1, 1, 1, 0.95))
        let dim = InterfaceColor(srgb: SIMD4(1, 1, 1, 0.55))
        let gold = InterfaceColor(srgb: SIMD4(1.0, 0.85, 0.25, 1))

        hud.fillRect(origin: SIMD2(left,
                                   top), size: SIMD2(width,
                                                     height), color: InterfaceColor(srgb: SIMD4(0.05, 0.06, 0.08, 0.86)))
        var y = top + line * 1.2
        _ = hud.text("SETTINGS", atBaseline: SIMD2(left + size, y), pointSize: size * 1.3, color: white)
        y += line * 1.3

        for (index, row) in menu.rows.enumerated() {
            let selected = index == menu.selected
            let (label, value): (String, String) = switch row {
            case .bind(let action):
                (SampleGame.title(of: action), menu.capturing == row ? "press a key..." : settings.bindings[action]?.name ?? "")
            case .pad(let action):
                ("Pad " + SampleGame.title(of: action).lowercased(), menu.capturing == row
                    ? "press a button..." : (settings.padBindings[action]?.name(on: input.gamepad) ?? ""))
            case .mouseSensitivity: ("Mouse sensitivity", String(format: "%.1f", settings.mouseSensitivity))
            case .invertMouse: ("Invert mouse", settings.invertMouse ? "on" : "off")
            case .stickSensitivity: ("Stick sensitivity", String(format: "%.1f", settings.stickSensitivity))
            case .invertStick: ("Invert stick", settings.invertStick ? "on" : "off")
            case .moveDeadzone: ("Move stick dead zone", "\(Int((settings.moveDeadzone * 100).rounded()))%")
            case .lookDeadzone: ("Look stick dead zone", "\(Int((settings.lookDeadzone * 100).rounded()))%")
            case .headBob: ("Head bob", settings.headBobAmount == 0 ? "off" : "\(Int((settings.headBobAmount * 100).rounded()))%")
            case .volume: ("Volume", "\(Int((settings.volume * 100).rounded()))%")
            case .ambienceVolume: ("Ambience", "\(Int((settings.ambienceVolume * 100).rounded()))%")
            case .brightness: ("Brightness", String(format: "%+.2f stops", settings.brightness))
            case .reset: ("Reset to defaults", "")
            }
            let color = selected ? gold : white
            _ = hud.text((selected ? "> " : "  ") + label, atBaseline: SIMD2(left + size, y),
                         pointSize: size, color: color)
            _ = hud.text(value, atBaseline: SIMD2(left + width * 0.58, y), pointSize: size, color: color)
            y += line
        }

        y += line * 0.4
        if case .pad = menu.capturing {
            _ = hud.text("press the button you want · menu button or esc cancels",
                         atBaseline: SIMD2(left + size, y), pointSize: size * 0.8, color: gold)
        } else if menu.capturing != nil {
            _ = hud.text("press the key you want · esc cancels", atBaseline: SIMD2(left + size, y),
                         pointSize: size * 0.8, color: gold)
        } else if let message = menu.message {
            _ = hud.text(message, atBaseline: SIMD2(left + size, y), pointSize: size * 0.8, color: gold)
        }
        y += line
        _ = hud.text(input.isGamepadConnected
                     ? "d-pad choose · cross change · d-pad left/right adjust · circle close"
                     : "up/down choose · return change · left/right adjust · o close",
                     atBaseline: SIMD2(left + size, y), pointSize: size * 0.75, color: dim)
    }

    private func openMenu() {
        var opened = SettingsMenu()
        opened.rows = SettingsMenu.rows(withPad: input.isGamepadConnected)
        // **Paused while it is open**, or the clock runs out behind a screen of key bindings.
        if run.mode == .playing {
            run.togglePause()
            opened.pausedTheRun = true
        }
        menu = opened
        input.setMouseCaptured(false)
        input.acceptsPadActions = false
    }

    private func closeMenu() {
        if menu?.pausedTheRun == true && run.mode == .paused { run.togglePause() }
        menu = nil
        input.acceptsPadActions = true
    }

    /// The pad's share of the settings screen, once a frame: open and close on the menu button,
    /// navigate on the d-pad, Cross to change and Circle to leave — or, while a pad row is waiting,
    /// the next button pressed, whatever it is.
    ///
    /// **Read from `padButtonsPressed` rather than from the bindings**, because the screen is where
    /// the bindings are changed: a menu that followed them would move its own "change" button the
    /// moment somebody rebound jump.
    private func handleMenuPad() {
        guard input.isGamepadConnected else { return }
        let steps = input.consumeSteps()
        guard var current = menu else {
            if input.wasPadMenuPressed && !isEditing { openMenu() }
            return
        }
        current.rows = SettingsMenu.rows(withPad: true)
        current.selected = min(current.selected, current.rows.count - 1)
        menu = current

        if case .pad(let action) = current.capturing {
            if input.wasPadMenuPressed {
                menu?.capturing = nil
            } else if let button = input.padButtonsPressed.sorted(by: { $0.rawValue < $1.rawValue }).first {
                bind(action, toButton: button)
            }
            return
        }
        if input.wasPadMenuPressed { perform(.close); return }
        for _ in 0..<abs(steps.y) { perform(steps.y > 0 ? .up : .down) }
        for _ in 0..<abs(steps.x) { perform(steps.x > 0 ? .right : .left) }
        if input.padButtonsPressed.contains(.south) { perform(.activate) }
        if input.padButtonsPressed.contains(.east) { perform(.close) }
    }

    /// Every key while the screen is open. **Always consumed**, so nothing typed into a settings
    /// screen walks the player behind it.
    private func handleMenuKey(_ key: KeyCode) -> Bool {
        guard let current = menu else { return false }
        if let capturing = current.capturing {
            if key == .escape {
                menu?.capturing = nil
                menu?.message = nil
            } else if case .bind(let action) = capturing {
                bind(action, to: key)
            }
            // A pad row waiting for a button ignores the keyboard, bar Escape.
            return true
        }
        switch key {
        case .escape, .o: perform(.close)
        case .up: perform(.up)
        case .down: perform(.down)
        case .left: perform(.left)
        case .right: perform(.right)
        case .return: perform(.activate)
        default: break
        }
        return true
    }

    private func perform(_ command: MenuCommand) {
        guard var current = menu else { return }
        let count = current.rows.count
        switch command {
        case .close:
            closeMenu()
            return
        case .up: current.selected = (current.selected + count - 1) % count
        case .down: current.selected = (current.selected + 1) % count
        case .left: adjust(current.row, by: -1)
        case .right: adjust(current.row, by: 1)
        case .activate:
            switch current.row {
            case .bind, .pad:
                current.capturing = current.row
                current.message = nil
            case .mouseSensitivity, .invertMouse, .stickSensitivity, .invertStick, .moveDeadzone, .lookDeadzone,
                 .headBob, .volume, .ambienceVolume, .brightness:
                adjust(current.row, by: 1)
            case .reset:
                settings = SampleGame.defaultSettings
                current.message = "Everything back to the defaults"
                saveAndApplySettings()
            }
        }
        menu = current
    }

    private func bind(_ action: InputAction, to key: KeyCode) {
        let outcome = settings.bindings.bind(action, to: key, reserving: SampleGame.reservedKeys)
        switch outcome {
        case .bound:
            menu?.message = "\(SampleGame.title(of: action)) is \(key.name)"
        case .swapped(let other):
            menu?.message = "\(SampleGame.title(of: action)) is \(key.name) — \(SampleGame.title(of: other)) moved to "
                + (settings.bindings[other]?.name ?? "")
        case .refused:
            menu?.message = InputBindings.fixed.contains(key)
                ? "\(key.name) cannot be bound"
                : "\(key.name) is one of this game's own keys"
        }
        menu?.capturing = nil
        saveAndApplySettings()
    }

    private func bind(_ action: InputAction, toButton button: PadButton) {
        let name = button.name(on: input.gamepad)
        switch settings.padBindings.bind(action, to: button) {
        case .bound:
            menu?.message = "Pad \(SampleGame.title(of: action).lowercased()) is \(name)"
        case .swapped(let other):
            menu?.message = "Pad \(SampleGame.title(of: action).lowercased()) is \(name) — \(SampleGame.title(of: other).lowercased()) moved to "
                + (settings.padBindings[other]?.name(on: input.gamepad) ?? "")
        case .refused:
            menu?.message = "\(name) cannot be bound"
        }
        menu?.capturing = nil
        saveAndApplySettings()
    }

    /// Rounded to a tenth, so eleven presses of +0.1 read 1.1 and not 1.0999999.
    private static func tenths(_ value: Float) -> Float { (value * 10).rounded() / 10 }

    private func adjust(_ row: SettingsMenu.Row, by steps: Int) {
        let step = Float(steps)
        switch row {
        case .mouseSensitivity: settings.mouseSensitivity = Self.tenths(settings.mouseSensitivity + 0.1 * step)
        case .invertMouse: settings.invertMouse.toggle()
        case .stickSensitivity: settings.stickSensitivity = Self.tenths(settings.stickSensitivity + 0.1 * step)
        case .invertStick: settings.invertStick.toggle()
        // Steps of 2%: a drifting stick rests a few percent off centre, so the useful settings are
        // close together, and a 10% step would jump straight past the one that just stops it.
        case .moveDeadzone: settings.moveDeadzone = ((settings.moveDeadzone + 0.02 * step) * 50).rounded() / 50
        case .lookDeadzone: settings.lookDeadzone = ((settings.lookDeadzone + 0.02 * step) * 50).rounded() / 50
        // Quarters, so off is two presses from half and four from full — and activating it from
        // full wraps to off, which is the press a player looking for "off" makes.
        case .headBob:
            let next = settings.headBobAmount + 0.25 * step
            settings.headBobAmount = next > 1.001 ? 0 : (next < -0.001 ? 1 : (next * 4).rounded() / 4)
        case .volume: settings.volume = Self.tenths(settings.volume + 0.1 * step)
        case .ambienceVolume: settings.ambienceVolume = Self.tenths(settings.ambienceVolume + 0.1 * step)
        case .brightness: settings.brightness += 0.25 * step
        case .bind, .pad, .reset: return
        }
        saveAndApplySettings()
    }

    /// Written the moment anything changes. **There is no "apply" button**: a settings screen that can
    /// be closed without saving is one a player closes without saving, and then finds their keys
    /// back the way they were.
    private func saveAndApplySettings() {
        applySettings()
        do {
            try SampleGame.settingsStore.save(settings)
        } catch {
            print("WindageSample: settings not saved — \(error)")
        }
    }

    private func applySettings() {
        input.apply(settings)
        audio?.masterVolume = settings.volume
        audio?.loopVolume = settings.ambienceVolume
        engine.toneMapping.exposureStops = SampleGame.baseExposure + settings.brightness
    }

    // MARK: - Footsteps

    /// Which of three recordings the next footstep uses. **An order that does not repeat every
    /// three**, so the pattern takes six steps to come round — long enough that the ear stops
    /// looking for it.
    private static let stepOrder = [0, 2, 1, 0, 1, 2]
    private var stepsPlayed = 0

    /// What the scripted walk reports for the segment in progress: footsteps, and landings.
    private var tally = (steps: 0, surfaces: Set<String>(), landings: [String](), deepestDip: Float(0))
    /// The lowest and highest head bob shown during the segment in progress, **after the player's
    /// setting** — what reached the screen, not what the body offered.
    private var bobSeen = (low: SIMD2<Float>(repeating: .greatestFiniteMagnitude),
                           high: SIMD2<Float>(repeating: -.greatestFiniteMagnitude))

    /// The head bob as shown: the body's, times the player's setting.
    private var shownBob: SIMD2<Float> { body.headBob * settings.headBobAmount }
    /// Last step's, so a frame between two steps shows a bob between them — like the camera.
    private var previousBob = SIMD2<Float>.zero

    /// Plays whatever the body just did.
    ///
    /// **Not positioned**, which is the engine's own advice for a sound that happens *to* the player:
    /// the ears are 1.7 m above the feet and moving with them, so a spatialised footstep would only
    /// come out a little quieter and from somewhere odd.
    private func playFootfalls() {
        // **From the level**: the placement stood on, or the ground. This was "every solid is stone,
        // the ground is dirt" until 2026-09-11 — true of both levels only because nobody had laid a board.
        let placement = body.groundSolid.flatMap { solidPlacements.indices.contains($0) ? solidPlacements[$0] : nil }
        var surface = level.surface(standingOn: placement) ?? "stone"
        if level.surface(standingOn: placement) == nil, let placement, unnamedSurfaces.insert(placement).inserted {
            // Said once, not guessed silently: a solid with no surface is a gap in the level file.
            print("WindageSample: \(level.placements[placement].mesh) #\(placement) names no surface — footsteps sound like stone")
        }
        if !SampleLevel.footstepSurfaces.contains(surface) { surface = "stone" }
        for event in body.events {
            switch event {
            case .stride(_, let speed):
                // Louder as it gets faster: crouched is a creep, a sprint is a run.
                let crouched = body.tuning.walkSpeed * body.tuning.crouchedSpeedFraction
                let t = simd_clamp((speed - crouched) / (body.tuning.sprintSpeed - crouched), 0, 1)
                let variant = SampleGame.stepOrder[stepsPlayed % SampleGame.stepOrder.count]
                audio?.play("step_\(surface)_\(variant)", volume: 0.3 + 0.7 * t)
                stepsPlayed += 1
                tally.steps += 1
                tally.surfaces.insert(surface)
            case .landed(let impact):
                // **A step down a stair is not this** — the controller never reports one — so every
                // landing here was a fall or a jump, and how loud is how hard.
                audio?.play("land_\(surface)", volume: simd_clamp(impact / 9, 0.35, 1))
                tally.landings.append(String(format: "%.1f m/s on %@", impact, surface))
            case .jumped:
                // The push-off: a footstep, softer. A jump with no sound at the start reads as the
                // floor letting go rather than the legs pushing.
                audio?.play("step_\(surface)_0", volume: 0.4)
            }
        }
    }

    /// The pad a script presses, made the first time a script asks for one.
    ///
    /// **A real `GCExtendedGamepad`, not a stand-in**: `GCController.withExtendedGamepad()` makes one
    /// whose buttons are set from code, and `InputState.useGamepad` reads it exactly as it would a
    /// DualSense — bindings, press edges, the menu and all.
    private var scriptPad: GCExtendedGamepad?

    /// Presses or releases one element of the script's pad.
    ///
    /// > **The d-pad has to be pushed by its axes.** Setting `dpad.down` as a button on a virtual pad
    /// > is accepted and does nothing — `isPressed` stays false — so the first scripted run opened the
    /// > settings screen with the menu button and then could not move off its first row. The
    /// > direction pad only moves through `setValueForXAxis(_:yAxis:)`.
    private func setScriptPad(_ token: String, down: Bool) {
        guard let pad = scriptPad else { return }
        // `lookRight@0.2` holds the stick a fifth of the way — what a worn stick resting off centre
        // looks like, and what a dead zone is for. Buttons ignore it.
        let parts = token.split(separator: "@")
        let name = String(parts[0])
        let amount = parts.count > 1 ? Float(parts[1]) ?? 1 : 1
        let value: Float = down ? amount : 0
        switch name {
        case "up": pad.dpad.setValueForXAxis(0, yAxis: value)
        case "down": pad.dpad.setValueForXAxis(0, yAxis: -value)
        case "left": pad.dpad.setValueForXAxis(-value, yAxis: 0)
        case "right": pad.dpad.setValueForXAxis(value, yAxis: 0)
        // The look stick, held at full deflection — the right thumbstick, by its axes as the d-pad is.
        case "lookUp": pad.rightThumbstick.setValueForXAxis(0, yAxis: value)
        case "lookDown": pad.rightThumbstick.setValueForXAxis(0, yAxis: -value)
        case "lookLeft": pad.rightThumbstick.setValueForXAxis(-value, yAxis: 0)
        case "lookRight": pad.rightThumbstick.setValueForXAxis(value, yAxis: 0)
        // The move stick, likewise.
        case "moveUp": pad.leftThumbstick.setValueForXAxis(0, yAxis: value)
        case "moveDown": pad.leftThumbstick.setValueForXAxis(0, yAxis: -value)
        case "moveLeft": pad.leftThumbstick.setValueForXAxis(-value, yAxis: 0)
        case "moveRight": pad.leftThumbstick.setValueForXAxis(value, yAxis: 0)
        default: scriptPadElement(name)?.setValue(value)
        }
    }

    private func scriptPadElement(_ name: String) -> GCControllerButtonInput? {
        guard let pad = scriptPad else { return nil }
        switch name {
        case "south": return pad.buttonA
        case "east": return pad.buttonB
        case "west": return pad.buttonX
        case "north": return pad.buttonY
        case "leftShoulder": return pad.leftShoulder
        case "rightShoulder": return pad.rightShoulder
        case "leftStick": return pad.leftThumbstickButton
        case "rightStick": return pad.rightThumbstickButton
        case "menu": return pad.buttonMenu
        default:
            print("WindageSample: WINDAGE_SAMPLE_WALK does not know the pad element '\(name)'")
            return nil
        }
    }

    /// How far the view has turned since the current script segment began — right and up, in
    /// radians — for the line a segment prints when it ends.
    private var viewTurned = SIMD2<Float>.zero

    /// A mouse movement, already through the mouse's own sensitivity and invert. **The one place a
    /// mouse turns the view**, whether the movement came from the hand — `InputState.consumeLook()`
    /// scales it — or from a script, which scales its own by the same `InputState.mouseLookScale`.
    private func lookWithMouse(_ delta: SIMD2<Float>) {
        let before = camera
        camera.look(mouseDelta: delta)
        noteTurn(from: before)
    }

    private func noteTurn(from before: Camera) {
        let yaw = camera.yaw - before.yaw
        viewTurned += SIMD2(-atan2(sin(yaw), cos(yaw)), camera.pitch - before.pitch)
    }

    /// The turned solid nearest the body, within 3 m: how far the body's square is from the solid as
    /// it stands and from its world box (nil inside it). **Measured here, not asked of the controller**
    /// — the gap between two convex outlines that do not overlap, the least of each one's corners to
    /// the other's edges.
    private func nearestTurnedSolid() -> (name: String, yaw: Float, center: SIMD2<Float>, gap: Float, boxGap: Float?)? {
        let r = body.tuning.radius, at = SIMD2(body.feet.x, body.feet.z)
        let square = [SIMD2<Float>(-r, -r), SIMD2(r, -r), SIMD2(r, r), SIMD2(-r, r)].map { at + $0 }
        var best: (name: String, yaw: Float, center: SIMD2<Float>, gap: Float, boxGap: Float?)?
        for (index, solid) in surroundings.solids.enumerated() {
            guard let footprint = solid.footprint, abs(sin(2 * footprint.yaw)) > 0.01,
                  simd_distance(footprint.center, at) < 3 + simd_length(footprint.halfSize) else { continue }
            let h = footprint.halfSize
            let outline = [SIMD2(-h.x, -h.y), SIMD2(h.x, -h.y), SIMD2(h.x, h.y), SIMD2(-h.x, h.y)]
                .map { footprint.center + Level.turned($0, by: footprint.yaw) }
            let box = solid.bounds
            let boxOutline = [SIMD2(box.minimum.x, box.minimum.z), SIMD2(box.maximum.x, box.minimum.z),
                              SIMD2(box.maximum.x, box.maximum.z), SIMD2(box.minimum.x, box.maximum.z)]
            let gap = SampleGame.gap(between: square, and: outline)
            guard best == nil || gap < best!.gap else { continue }
            let inBox = at.x + r > box.minimum.x && at.x - r < box.maximum.x
                && at.y + r > box.minimum.z && at.y - r < box.maximum.z
            best = (level.placements[solidPlacements[index]].mesh, footprint.yaw, footprint.center,
                    gap, inBox ? nil : SampleGame.gap(between: square, and: boxOutline))
        }
        return best
    }

    /// The distance between two convex outlines that do not overlap — zero if they touch.
    private static func gap(between a: [SIMD2<Float>], and b: [SIMD2<Float>]) -> Float {
        func toEdges(_ point: SIMD2<Float>, _ outline: [SIMD2<Float>]) -> Float {
            var least = Float.greatestFiniteMagnitude
            for i in outline.indices {
                let p = outline[i], q = outline[(i + 1) % outline.count], edge = q - p
                let t = simd_clamp(simd_dot(point - p, edge) / simd_length_squared(edge), 0, 1)
                least = min(least, simd_distance(point, p + edge * t))
            }
            return least
        }
        return min(a.map { toEdges($0, b) }.min() ?? 0, b.map { toEdges($0, a) }.min() ?? 0)
    }

    /// Plays the scripted walk's keys this step. See `ScriptedWalk`.
    private func runScript(_ deltaTime: Float) {
        guard scriptedWalk?.isRunning == true else { return }
        if scriptPad == nil && scriptedWalk?.usesPad == true {
            scriptPad = GCController.withExtendedGamepad().extendedGamepad
            input.useGamepad(scriptPad)
        }
        for event in scriptedWalk!.advance(by: deltaTime, body: body) {
            switch event {
            case .begin(let segment):
                viewTurned = .zero
                if let yaw = segment.yaw { camera.yaw = yaw }
                if let pitch = segment.pitch { camera.pitch = pitch }
                if let mouse = segment.mouse { lookWithMouse(mouse * input.mouseLookScale) }
                // **`cmd+s` is ⌘S**: the editor's save, undo and discard are Command chords, and a script pressed them
                // as a held modifier and a bare S, which the editor never sees as a chord.
                let command = segment.keys.contains { $0 == .leftCommand || $0 == .rightCommand }
                for key in segment.keys {
                    if let flag = key.modifierFlag {
                        modifiersChanged(key, flags: flag)
                    } else {
                        keyPressed(key, command: command)
                    }
                }
                for name in segment.pads { setScriptPad(name, down: true) }
                if segment.clicks { mousePressed() }
            case .end(let segment, let report):
                for key in segment.keys {
                    if key.isModifier { modifiersChanged(key, flags: []) } else { keyReleased(key) }
                }
                for name in segment.pads { setScriptPad(name, down: false) }
                if simd_length(viewTurned) > 1e-5 {
                    print(String(format: "WindageSample: look '%@' → view turned %.2f° right, %.2f° up",
                                 segment.label, viewTurned.x * 180 / .pi, viewTurned.y * 180 / .pi))
                }
                if let report {
                    print(report)
                    var heard = tally.steps == 1 ? "1 footstep" : "\(tally.steps) footsteps"
                    if !tally.surfaces.isEmpty { heard += " on " + tally.surfaces.sorted().joined(separator: " and ") }
                    if !tally.landings.isEmpty { heard += ", landed at " + tally.landings.joined(separator: ", ") }
                    if tally.deepestDip > 0 {
                        heard += String(format: ", eye dipped %.0f cm and the view %.1f°",
                                        tally.deepestDip * body.tuning.landingDropMax * 100,
                                        tally.deepestDip * body.tuning.landingDipMax * 180 / .pi)
                    }
                    print("WindageSample:     \(heard)")
                    if let table = turntables.first(where: { t in body.groundSolid.map { t.solid == $0 } ?? false }) {
                        // Angles the way a yaw turns an offset — `Level.turned` — so all three read alike.
                        let offset = SIMD2(body.feet.x - table.position.x, body.feet.z - table.position.z)
                        let feetAngle = atan2(-offset.y, offset.x) * 180 / .pi
                        print(String(format: "WindageSample:     on the turntable (turned %.1f°): feet at %.1f° round its centre, radius %.2f m; view yaw %.1f°",
                                     turntableAngle * 180 / .pi, feetAngle, simd_length(offset), camera.yaw * 180 / .pi))
                    }
                    if let slider = sliders.first, body.pinnedBy != nil || simd_distance(
                        SIMD2(volumes[slider.drawable].worldBounds.center.x, volumes[slider.drawable].worldBounds.center.z),
                        SIMD2(body.feet.x, body.feet.z)) < 3 {
                        let box = volumes[slider.drawable].worldBounds
                        let speed = (body.feet.x - previousFeet.x) / Float(engine.timestep.stepDuration)
                        print(String(format: "WindageSample:     slider's face at x %.3f, feet %.3f m ahead of it, going %.3f m/s, the slider %.3f%@",
                                     box.maximum.x, body.feet.x - box.maximum.x, speed,
                                     surroundings.solids.indices.contains(slider.solid ?? -1)
                                        ? surroundings.solids[slider.solid!].motion.x / Float(engine.timestep.stepDuration) : 0,
                                     body.pinnedBy != nil ? ", PINNED" : ""))
                    }
                    if let near = nearestTurnedSolid() {
                        print(String(format: "WindageSample:     %@ turned %.1f° at (%.2f, %.2f): %.3f m from it, %@",
                                     near.name, near.yaw * 180 / .pi, near.center.x, near.center.y, near.gap,
                                     near.boxGap.map { String(format: "%.3f m from its box", $0) } ?? "inside its box"))
                    }
                    if !lifts.isEmpty {
                        let riding = body.groundSolid.map { solid in
                            lifts.contains { $0.solid == solid }
                        } ?? false
                        let top = lifts.first.flatMap { volumes[$0.drawable].worldBounds.maximum.y } ?? 0
                        print(String(format: "WindageSample:     lift top %.2f m, feet at %.2f m%@", top, body.feet.y,
                                     riding ? ", riding it" : ""))
                    }
                    let bob = bobSeen.high - bobSeen.low
                    print(bob.y.isFinite && simd_max(bob.x, bob.y) > 0.0005
                        ? String(format: "WindageSample:     head bob %.1f cm up and down, %.1f cm side to side",
                                 bob.y * 100, bob.x * 100)
                        : "WindageSample:     no head bob")
                }
                tally = (0, [], [], 0)
                bobSeen = (SIMD2(repeating: .greatestFiniteMagnitude), SIMD2(repeating: -.greatestFiniteMagnitude))
            }
        }
    }

    private func cycleToneMapping() {
        let curves = ToneMapping.Curve.allCases
        let next = curves[((curves.firstIndex(of: engine.toneMapping.curve) ?? 0) + 1) % curves.count]
        engine.toneMapping.curve = next
        print("WindageSample: tone map curve \(next), "
              + "\(engine.toneMapping.exposureStops) stops")
    }

    /// Pick whatever is under the middle of the screen.
    ///
    /// Down the crosshair rather than from the mouse position: the sample captures the pointer for
    /// look, so there *is* no mouse position while playing, and a picker that needed one would only
    /// work in a mode the sample does not have.
    /// A mouse button went down. **The game decides what that is**: in the editor it picks what is
    /// under the crosshair, otherwise it captures the pointer for looking. Here rather than in the
    /// view so the scripted walk can click through the same path.
    func mousePressed() {
        skipSplash()
        if isEditing { pickUnderCrosshair() } else { input.setMouseCaptured(true) }
    }

    func pickUnderCrosshair() {
        let origin = camera.position
        // **Not the lanterns.** The editor's selection is an index into the level's placements, and
        // a lantern has none — clicking one would select something that is not there.
        let hit = Volume.firstHit(origin: origin, direction: camera.forward,
                                  against: Array(volumes.prefix(levelVolumeCount)),
                                  maxDistance: 200)
        editor.select(hit?.index)
        rebuild()
    }

    // MARK: - GameLoop

    /// **Mouse look is consumed once per frame, not once per step.** A mouse delta is a
    /// displacement that already happened; applying it in a frame that ran three simulation steps
    /// would turn three times as far. The engine's `InputState` says so and the sample obeys it —
    /// this is the sort of thing a consumer gets wrong when the engine only documents it in one
    /// game's source.
    /// `WINDAGE_SAMPLE_FPS=1` prints frames and simulation steps per second — how a slowdown that
    /// only shows as a scripted walk taking too long was first measured.
    private static let reportsRate = ProcessInfo.processInfo.environment["WINDAGE_SAMPLE_FPS"] != nil
    private var rateWindow = (start: CFAbsoluteTimeGetCurrent(), frames: 0, steps: 0)
    /// The longest wall-clock wait between two steps in the current second, and when the last ran.
    /// **Steps a second cannot show a throttled clock**: a hidden window's steps credit whatever time
    /// went by, so a timer slowed to once a second still runs 120 of them — in one burst. The gap shows it.
    private var stepGap = (longest: 0.0, last: CFAbsoluteTimeGetCurrent())

    func beginFrame() {
        if SampleGame.reportsRate {
            rateWindow.frames += 1
            reportRate()
        }
        input.pollFrame()
        handleMenuPad()
        let look = input.consumeLook()
        // **A scripted walk holds its heading.** Otherwise whatever the mouse is doing over the
        // window steers it, and the same script ends somewhere different each time — which was the
        // first thing it did.
        if scriptedWalk?.isRunning != true { lookWithMouse(look) }
    }

    /// Prints the rate once a second has gone by. **From a step as well as a frame**, because a
    /// hidden window running its simulation has steps and no frames — a report only a frame could
    /// print would go quiet exactly when there is something to report.
    private func reportRate() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - rateWindow.start >= 1 else { return }
        print(String(format: "WindageSample: %.0f frames a second, %.0f steps, longest wait %.0f ms, camera (%.1f, %.1f, %.1f)",
                     Double(rateWindow.frames) / (now - rateWindow.start),
                     Double(rateWindow.steps) / (now - rateWindow.start),
                     stepGap.longest * 1000,
                     camera.position.x, camera.position.y, camera.position.z))
        rateWindow = (now, 0, 0)
        stepGap.longest = 0
    }

    /// The engine's splash, while it lasts. **An overlay and a clock, not a mode** — the game steps
    /// behind it, so a walk that begins under it ends exactly where it would have.
    private var splash: SplashScreen? = SampleGame.showsSplash ? SplashScreen(lead: "MADE WITH") : nil

    /// Any press cuts the splash short — **and goes on to do whatever it was going to do.** A splash
    /// that swallowed it would swallow the first key of a scripted walk; there is a walk that checks.
    private func skipSplash() {
        splash?.skip()
    }

    func step(deltaTime: Float) {
        if splash != nil {
            splash?.advance(by: deltaTime)
            if splash?.isFinished == true { splash = nil }
        }
        // **As a check there are no frames**, and the pad is polled in `beginFrame` — so a scripted pad
        // could press the settings screen's buttons and nothing read them: the dead-zone walk set nothing
        // and measured the defaults twice. Polled here instead, where the check's steps are. The keyboard
        // never had this: its keys go straight to `keyPressed`.
        if SampleGame.isCheck {
            input.pollFrame()
            handleMenuPad()
        }
        rateWindow.steps += 1
        if SampleGame.reportsRate {
            let now = CFAbsoluteTimeGetCurrent()
            stepGap.longest = max(stepGap.longest, now - stepGap.last)
            stepGap.last = now
            reportRate()
        }
        previousCamera = camera
        previousBob = shownBob
        // **First, and whatever state the run is in** — a script that opens the settings screen
        // pauses the run, and one that only advanced while playing would wait for ever.
        runScript(deltaTime)
        let before = camera
        camera.turn(rate: input.lookRate, deltaTime: deltaTime)
        noteTurn(from: before)
        // **A pause is "do not advance", not "stop the loop".** The frame loop keeps running, the
        // scene still draws and the window still resizes — which is why pausing is a game's decision
        // and not something the engine has to provide.
        if !isEditing {
            let events = run.step(deltaTime: Double(deltaTime), playerAt: camera.position)
            if !events.isEmpty { rebuild() }          // a collected crate changes colour
            for crate in events.collected {
                // **At the crate, not at the player.** The whole reason the engine spatialises is
                // that a sound should come from where the thing is; playing it flat would make the
                // positional path untested by the one consumer meant to exercise it.
                audio?.play("pickup", at: crate + SIMD3(0, 1, 0))
                // **Above the lid, not at the crate's middle.** The first run threw it from 1.2 m, inside
                // a crate 1.5 m tall, and depth hid the bottom half of every burst.
                particles.burst(SampleGame.pickupRecipe, at: crate + SIMD3(0, 1.6, 0), seed: stepCount)
            }
            if events.won {
                audio?.play("win")
                // **Winning moves you on.** A game that ends and sits there is a game that stopped;
                // this is the smallest progression there is, and it is what makes a second level
                // part of the loop rather than a thing you have to ask for.
                advanceAfterWinning = 2.5
            }
            if events.lost { audio?.play("lose") }
        }

        if var wait = advanceAfterWinning {
            wait -= Double(deltaTime)
            if wait <= 0 {
                advanceAfterWinning = nil
                load(level: levelIndex + 1)
            } else {
                advanceAfterWinning = wait
            }
        }

        animateFigures(deltaTime: deltaTime)

        // **Every step, and after the lanterns have moved**, so an ember leaves the lantern where it
        // is rather than where it was. Paused or not: embers that froze mid-air would read as the game
        // having crashed, the same reason the figures keep breathing through a pause.
        for index in emberEmitters.indices {
            let at: SIMD3<Float>
            switch emberEmitters[index].source {
            case .point(let point): at = point
            case .light(let light):
                guard light < lightSet.lights.count else { continue }
                at = lightSet.lights[light].position
            }
            emberEmitters[index].emitter.emit(into: &particles, at: at, deltaTime: deltaTime)
        }
        particles.step(deltaTime: deltaTime)
        stepCount += 1

        // Where the ears are. Once per step is more often than needed — once per frame would do —
        // but it costs two vector writes and cannot go stale.
        audio?.updateListener(position: camera.position, forward: camera.forward, up: SIMD3(0, 1, 0))

        // In edit mode the movement keys are the editor's, so the camera holds still. So is a
        // finished run: walking around after the clock stops reads as the game not having noticed.
        if !isEditing && !run.isOver && run.mode != .paused {
            // **The level's machinery runs whichever camera is in use.** These were inside the walking
            // branch, so in photo mode every lift and turntable stood still — found by two frames of
            // the turntable 1.5 s apart that came out identical.
            advanceLifts(deltaTime)
            advanceSliders(deltaTime)
            advanceTurntables(deltaTime)
            if isPhotoMode {
                camera.advance(input.movement, deltaTime: deltaTime)
            } else {
                // **Yaw from the camera, and nothing else.** Pitch never reaches the body: looking at
                // your feet does not slow the walk, and looking at the sky does not lift you off it.
                let wasAirborne = !body.isGrounded
                let fallSpeed = -body.verticalVelocity
                previousFeet = body.feet
                let wasOn = body.groundSolid
                body.step(yaw: camera.yaw,
                          input: input.movement,
                          isJumpHeld: input.isJumpHeld,
                          isCrouching: input.isCrouching,
                          deltaTime: deltaTime,
                          in: surroundings)
                camera.position = body.eye
                // **A slider that pins the player turns back** — a door that meets someone reverses. The
                // controller only says which solid has them pinned; what that solid does is this game's.
                if let pinned = body.pinnedBy,
                   let slider = sliders.first(where: { !$0.piston && $0.solid == pinned }), slideRun.leg == .out {
                    slideRun.turnBack()
                    if scriptedWalk != nil {
                        let box = volumes[slider.drawable].worldBounds
                        print(String(format: "WindageSample:     pinned by the slider — its face at x %.4f, the feet at x %.4f — turned it back",
                                     box.maximum.x, body.feet.x))
                    }
                }
                // A scripted walk says where the feet left the ground and came down, and what they kept —
                // the flight a push or a moving floor sends them on.
                if scriptedWalk != nil && !wasAirborne && !body.isGrounded {
                    leftGroundAt = body.feet
                    print(String(format: "WindageSample:     left the ground at (%.3f, %.3f, %.3f), keeping (%.3f, %.3f) m/s",
                                 body.feet.x, body.feet.y, body.feet.z, body.airVelocity.x, body.airVelocity.y))
                }
                if scriptedWalk != nil && wasAirborne && body.isGrounded, let from = leftGroundAt {
                    print(String(format: "WindageSample:     came down at (%.3f, %.3f, %.3f), %.3f m across from where it left",
                                 body.feet.x, body.feet.y, body.feet.z,
                                 simd_distance(SIMD2(from.x, from.z), SIMD2(body.feet.x, body.feet.z))))
                    leftGroundAt = nil
                }
                // A scripted walk says where the feet stepped onto a turntable — the one moment its
                // outline shows: a square's corner lifts them before the rim, a disc at it.
                if scriptedWalk != nil, body.groundSolid != wasOn,
                   let table = turntables.first(where: { $0.solid != nil && $0.solid == body.groundSolid }) {
                    let from = SIMD2(body.feet.x - table.position.x, body.feet.z - table.position.z)
                    print(String(format: "WindageSample:     stepped onto the turntable %.3f m from its centre, the table turned %.1f°",
                                 simd_length(from), turntableAngle * 180 / .pi))
                }
                // **The view turns with whatever turned the feet.** The controller carries the body round
                // a turntable and says how far; the camera is the game's, so the game adds it — or the
                // player faces one fixed way while the floor spins under them.
                if body.turned != 0 { camera.yaw += body.turned }
                playFootfalls()
                tally.deepestDip = max(tally.deepestDip, body.landingCompression)
                bobSeen.low = simd_min(bobSeen.low, shownBob)
                bobSeen.high = simd_max(bobSeen.high, shownBob)
                // **Dust on a landing that was a fall**, not on every step down a stair: 4 m/s is a
                // drop of about 40 cm at this gravity, which is where a landing starts to be felt.
                if wasAirborne && body.isGrounded && fallSpeed > 4 {
                    particles.burst(SampleGame.dustRecipe, at: body.feet + SIMD3(0, 0.05, 0),
                                    seed: stepCount)
                }
            }
        }
    }

    /// How far away a figure notices the player. Chosen so a figure is waving by the time you are
    /// close enough to read the blend rather than after you have walked past it.
    private static let noticeDistance: Float = 7

    /// Advances every figure's clips and blends between them.
    ///
    /// **This is the whole animation update, and it is nine lines.** Everything expensive —
    /// sampling, the parent chain, the cross-fade — is `SkeletonPose.set(to:blendedWith:weight:)`,
    /// and the game's part is deciding *what* to play. That split is the point: a game that had to
    /// walk a joint hierarchy to make a character wave would have an engine that had not finished
    /// the job.
    ///
    /// **Runs while editing and while paused.** A frozen character in a paused game looks broken in
    /// a way a frozen crate does not.
    private func animateFigures(deltaTime: Float) {
        for index in figures.indices {
            figures[index].idle.advance(by: deltaTime)
            figures[index].wave.advance(by: deltaTime)

            let distance = simd_distance(figures[index].position, camera.position)
            let target: Float = distance < SampleGame.noticeDistance ? 1 : 0
            // Eased rather than switched. A cross-fade is the only reason the pose keeps rotation as
            // a quaternion, and snapping between clips would waste it — a quarter of a second is
            // about where a hand-over stops reading as a glitch.
            let rate = min(deltaTime / 0.25, 1)
            figures[index].waveWeight += (target - figures[index].waveWeight) * rate

            figures[index].pose.set(to: figures[index].idle,
                                    blendedWith: figures[index].wave,
                                    weight: figures[index].waveWeight)
        }
        // **After the poses, never before.** A lantern placed from last step's pose is a hand and a
        // held object a frame apart, which is the one artefact everybody recognises as wrong.
        placeLanterns()
    }

    func viewportSizeChanged(width: Int, height: Int) {
        aspectRatio = Float(width) / Float(max(height, 1))
        viewportSize = SIMD2(Float(width), Float(height))
    }

    private func uniformOffset(frameSlot: Int, drawable index: Int) -> Int {
        frameSlot * SampleGame.uniformStride * SampleGame.uniformSlots + index * SampleGame.uniformStride
    }

    /// Figures take the slots after the level's drawables in the same buffer.
    private func uniformOffset(frameSlot: Int, figure index: Int) -> Int {
        uniformOffset(frameSlot: frameSlot, drawable: SampleGame.maxDrawables + index)
    }

    private func jointOffset(frameSlot: Int, figure index: Int) -> Int {
        (frameSlot * SampleGame.maxFigures + index) * SampleGame.jointPaletteStride
    }

    private var visibleFigureCount: Int { min(figures.count, SampleGame.maxFigures) }

    /// The highest mip a shader may ask the specular cube for: `roughness × this`.
    private var environmentLOD: Float {
        Float(max((environment?.specularMipCount ?? 1) - 1, 0))
    }

    private var visibleDrawableCount: Int { min(drawables.count, SampleGame.maxDrawables) }

    /// The camera as drawn: between the last two steps, plus the slide's dip.
    ///
    /// **The dip goes on the view and never on `camera`**, which is the aim. Folded into the aim, a
    /// slide would leave the player looking somewhere new every time — the same rule a scope's sway
    /// follows.
    private func displayCamera(_ interpolation: Float) -> Camera {
        var view = Camera.interpolated(from: previousCamera, to: camera, alpha: interpolation)
        // Both kicks are the view's, and both are the body's to report: the slide's, and the head
        // nodding with the legs on a landing. The landing's *drop* is already in `body.eye`.
        view.pitch += body.slideCameraDip + body.landingCameraDip
        // The head bob, likewise the view's: across the view and up, never into the aim.
        let bob = previousBob + (shownBob - previousBob) * interpolation
        view.position += view.right * bob.x + SIMD3(0, bob.y, 0)
        return view
    }

    /// **Written before the shadow pass, not during the main one.** The shadow pass reads the same
    /// `model` matrix the main pass will; writing them in `encode` would record shadows from last
    /// frame's positions, which reads as shadows lagging behind their casters.
    private func writeUniforms(frameSlot: Int, interpolation: Float) {
        let view = displayCamera(interpolation)
        writeClusters(frameSlot: frameSlot, camera: view)
        let projection = simd_float4x4(
            perspectiveFovY: Float.radians(fromDegrees: 70), aspectRatio: aspectRatio, nearZ: 0.1)
        let viewProjection = simd_mul(projection, view.viewMatrix)

        for (index, drawable) in drawables.prefix(SampleGame.maxDrawables).enumerated() {
            var albedo = drawable.albedo

            // **An objective still to reach emits; one already taken does not.** It used to swap its
            // albedo instead, which is a colour a surface *is* — so a collected crate and an
            // uncollected one differed the way two paints differ. Emission is light the surface makes,
            // it survives being in shadow, and it is above 1 so the tone map rolls it towards white:
            // it reads as powered rather than as painted.
            var emissive = drawable.mesh.material(forSubmesh: 0).emissive
            if let glow = glowingDrawables[index] { emissive *= glow }
            if let slot = objectiveDrawables.firstIndex(of: index) {
                let taken = run.collected.indices.contains(slot) && run.collected[slot]
                // **Modest, because the whole crate emits and emission is unshaded.** A surface that
                // makes its own light has no light direction, so an object emitting over all of it is
                // flat by definition — which is why a real emissive surface is a strip or a panel,
                // confined by a *map*. `box.obj` cannot have one: Model I/O reads neither `Ke` nor
                // `map_Ke` from an OBJ. So the glow stays low enough that the planks and the sun's
                // shading still carry the shape, and the emission reads as a tint from within.
                emissive = taken ? .zero : SIMD3(0.05, 0.40, 0.18)
                albedo = taken ? SIMD3(0.34, 0.36, 0.34) : SIMD3(0.42, 0.62, 0.45)
            }
            // A lantern is a lamp with a body: the light is a `PunctualLight` and this is the part
            // you can see. Well above 1 so the tone map rolls it towards white.
            if lanternDrawables.contains(index) {
                emissive = SIMD3(3.4, 2.1, 0.9)
                albedo = SIMD3(1.0, 0.86, 0.62)
            }
            // The selection glows too, because an editor where you cannot tell what is selected is a
            // way to move the wrong thing.
            if isEditing && index == editor.selection { emissive = SIMD3(1.6, 1.2, 0.3) }
            // **The first submesh's material, and the sample is honest that this is a shortcut.**
            // Uniforms here are per drawable, so a mesh whose submeshes differ in roughness would
            // get the first one's for all of them. Every mesh in this sample has one submesh; a game
            // with multi-material meshes writes a set of uniforms per submesh instead.
            var uniforms = Uniforms(viewProjection: viewProjection,
                                    model: drawable.transform,
                                    normalMatrix: normalMatrix(from: drawable.transform),
                                    albedo: albedo,
                                    sunDirection: sunDirection,
                                    material: drawable.mesh.material(forSubmesh: 0),
                                    specularLOD: environmentLOD,
                                    sunColor: sunIrradiance,
                                    emissive: emissive)
            uniformBuffer.contents().advanced(by: uniformOffset(frameSlot: frameSlot, drawable: index))
                .copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.size)
        }

        // The debris: one set of uniforms for every piece. The box mesh's own place times nothing else —
        // each piece's transform comes from the instance buffer.
        if let box = meshes["box"], !rubble.isEmpty {
            var uniforms = Uniforms(viewProjection: viewProjection,
                                    model: box.nodeTransform,
                                    normalMatrix: normalMatrix(from: box.nodeTransform),
                                    // Weathered: darker and greyer than a whole crate.
                                    albedo: SIMD3(0.62, 0.58, 0.54),
                                    sunDirection: sunDirection,
                                    material: box.material(forSubmesh: 0),
                                    specularLOD: environmentLOD,
                                    sunColor: sunIrradiance,
                                    emissive: .zero)
            uniformBuffer.contents().advanced(by: uniformOffset(frameSlot: frameSlot, drawable: SampleGame.rubbleSlot))
                .copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.size)
        }

        for (index, figure) in figures.prefix(SampleGame.maxFigures).enumerated() {
            var uniforms = Uniforms(viewProjection: viewProjection,
                                    model: figure.transform,
                                    normalMatrix: normalMatrix(from: figure.transform),
                                    // No tint: the figure's colour is its texture's, which is the
                                    // point of it having one.
                                    albedo: SIMD3(repeating: 1),
                                    sunDirection: sunDirection,
                                    material: figureMesh?.material(forSubmesh: 0) ?? Material(),
                                    specularLOD: environmentLOD,
                                    sunColor: sunIrradiance,
                                    // **Times three, and that is the game's call.** A PNG cannot hold
                                    // a value above 1, so an emissive map alone can never be brighter
                                    // than white — and a seam that is exactly white does not read as
                                    // lit. How much brighter is a look decision, so it lives here.
                                    emissive: (figureMesh?.material(forSubmesh: 0).emissive ?? .zero)
                                        * SampleGame.figureGlow)
            uniformBuffer.contents().advanced(by: uniformOffset(frameSlot: frameSlot, figure: index))
                .copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.size)

            // The palette straight out of the pose — no conversion, because `skinningMatrices` is
            // already exactly what the vertex shader indexes.
            figure.pose.skinningMatrices.withUnsafeBytes { source in
                jointBuffer.contents().advanced(by: jointOffset(frameSlot: frameSlot, figure: index))
                    .copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
    }

    /// Bins this frame's lights into the clusters they reach, and uploads the result.
    ///
    /// **Every frame, because the grid is in view space.** The lights have not moved but the camera
    /// has, and a cell is a piece of the frustum rather than a piece of the world.
    private func writeClusters(frameSlot: Int, camera: Camera) {
        let projectionFovY = Float.radians(fromDegrees: 70)
        let clustered = ClusteredLights(lights: Array(lightSet.lights.prefix(SampleGame.maxSceneLights)),
                                        grid: SampleGame.clusterGrid,
                                        viewMatrix: camera.viewMatrix,
                                        fovY: projectionFovY,
                                        aspectRatio: aspectRatio,
                                        maximumIndices: SampleGame.maxClusterIndices)

        var lights = lightSet.lights.prefix(SampleGame.maxSceneLights).map(PackedLight.init)
        if let shadowAtlas {
            for (lightIndex, caster) in shadowCasters where lightIndex < lights.count {
                let (offset, scale) = shadowAtlas.tile(forSlot: caster.slot)
                    .uvTransform(atlasResolution: shadowAtlas.resolution)
                lights[lightIndex].shadowTile = SIMD4(offset.x, offset.y, scale, 1)
                lights[lightIndex].shadowViewProjection = caster.viewProjection
            }
        }
        if let shadowCubes {
            for (lightIndex, caster) in cubeCasters where lightIndex < lights.count {
                // **The near plane travels with the light**, because it is what the shader's
                // reference depth is made of: `near / distance`. Reading it from a shader constant
                // instead would be one number written down twice.
                // **The face's texel size travels with the light too.** It was a shader constant
                // written as `2 / 512`, which is a number in two places the moment a game asks for a
                // different resolution — and the failure is a filter kernel of the wrong width, which
                // looks like a bias problem rather than like a stale constant.
                lights[lightIndex].shadowCube = SIMD4(Float(caster.slot), shadowCubes.nearPlane,
                                                      2 / Float(shadowCubes.resolution), 1)
            }
        }
        lights.withUnsafeBytes { source in
            guard let base = source.baseAddress, source.count > 0 else { return }
            sceneLightBuffer.contents()
                .advanced(by: frameSlot * SampleGame.sceneLightStride * SampleGame.maxSceneLights)
                .copyMemory(from: base, byteCount: source.count)
        }
        clustered.ranges.withUnsafeBytes { source in
            guard let base = source.baseAddress, source.count > 0 else { return }
            clusterRangeBuffer.contents()
                .advanced(by: frameSlot * SampleGame.clusterRangeStride
                                        * SampleGame.clusterGrid.clusterCount)
                .copyMemory(from: base, byteCount: source.count)
        }
        clustered.indices.withUnsafeBytes { source in
            guard let base = source.baseAddress, source.count > 0 else { return }
            clusterIndexBuffer.contents()
                .advanced(by: frameSlot * MemoryLayout<UInt32>.stride * SampleGame.maxClusterIndices)
                .copyMemory(from: base, byteCount: source.count)
        }
        maxLightsPerCluster = clustered.maxLightsPerCluster

        // **Said once per level, because it is the number that decides the worst fragment's cost.**
        // Per-draw selection made that number a constant the game chose; clustering makes it a fact
        // about the scene, and one worth watching rather than assuming.
        if reportClustersNextFrame {
            reportClustersNextFrame = false
            let grid = SampleGame.clusterGrid
            print("WindageSample: \(lightSet.lights.count) lights binned into "
                  + "\(grid.tilesX)×\(grid.tilesY)×\(grid.slices) clusters — "
                  + "\(clustered.indices.count) entries, busiest cluster holds "
                  + "\(clustered.maxLightsPerCluster)")
        }
    }

    /// Which lights got a tile of the shadow atlas this frame, and where they look from.
    ///
    /// **Spots only, and only as many as there are tiles.** Ranked by how much light they are
    /// putting out, because a lamp nobody can see casting a shadow nobody can see is the tile to give
    /// away first.
    private func assignShadowTiles() -> [(lightIndex: Int, caster: ShadowAtlas.Caster)] {
        guard let shadowAtlas else { return [] }
        let candidates = lightSet.lights.enumerated()
            .filter { $0.element.cone != nil }
            .sorted { PunctualLight.luminance($0.element.color) * $0.element.range
                    > PunctualLight.luminance($1.element.color) * $1.element.range }
            .prefix(shadowAtlas.slotCount)

        return candidates.enumerated().compactMap { slot, entry in
            guard let matrix = ShadowAtlas.viewProjection(for: entry.element) else { return nil }
            return (entry.offset, ShadowAtlas.Caster(slot: slot, viewProjection: matrix))
        }
    }

    /// Which point lights got a cube this frame.
    ///
    /// **The same ranking as the tiles and a much smaller number.** A cube is six passes, so the
    /// question "which lamp deserves one" is six times as sharp as it is for a spot — and a level with
    /// three braziers is going to have to answer it.
    private func assignShadowCubes() -> [(lightIndex: Int, caster: ShadowCubes.Caster)] {
        guard let shadowCubes else { return [] }
        return lightSet.lights.enumerated()
            .filter { $0.element.cone == nil }
            .sorted { PunctualLight.luminance($0.element.color) * $0.element.range
                    > PunctualLight.luminance($1.element.color) * $1.element.range }
            .prefix(shadowCubes.slotCount)
            .enumerated()
            .map { slot, entry in
                (entry.offset, ShadowCubes.Caster(slot: slot, position: entry.element.position,
                                                  range: entry.element.range))
            }
    }

    /// The most lights any one cluster held last frame — **the number that decides the worst
    /// fragment's cost**, and the one clustering exists to keep small.
    private(set) var maxLightsPerCluster = 0
    private var reportClustersNextFrame = true
    private var reportCubeDrawsNextFrame = true

    /// The shadow pass, before anything is drawn to the screen.
    func encodePrePasses(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, interpolation: Float) {
        writeUniforms(frameSlot: frameSlot, interpolation: interpolation)
        rubbleCopies = rubbleBuffer.write(rubble, frameSlot: frameSlot)
        guard let shadowMap else { return }

        let view = displayCamera(interpolation)
        let matrices = shadowMap.updateMatrices(frameSlot: frameSlot, camera: view,
                                                sunDirection: sunDirection)

        let cascades = SampleGame.cascades
        let projection = simd_float4x4(
            perspectiveFovY: Float.radians(fromDegrees: 70), aspectRatio: aspectRatio, nearZ: 0.1)
        var frame = FrameUniforms(
            cascadeViewProjection: (matrices[0], matrices[1], matrices[2], matrices[3]),
            inverseViewProjection: simd_inverse(simd_mul(projection, view.viewMatrix)),
            view: view.viewMatrix,
            cascadeSplits: cascades.splitVector,
            cascadeBlendStart: cascades.blendStartVector,
            cascadeDepthBias: cascades.depthBiasVector,
            cameraPosition: view.position,
            texelSize: 1 / Float(cascades.resolution),
            viewportSize: viewportSize,
            clusters: PackedClusterGrid(SampleGame.clusterGrid))
        shadowFrameBuffer.contents().advanced(by: frameSlot * SampleGame.shadowFrameStride)
            .copyMemory(from: &frame, byteCount: MemoryLayout<FrameUniforms>.size)

        guard let shadowPipeline else { return }
        var batches = [ShadowBatch(
            pipeline: shadowPipeline,
            count: visibleDrawableCount,
            mesh: { self.drawables[$0].mesh.mesh },
            uniformAddress: { self.uniformBuffer.gpuAddress
                + UInt64(self.uniformOffset(frameSlot: frameSlot, drawable: $0)) },
            // **`volumes` is index-aligned with `drawables`** — the same loop appends to both, which
            // is the reason the game has one list of "what is there" rather than two.
            bounds: { self.volumes[$0].worldBounds })]

        if let skinnedShadowPipeline, let mesh = figureMesh, visibleFigureCount > 0 {
            batches.append(ShadowBatch(
                pipeline: skinnedShadowPipeline,
                count: visibleFigureCount,
                mesh: { _ in mesh.mesh },
                uniformAddress: { self.uniformBuffer.gpuAddress
                    + UInt64(self.uniformOffset(frameSlot: frameSlot, figure: $0)) },
                jointPaletteAddress: { self.jointBuffer.gpuAddress
                    + UInt64(self.jointOffset(frameSlot: frameSlot, figure: $0)) },
                // **The bind pose, widened.** A skinned mesh's bounds are the pose's, not the file's,
                // and a raised arm leaves the box the loader measured. Half a metre covers this
                // sample's clips; a game with a vault or a dive computes it from the pose instead.
                bounds: { Volume(localBounds: mesh.bounds, transform: self.figures[$0].transform)
                    .worldBounds.expanded(by: 0.5) }))
        }

        // The debris casts too — every piece in one instanced draw per cascade, through a batch that
        // encodes itself.
        if let instancedShadowPipeline, let box = meshes["box"], let copies = rubbleCopies, !rubble.isEmpty {
            let uniforms = uniformBuffer.gpuAddress
                + UInt64(uniformOffset(frameSlot: frameSlot, drawable: SampleGame.rubbleSlot))
            let batchList = rubble.batches
            // The debris is small enough to draw whole into every pass; a game with a wood culls per `pass`.
            batches.append(ShadowBatch(pipeline: instancedShadowPipeline) { encoder, table, _ in
                table.setAddress(uniforms, index: ShadowBufferIndex.uniforms)
                for (bufferIndex, vertexBuffer) in box.mesh.vertexBuffers.enumerated() {
                    table.setAddress(vertexBuffer.buffer.gpuAddress + UInt64(vertexBuffer.offset), index: bufferIndex)
                }
                for batch in batchList {
                    table.setAddress(copies.gpuAddress + UInt64(batch.byteOffset),
                                     index: ShadowBufferIndex.instances)
                    for submesh in box.mesh.submeshes {
                        encoder.drawIndexedPrimitives(primitiveType: submesh.primitiveType,
                                                      indexCount: submesh.indexCount,
                                                      indexType: submesh.indexType,
                                                      indexBuffer: submesh.indexBuffer.buffer.gpuAddress
                                                          + UInt64(submesh.indexBuffer.offset),
                                                      indexBufferLength: submesh.indexBuffer.length,
                                                      instanceCount: batch.count)
                    }
                }
            })
        }

        shadowMap.encode(into: commandBuffer, frameSlot: frameSlot, batches: batches)

        // **The lamps' maps, after the sun's and in one pass of their own.** Same batches, same
        // pipelines — a spot's shadow map is a perspective render, which is the shape the cascade
        // pipelines already are.
        if let shadowAtlas, !shadowCasters.isEmpty {
            shadowAtlas.encode(into: commandBuffer, frameSlot: frameSlot,
                               casters: shadowCasters.map(\.caster), batches: batches)
        }

        // **And the lamps that point nowhere, six faces each.** Reported once per level because six
        // times the passes is the sort of cost that should be visible rather than inferred.
        if let shadowCubes, !cubeCasters.isEmpty {
            let draws = shadowCubes.encode(into: commandBuffer, frameSlot: frameSlot,
                                           casters: cubeCasters.map(\.caster), batches: batches)
            if reportCubeDrawsNextFrame {
                reportCubeDrawsNextFrame = false
                // A batch that encodes itself is one draw per face, culled or not.
                let unculled = cubeCasters.count * ShadowCubes.faceCount
                    * batches.reduce(0) { $0 + ($1.objectCount ?? 1) }
                print("WindageSample: \(cubeCasters.count) point light(s) casting — \(draws) draws "
                      + "against \(unculled) unculled")
            }
        }
    }

    func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])

        argumentTable.setAddress(
            shadowFrameBuffer.gpuAddress + UInt64(frameSlot * SampleGame.shadowFrameStride), index: 2)
        if let shadowMap { argumentTable.setTexture(shadowMap.texture.gpuResourceID, index: 0) }
        if let shadowAtlas { argumentTable.setTexture(shadowAtlas.texture.gpuResourceID, index: 7) }
        if let shadowCubes { argumentTable.setTexture(shadowCubes.texture.gpuResourceID, index: 8) }
        if let environment {
            argumentTable.setTexture(environment.specular.gpuResourceID, index: 3)
            argumentTable.setTexture(environment.irradiance.gpuResourceID, index: 4)
        }

        argumentTable.setAddress(
            sceneLightBuffer.gpuAddress
                + UInt64(frameSlot * SampleGame.sceneLightStride * SampleGame.maxSceneLights),
            index: 4)
        argumentTable.setAddress(
            clusterRangeBuffer.gpuAddress
                + UInt64(frameSlot * SampleGame.clusterRangeStride
                                   * SampleGame.clusterGrid.clusterCount),
            index: 5)
        argumentTable.setAddress(
            clusterIndexBuffer.gpuAddress
                + UInt64(frameSlot * MemoryLayout<UInt32>.stride * SampleGame.maxClusterIndices),
            index: 6)

        encodeSky(into: encoder)

        for (index, drawable) in drawables.prefix(SampleGame.maxDrawables).enumerated() {
            argumentTable.setAddress(
                uniformBuffer.gpuAddress + UInt64(uniformOffset(frameSlot: frameSlot, drawable: index)),
                index: 1)

            let mesh = drawable.mesh.mesh
            for (bufferIndex, vertexBuffer) in mesh.vertexBuffers.enumerated() {
                argumentTable.setAddress(vertexBuffer.buffer.gpuAddress + UInt64(vertexBuffer.offset),
                                         index: bufferIndex)
            }
            let maps = drawable.maps
            for (submeshIndex, submesh) in mesh.submeshes.enumerated() {
                // **Per submesh, because a material is per submesh** — that is the unit a file binds
                // one to, and a mesh with a painted body and a metal fitting is two submeshes.
                bindSurface(maps.indices.contains(submeshIndex) ? maps[submeshIndex] : nil,
                            drawable.normals.indices.contains(submeshIndex)
                                ? drawable.normals[submeshIndex] : nil,
                            drawable.orm.indices.contains(submeshIndex)
                                ? drawable.orm[submeshIndex] : nil,
                            drawable.glow.indices.contains(submeshIndex)
                                ? drawable.glow[submeshIndex] : nil)
                encoder.drawIndexedPrimitives(primitiveType: submesh.primitiveType,
                                              indexCount: submesh.indexCount,
                                              indexType: submesh.indexType,
                                              indexBuffer: submesh.indexBuffer.buffer.gpuAddress
                                                  + UInt64(submesh.indexBuffer.offset),
                                              indexBufferLength: submesh.indexBuffer.length)
            }
        }

        encodeRubble(into: encoder, frameSlot: frameSlot)
        encodeFigures(into: encoder, frameSlot: frameSlot)

        // **Last, into the scene rather than onto the interface**: a spark goes through the tone map
        // like the lamp it came off. After everything opaque, so depth can hide the ones behind.
        if let particleRenderer {
            let view = displayCamera(interpolation)
            let projection = simd_float4x4(
                perspectiveFovY: Float.radians(fromDegrees: 70), aspectRatio: aspectRatio, nearZ: 0.1)
            particleRenderer.draw(particles, into: encoder, frameSlot: frameSlot,
                                  viewProjection: simd_mul(projection, view.viewMatrix),
                                  cameraRight: view.right, cameraUp: view.up, matterLight: matterLight)
        }
    }

    /// The sky, drawn first and covered by everything else.
    ///
    /// **The same cube the surfaces reflect.** A flat clear colour behind a metal object reflecting a
    /// sky with a sun in it is two skies in one picture, and that is among the first things an eye
    /// finds wrong with a render.
    private func encodeSky(into encoder: MTL4RenderCommandEncoder) {
        guard let skyPipeline, let skyDepthState, environment != nil else { return }
        encoder.setRenderPipelineState(skyPipeline)
        encoder.setDepthStencilState(skyDepthState)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)

        // Put the scene's state back, since the sky borrowed the encoder.
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
    }

    /// Binds a base-colour map, falling back to the store's white pixel.
    ///
    /// **Something is always bound.** The alternative is a shader that branches on whether a texture
    /// exists, or a second pipeline compiled without one — a branch per fragment, or twice the
    /// pipelines. White multiplies to nothing.
    private func bindSurface(_ base: MTLTexture?, _ normal: MTLTexture?, _ orm: MTLTexture?,
                             _ glow: MTLTexture?) {
        if let resolved = base ?? textures?.white {
            argumentTable.setTexture(resolved.gpuResourceID, index: 1)
        }
        // **The normal fallback is not the white one.** A white pixel decodes to the normal (1, 1, 1),
        // which tilts every surface diagonally and lights the whole scene wrongly.
        if let resolved = normal ?? textures?.flatNormal {
            argumentTable.setTexture(resolved.gpuResourceID, index: 2)
        }
        // **White is exactly right here**, because the shader multiplies: a surface with no map keeps
        // its material's own occlusion, roughness and metalness untouched.
        if let resolved = orm ?? textures?.white {
            argumentTable.setTexture(resolved.gpuResourceID, index: 5)
        }
        // **White again, and again because it is multiplied.** A surface with no emissive map emits
        // whatever its material says — which for almost everything is nothing at all.
        if let resolved = glow ?? textures?.white {
            argumentTable.setTexture(resolved.gpuResourceID, index: 6)
        }
    }

    /// The characters, in one pipeline change rather than one per object.
    ///
    /// **Same fragment shader, same shadow map, same uniforms** — a skinned mesh differs from the
    /// rest of the scene in exactly two things: where its vertices are and what moved them there.
    /// The debris: every piece in one draw per submesh, and one more per cascade for its shadows —
    /// see `encodePrePasses`.
    private func encodeRubble(into encoder: MTL4RenderCommandEncoder, frameSlot: Int) {
        guard let instancedPipeline, let box = meshes["box"], let copies = rubbleCopies else { return }
        encoder.setRenderPipelineState(instancedPipeline)
        defer { encoder.setRenderPipelineState(pipeline) }
        argumentTable.setAddress(
            uniformBuffer.gpuAddress + UInt64(uniformOffset(frameSlot: frameSlot, drawable: SampleGame.rubbleSlot)),
            index: 1)
        let mesh = box.mesh
        for (bufferIndex, vertexBuffer) in mesh.vertexBuffers.enumerated() {
            argumentTable.setAddress(vertexBuffer.buffer.gpuAddress + UInt64(vertexBuffer.offset), index: bufferIndex)
        }
        let maps = baseColorMaps["box"] ?? [], normals = normalMaps["box"] ?? []
        let orm = ormMaps["box"] ?? [], glow = emissiveMaps["box"] ?? []
        for batch in rubble.batches {
            argumentTable.setAddress(copies.gpuAddress + UInt64(batch.byteOffset), index: 7)
            for (submeshIndex, submesh) in mesh.submeshes.enumerated() {
                bindSurface(maps.indices.contains(submeshIndex) ? maps[submeshIndex] : nil,
                            normals.indices.contains(submeshIndex) ? normals[submeshIndex] : nil,
                            orm.indices.contains(submeshIndex) ? orm[submeshIndex] : nil,
                            glow.indices.contains(submeshIndex) ? glow[submeshIndex] : nil)
                encoder.drawIndexedPrimitives(primitiveType: submesh.primitiveType,
                                              indexCount: submesh.indexCount,
                                              indexType: submesh.indexType,
                                              indexBuffer: submesh.indexBuffer.buffer.gpuAddress
                                                  + UInt64(submesh.indexBuffer.offset),
                                              indexBufferLength: submesh.indexBuffer.length,
                                              instanceCount: batch.count)
            }
        }
    }

    private func encodeFigures(into encoder: MTL4RenderCommandEncoder, frameSlot: Int) {
        guard let skinnedPipeline, let mesh = figureMesh?.mesh, visibleFigureCount > 0 else { return }
        encoder.setRenderPipelineState(skinnedPipeline)

        for index in 0..<visibleFigureCount {
            argumentTable.setAddress(
                uniformBuffer.gpuAddress + UInt64(uniformOffset(frameSlot: frameSlot, figure: index)),
                index: 1)
            argumentTable.setAddress(
                jointBuffer.gpuAddress + UInt64(jointOffset(frameSlot: frameSlot, figure: index)),
                index: 3)

            for (bufferIndex, vertexBuffer) in mesh.vertexBuffers.enumerated() {
                argumentTable.setAddress(vertexBuffer.buffer.gpuAddress + UInt64(vertexBuffer.offset),
                                         index: bufferIndex)
            }
            for (submeshIndex, submesh) in mesh.submeshes.enumerated() {
                bindSurface(figureMaps.indices.contains(submeshIndex) ? figureMaps[submeshIndex] : nil,
                            figureNormalMaps.indices.contains(submeshIndex)
                                ? figureNormalMaps[submeshIndex] : nil,
                            figureORMMaps.indices.contains(submeshIndex)
                                ? figureORMMaps[submeshIndex] : nil,
                            figureEmissiveMaps.indices.contains(submeshIndex)
                                ? figureEmissiveMaps[submeshIndex] : nil)
                encoder.drawIndexedPrimitives(primitiveType: submesh.primitiveType,
                                              indexCount: submesh.indexCount,
                                              indexType: submesh.indexType,
                                              indexBuffer: submesh.indexBuffer.buffer.gpuAddress
                                                  + UInt64(submesh.indexBuffer.offset),
                                              indexBufferLength: submesh.indexBuffer.length)
            }
        }
    }

    func encodeHUD(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
        guard let hud else { return }
        hud.begin(viewportSize: viewportSize)

        // **Sized against the drawable, not in raw pixels.** The viewport is in *pixels*, and on a
        // Retina display that is twice the points — so text asked for at "20" rendered at ten points
        // and was reported as unreadable. Scaling against a 1080-pixel reference is
        // resolution-independent rather than tuned to one machine.
        let scale = max(viewportSize.y / 1080, 0.75)
        let title = 30 * scale, body = 21 * scale, hint = 17 * scale
        let margin = 22 * scale
        let white = InterfaceColor(srgb: SIMD4(1, 1, 1, 0.95))
        let gold = InterfaceColor(srgb: SIMD4(1.0, 0.85, 0.25, 1))
        let green = InterfaceColor(srgb: SIMD4(0.45, 0.95, 0.6, 1))
        let red = InterfaceColor(srgb: SIMD4(1.0, 0.45, 0.4, 1))

        // **`y` is a baseline and glyphs draw upward from it**, so the first line starts a full
        // line-height down or its ascenders run off the top edge — which is what "COURTYARD touches
        // the top" was.
        var y = margin + title
        _ = hud.text("\(level.name)   \(levelIndex + 1)/\(SampleLevel.names.count)",
                     atBaseline: SIMD2(margin, y), pointSize: title, color: white)
        y += title * 1.5

        let clock = String(format: "%02d:%02d", Int(run.remaining) / 60, Int(run.remaining) % 60)
        _ = hud.text("CRATES \(run.found)/\(run.objectives.count)     \(clock)",
                     atBaseline: SIMD2(margin, y),
                     pointSize: body, color: run.remaining < 15 ? red : white)
        y += body * 1.4

        if let best = run.best {
            _ = hud.text(String(format: "best %.1fs   ·   %d of %d runs won",
                         best, run.progress.wins, run.progress.runs),
                         atBaseline: SIMD2(margin, y), pointSize: hint, color: white)
        } else {
            _ = hud.text("no run finished yet", atBaseline: SIMD2(margin, y), pointSize: hint, color: white)
        }
        // **Said, not left to be discovered.** Crouch let go under a beam does nothing you can see
        // except not standing; without a word, that reads as the key being broken.
        if self.body.isCrouchForced && !isEditing {
            _ = hud.text("NO ROOM TO STAND",
                         atBaseline: SIMD2((viewportSize.x - hud.width(of: "NO ROOM TO STAND", pointSize: body)) / 2,
                                           viewportSize.y * 0.62),
                         pointSize: body, color: white)
        }
        y += hint * 1.6

        switch run.mode {
        case .paused:
            // Not while the settings screen is open: it paused the run itself, it takes every key
            // including P, and "p to resume" would be an instruction that does nothing.
            if menu == nil {
                _ = hud.text("PAUSED — p to resume", atBaseline: SIMD2(margin, y), pointSize: body, color: gold)
            }
        case .won(let seconds):
            _ = hud.text(String(format: "ALL FOUND in %.1fs — r to run again", seconds),
                         atBaseline: SIMD2(margin, y), pointSize: body, color: green)
        case .lost:
            _ = hud.text("OUT OF TIME — r to run again", atBaseline: SIMD2(margin, y),
                         pointSize: body, color: red)
        case .playing:
            break
        }

        if isEditing {
            let what = editor.selected.map {
                "\($0.mesh)  yaw \(Int($0.yaw * 180 / .pi))°  scale \(String(format: "%.2f", $0.scale))"
                    + ($0.light.map { String(format: "  lamp %.0f", $0.color.max()) } ?? "")
            }
            let kinds = addableKinds
            let adding = kinds.isEmpty ? "" : "   i adds \(kindName(kinds[min(addKind, kinds.count - 1)]))"
            _ = hud.text("EDIT\(editor.isDirty ? " •" : "")   \(what ?? "aim and click to pick")\(adding)",
                         atBaseline: SIMD2(margin, y + body * 1.4), pointSize: body, color: gold)
            _ = hud.text("click pick · arrows move · q/e up · a/d turn · -/= scale · b copy · ⌫ delete"
                         + " · l lamp · [ ] lamp height · , . lamp brightness · t kind · i add",
                         atBaseline: SIMD2(margin, viewportSize.y - margin - hint * 1.4),
                         pointSize: hint, color: white)
            _ = hud.text("⌘S save · ⌘Z undo · ⌘R redo · ⌘⌫ revert to shipped · tab back to walking",
                         atBaseline: SIMD2(margin, viewportSize.y - margin), pointSize: hint, color: white)
        } else {
            // **The hints follow whichever device is actually plugged in.** Telling somebody holding
            // a controller to press WASD is a small lie the game is in a position to avoid, and the
            // engine already reports which it has.
            // **From the bindings, not typed in.** The hint that said "shift sprint" while Shift did
            // nothing was written by hand; one that reads the bindings cannot disagree with them.
            let b = settings.bindings
            let directions = [b[.forward], b[.left], b[.back], b[.right]].map { $0?.name ?? "" }
            let move = directions.allSatisfy { $0.count == 1 }
                ? directions.joined() : directions.joined(separator: "/")
            let moving = input.isGamepadConnected
                ? "left stick move · right stick look · "
                    + "\((settings.padBindings[.jump]?.name(on: input.gamepad) ?? "").lowercased()) jump · "
                    + "\((settings.padBindings[.crouch]?.name(on: input.gamepad) ?? "").lowercased()) crouch · "
                    + "menu button settings"
                : "\(move) move · \((b[.sprint]?.name ?? "").lowercased()) sprint · "
                    + "\((b[.jump]?.name ?? "").lowercased()) jump · \((b[.crouch]?.name ?? "").lowercased()) crouch · "
                    + "click to capture"
            _ = hud.text(moving, atBaseline: SIMD2(margin, viewportSize.y - margin - hint * 1.4),
                         pointSize: hint, color: white)
            _ = hud.text("o settings · p pause · r restart · n next level · m tone map · tab edit",
                         atBaseline: SIMD2(margin, viewportSize.y - margin), pointSize: hint, color: white)
        }

        if let menu { drawSettings(menu, on: hud, scale: scale) }

        // A centre dot, so turning has something to turn about.
        let dot = 3 * scale
        hud.fillRect(origin: SIMD2(viewportSize.x / 2 - dot, viewportSize.y / 2 - dot),
                     size: SIMD2(dot * 2, dot * 2), color: white)
        // **Last, over everything.** The engine's own name, for as long as it lasts.
        splash?.draw(into: hud, viewportSize: viewportSize)
        hud.draw(into: encoder, frameSlot: frameSlot)
    }
}
