//
//  Level.swift
//  WindageEngine
//

import Foundation
import simd

/// A level, as **data rather than code**.
///
/// ### Why this exists, and what it is deliberately not
///
/// Before this, the engine's only consumer described its level in Swift: arrays of structs, compiled
/// into the game. That works exactly once, for the person who owns the source. **Nobody else can
/// author a level for a game built that way** — not a designer without Xcode, not a modder, not a
/// tool, and not an editor, which is the thing this is the prerequisite for. An engine whose levels
/// are source files is a library with a game attached.
///
/// So a level is a file. It is JSON because a format nobody can read by hand is a format nobody can
/// fix at 2am, and because the first "editor" for any format is a text editor.
///
/// ### What the engine knows about a level, and what it refuses to know
///
/// The engine knows a level is **things placed in space** and **points that mean something**. It does
/// not know what they mean. `Marker.kind` is a string the *game* interprets: one game reads
/// `"target"` and `"firing-position"`, a pirate game would read `"anchorage"`, and the engine reads
/// neither. The same goes for ``Placement/tags``.
///
/// **This is the line that keeps the engine an engine.** The moment `Marker` gains a `.target` case,
/// the format has an opinion about genre, and every game that does not share it is fighting the
/// format. A string and a dictionary are less tidy and cost nothing to be wrong about.
///
/// ### Heights are anchored, not absolute
///
/// A placement stores **how it meets the ground**, not the height it happened to sit at when someone
/// pressed save. Terrain changes — a valley grows a cross-section and every structure in it
/// moved tens of meters — and a level of absolute Y values silently becomes a level of floating and
/// buried buildings. See ``Anchor``.
/// **`nonisolated`, like every other value type here.** A level is data; loading one is I/O and
/// decoding, and tying it to the main actor would mean a game could not read a level off the main
/// thread — which is exactly what a game wants to do while a loading screen is up.
public nonisolated struct Level: Codable, Equatable, Sendable {

    /// **The format's own version, checked on load.**
    ///
    /// A level file outlives the code that wrote it. Without a version, a file written by a newer
    /// build loads into an older one, silently missing whatever it did not understand — and the
    /// failure surfaces as level geometry quietly absent rather than as a refusal to load.
    public static let currentVersion = 1

    /// The format version this level was read as, or ``currentVersion`` for one made in code.
    ///
    /// **Read-only**: set by hand it could write a file the same build then refuses to load.
    public private(set) var formatVersion: Int
    public var name: String

    /// Free-form per-level values the game interprets — a sun angle, a wind seed, a par time.
    ///
    /// **Deliberately `[String: Double]` and not `Any`.** A heterogeneous bag needs custom coding,
    /// makes round-tripping lossy, and invites a level file to become a config file for the whole
    /// game. Anything that is not a number belongs in ``markers`` or in the game's own files.
    public var settings: [String: Double]

    /// The sky this level is under, and therefore what everything in it is lit by.
    ///
    /// **A named thing rather than more entries in ``settings``.** A sky is three colors, two angles
    /// and a sun size; flattened into a scalar dictionary that is fifteen keys with no structure, no
    /// way to say a color is a color, and nothing to stop `skyZenithB` being set and `skyZenithG`
    /// forgotten. It was in the game's source until 2026-09-10, which meant two levels could differ
    /// in where the sun was and not in what the sky looked like.
    ///
    /// Optional, because a level that says nothing about its sky gets a plausible one.
    public var sky: ProceduralSky?

    /// The lamps in this level, beyond the sun its ``sky`` carries.
    ///
    /// **A named list rather than markers with values on them.** A marker is a *place* the game
    /// interprets — a spawn, an objective — and its `values` dictionary is scalars. A light is a
    /// position, a color, a brightness and a range, and expressing it as five loose numbers under a
    /// marker means nothing checks that they belong together.
    public var lights: [PunctualLight]

    public var placements: [Placement]
    public var markers: [Marker]

    /// What the ground itself is made of — the terrain, wherever no placement is under the feet.
    /// The game's word, like ``Placement/surface``.
    public var groundSurface: String?

    /// What is under the feet: the surface of the placement stood on, or the ground's when that is
    /// `nil`. **The one question a footstep asks**, answered from the level rather than from a guess.
    ///
    /// Pass the *placement's* index. A game that built ``CharacterController/Surroundings`` from some
    /// placements — its solid ones — maps ``CharacterController/groundSolid`` back to the placement it
    /// came from first. Returns `nil` for a placement that names no surface, so a missing one can be
    /// noticed rather than papered over with the ground's.
    public func surface(standingOn placement: Int?) -> String? {
        guard let placement else { return groundSurface }
        return placements.indices.contains(placement) ? placements[placement].surface : nil
    }

    public init(name: String,
                settings: [String: Double] = [:],
                sky: ProceduralSky? = nil,
                lights: [PunctualLight] = [],
                placements: [Placement] = [],
                markers: [Marker] = [],
                groundSurface: String? = nil) {
        self.formatVersion = Level.currentVersion
        self.name = name
        self.settings = settings
        self.sky = sky
        self.lights = lights
        self.placements = placements
        self.markers = markers
        self.groundSurface = groundSurface
    }

    // MARK: - Codable
    //
    // **Written by hand rather than synthesised, so that every field but the version is optional.**
    // A level file is edited by hand as often as by a tool, and the synthesised decoder throws on a
    // missing key — so adding `lights` to this type would have refused every level already written,
    // including the ones a player edited and saved into Application Support.
    //
    // The version is the one thing that must be there: it is what makes a file readable at all.

    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, settings, sky, lights, groundSurface, placements, markers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "UNTITLED"
        settings = try container.decodeIfPresent([String: Double].self, forKey: .settings) ?? [:]
        sky = try container.decodeIfPresent(ProceduralSky.self, forKey: .sky)
        lights = try container.decodeIfPresent([PunctualLight].self, forKey: .lights) ?? []
        placements = try container.decodeIfPresent([Placement].self, forKey: .placements) ?? []
        markers = try container.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        groundSurface = try container.decodeIfPresent(String.self, forKey: .groundSurface)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(name, forKey: .name)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(sky, forKey: .sky)
        // **Omitted when empty**, so a level with no lamps does not carry an empty array explaining
        // that it has none. Same for the sky above.
        if !lights.isEmpty { try container.encode(lights, forKey: .lights) }
        try container.encodeIfPresent(groundSurface, forKey: .groundSurface)
        try container.encode(placements, forKey: .placements)
        try container.encode(markers, forKey: .markers)
    }

    /// The sky to light this level with, whatever the file did or did not say.
    ///
    /// ### The migration, and why it is here rather than in a game
    ///
    /// **Levels already exist on disk that say `sunPitch` and `sunYaw` in ``settings``** — including
    /// any a player edited and saved, which live in Application Support and are not something this
    /// repository can rewrite. Those two keys are how the sun was expressed before there was a sky,
    /// so a file with them and no `sky` block still means something, and it means it exactly.
    ///
    /// Reading them here rather than in a game is the difference between one migration and one per
    /// consumer.
    ///
    /// **Part of format version 1, and kept for as long as version 1 loads.** A level with a `sky`
    /// block ignores the two keys; one with neither gets the default sky. Dropping the migration would
    /// change what an existing file looks like, so it can only go with a format version that says so.
    public var resolvedSky: ProceduralSky {
        if let sky { return sky }
        guard let pitch = settings["sunPitch"], let yaw = settings["sunYaw"] else {
            return ProceduralSky()
        }
        return ProceduralSky(sunPitchDegrees: Float(pitch), sunYawDegrees: Float(yaw))
    }

    /// How a placement meets the ground.
    public nonisolated enum Anchor: String, Codable, Equatable, Sendable {
        /// `y` is a world height. For things that genuinely float — a gantry, a sign, an aircraft.
        case absolute
        /// `y` is an offset from the ground under the placement's origin.
        case ground
        /// `y` is an offset from the **lowest** ground under the placement's footprint, so a long
        /// building on a slope beds into the hill rather than standing with one end in the air.
        case beddedFootprint
    }

    /// One thing, placed.
    public nonisolated struct Placement: Codable, Equatable, Sendable {
        /// The mesh's resource name. The engine does not resolve it — the game does, from wherever
        /// its meshes live.
        public var mesh: String
        /// Meters. `y` is interpreted per ``anchor``.
        public var position: SIMD3<Float>
        /// Radians about +Y.
        public var yaw: Float
        public var scale: Float
        public var anchor: Anchor
        /// Game-defined labels — `"solid"`, `"cover"`, `"decorative"`. The engine passes them through.
        public var tags: [String]

        /// A lamp this thing carries — a brazier's flame, a lantern on a post, a light fitting.
        ///
        /// **In the placement's own space**: `position` is an offset from the placement's origin and a
        /// cone's `direction` is in its frame, so moving, turning or copying the placement takes the
        /// light with it. Resolve it with ``Level/resolvedLights(on:)``.
        ///
        /// > **Why a lamp is not just another entry in ``Level/lights``.** A brazier and its flame
        /// > were two entries in one file until 2026-09-11, kept together by a test. Moving the
        /// > brazier in the in-game editor left the pool of light on the floor where it had been.
        ///
        /// The offset scales with the placement — a brazier twice the size has its flame twice as
        /// high — and the range and brightness do not, because a light's reach is a property of the
        /// lamp rather than of the object holding it.
        public var light: PunctualLight?

        /// What this is made of, for what a foot on it sounds like — `"stone"`, `"wood"`, `"metal"`.
        ///
        /// **The game's word, like ``tags``**: the engine does not know what sounds a game has, only
        /// that a footstep needs to ask. Read it with ``Level/surface(standingOn:)``, which also answers
        /// for the ground.
        ///
        /// > **Why it is in the level and not guessed.** A game knows which solid its player is
        /// > standing on (``CharacterController/groundSolid``) and nothing about what that solid is.
        /// > The sample filled the gap with "every solid is stone, the ground is dirt", which was true of
        /// > its two levels only by accident — and a crate would have rung like a flagstone.
        public var surface: String?

        /// A sound this thing makes for as long as it is there — a brazier's crackle, a generator's
        /// hum — at an offset in its own space, like ``light``, so it moves and copies with it.
        /// Resolve it with ``Level/carriedSounds(on:)``; play it with ``AudioEngine/startLoop(_:at:volume:)``.
        public var sound: CarriedSound?

        /// **One initializer, every field.** The engine is built from source with every game that uses
        /// it, so a defaulted parameter added here costs no consumer a link failure — the reason a
        /// second initializer was once kept beside this one.
        public init(mesh: String,
                    position: SIMD3<Float>,
                    yaw: Float = 0,
                    scale: Float = 1,
                    anchor: Anchor = .ground,
                    tags: [String] = [],
                    light: PunctualLight? = nil,
                    surface: String? = nil,
                    sound: CarriedSound? = nil) {
            self.mesh = mesh
            self.position = position
            self.yaw = yaw
            self.scale = scale
            self.anchor = anchor
            self.tags = tags
            self.light = light
            self.surface = surface
            self.sound = sound
        }

        // Written long-hand so the JSON stays small and stable: yaw, scale, anchor and tags are all
        // omitted at their defaults. A level of four hundred props is mostly defaults, and a format
        // that writes them all is four times the file and four times the diff.
        private enum CodingKeys: String, CodingKey {
            case mesh, position, yaw, scale, anchor, tags, light, surface, sound
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mesh = try container.decode(String.self, forKey: .mesh)
            position = try container.decode(SIMD3<Float>.self, forKey: .position)
            yaw = try container.decodeIfPresent(Float.self, forKey: .yaw) ?? 0
            scale = try container.decodeIfPresent(Float.self, forKey: .scale) ?? 1
            anchor = try container.decodeIfPresent(Anchor.self, forKey: .anchor) ?? .ground
            tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
            light = try container.decodeIfPresent(PunctualLight.self, forKey: .light)
            surface = try container.decodeIfPresent(String.self, forKey: .surface)
            sound = try container.decodeIfPresent(CarriedSound.self, forKey: .sound)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(mesh, forKey: .mesh)
            try container.encode(position, forKey: .position)
            if yaw != 0 { try container.encode(yaw, forKey: .yaw) }
            if scale != 1 { try container.encode(scale, forKey: .scale) }
            if anchor != .ground { try container.encode(anchor, forKey: .anchor) }
            if !tags.isEmpty { try container.encode(tags, forKey: .tags) }
            try container.encodeIfPresent(light, forKey: .light)
            try container.encodeIfPresent(surface, forKey: .surface)
            try container.encodeIfPresent(sound, forKey: .sound)
        }
    }

    /// A looping sound a placement makes: a name the game loads, where on the placement it comes from,
    /// and how loud.
    public nonisolated struct CarriedSound: Codable, Equatable, Sendable {
        public var name: String
        /// In the placement's own space — scaled and turned with it.
        public var offset: SIMD3<Float>
        public var volume: Float

        public init(name: String, offset: SIMD3<Float> = .zero, volume: Float = 1) {
            self.name = name
            self.offset = offset
            self.volume = volume
        }

        private enum CodingKeys: String, CodingKey { case name, offset, volume }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            offset = try container.decodeIfPresent(SIMD3<Float>.self, forKey: .offset) ?? .zero
            volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            if offset != .zero { try container.encode(offset, forKey: .offset) }
            if volume != 1 { try container.encode(volume, forKey: .volume) }
        }
    }

    /// A point that means something to the game.
    ///
    /// Spawns, objectives, patrol nodes, cameras, trigger volumes' centers. **``kind`` is the game's
    /// word, not the engine's** — see the type's own notes.
    public nonisolated struct Marker: Codable, Equatable, Sendable {
        public var kind: String
        public var name: String?
        public var position: SIMD3<Float>
        public var anchor: Anchor
        /// Radians about +Y — which way it faces, where that means anything.
        public var yaw: Float
        /// Per-marker numbers the game interprets: a radius, a delay, a difficulty.
        public var values: [String: Double]

        public init(kind: String,
                    name: String? = nil,
                    position: SIMD3<Float>,
                    anchor: Anchor = .ground,
                    yaw: Float = 0,
                    values: [String: Double] = [:]) {
            self.kind = kind
            self.name = name
            self.position = position
            self.anchor = anchor
            self.yaw = yaw
            self.values = values
        }

        private enum CodingKeys: String, CodingKey { case kind, name, position, anchor, yaw, values }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            position = try container.decode(SIMD3<Float>.self, forKey: .position)
            anchor = try container.decodeIfPresent(Anchor.self, forKey: .anchor) ?? .ground
            yaw = try container.decodeIfPresent(Float.self, forKey: .yaw) ?? 0
            values = try container.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encode(position, forKey: .position)
            if anchor != .ground { try container.encode(anchor, forKey: .anchor) }
            if yaw != 0 { try container.encode(yaw, forKey: .yaw) }
            if !values.isEmpty { try container.encode(values, forKey: .values) }
        }
    }

    // MARK: - Queries

    /// Every placement carrying a tag. The game's way of asking "what is solid here".
    public func placements(tagged tag: String) -> [Placement] {
        placements.filter { $0.tags.contains(tag) }
    }

    /// Every marker of a kind, in file order — which is authoring order, and therefore stable.
    public func markers(ofKind kind: String) -> [Marker] {
        markers.filter { $0.kind == kind }
    }
}

// MARK: - Anchors

nonisolated extension Level {

    /// What the engine needs from the game to turn an anchored placement into a world position.
    ///
    /// **Closures rather than a protocol the game must conform to, and rather than the engine owning
    /// terrain.** Only the game knows what its ground is — one game's is a height *function* with no
    /// mesh behind it — and only the game knows how big its meshes are. What the engine does know is
    /// what an anchor *means*, and that meaning is identical in every game, so it lives here instead
    /// of being re-derived per title.
    public struct Ground: Sendable {
        private let heightFunction: @Sendable (Float, Float) -> Float
        private let footprintFunction: @Sendable (String) -> [SIMD2<Float>]

        /// - Parameters:
        ///   - height: ground height at a world x and z, in that order.
        ///   - footprintCorners: a mesh's footprint corners in **its own model space**, by mesh name, for
        ///     ``Anchor/beddedFootprint``. Returning none is fine — the placement then beds on its origin
        ///     alone.
        public init(height: @escaping @Sendable (_ x: Float, _ z: Float) -> Float,
                    footprintCorners: @escaping @Sendable (_ mesh: String) -> [SIMD2<Float>] = { _ in [] }) {
            self.heightFunction = height
            self.footprintFunction = footprintCorners
        }

        /// Ground height at a world x/z.
        public func height(atX x: Float, z: Float) -> Float { heightFunction(x, z) }

        /// A mesh's footprint corners in its own model space; empty when the game gave none.
        public func footprintCorners(of mesh: String) -> [SIMD2<Float>] { footprintFunction(mesh) }
    }

    /// Where a placement actually stands.
    ///
    /// The stored `y` is an **offset** for the ground anchors and a world height for `.absolute`, so
    /// a level authored on one terrain still sits on the ground after the terrain changes.
    public func worldPosition(of placement: Placement, on ground: Ground) -> SIMD3<Float> {
        let x = placement.position.x, z = placement.position.z
        switch placement.anchor {
        case .absolute:
            return placement.position
        case .ground:
            return SIMD3(x, ground.height(atX: x, z: z) + placement.position.y, z)
        case .beddedFootprint:
            // The **lowest** corner, not the average and not the origin: bedding to anything higher
            // leaves the low end of a long building in the air, which is the failure this exists for.
            //
            // **Turned by `turned(_:by:)`, the same turn `transform(of:on:)` draws with.** This used
            // its own inline rotation until 2026-09-11, and it turned the other way: every renderer
            // in the studio draws a placement with the standard right-handed turn about +Y, and this
            // sampled the ground under the corners of the placement's *mirror image*. On flat ground
            // or for a square footprint nothing shows; a long building turned on a slope was bedded
            // on corners it does not have.
            var lowest = ground.height(atX: x, z: z)
            for corner in ground.footprintCorners(of: placement.mesh) {
                let offset = Level.turned(corner * placement.scale, by: placement.yaw)
                lowest = min(lowest, ground.height(atX: x + offset.x, z: z + offset.y))
            }
            return SIMD3(x, lowest + placement.position.y, z)
        }
    }

    /// Every light in the level, in the world: the free-standing ``lights`` first, then each
    /// placement's own, in placement order.
    public func resolvedLights(on ground: Ground) -> [PunctualLight] {
        lights + carriedLights(on: ground).map(\.light)
    }

    /// A lamp a placement carries, in the world — see ``carriedLights(on:)``.
    public struct CarriedLightInWorld: Equatable, Sendable {
        /// The index in ``Level/placements`` of the placement carrying it.
        public var placement: Int
        /// The lamp, its position and any cone's direction moved into the world.
        public var light: PunctualLight

        public init(placement: Int, light: PunctualLight) {
            self.placement = placement
            self.light = light
        }
    }

    /// A sound a placement carries, in the world — see ``carriedSounds(on:)``.
    public struct CarriedSoundInWorld: Equatable, Sendable {
        /// The index in ``Level/placements`` of the placement carrying it.
        public var placement: Int
        /// The sound's name, for the game to play — ``CarriedSound/name``.
        public var name: String
        /// Where it comes from in the world.
        public var position: SIMD3<Float>
        public var volume: Float

        public init(placement: Int, name: String, position: SIMD3<Float>, volume: Float) {
            self.placement = placement
            self.name = name
            self.position = position
            self.volume = volume
        }
    }

    /// The sounds placements carry, in the world: which placement, what, where and how loud.
    ///
    /// **Through the placement's own transform**, so a brazier moved, turned, scaled or copied in the
    /// editor takes its crackle with it — the reason a sound is carried rather than listed.
    public func carriedSounds(on ground: Ground) -> [CarriedSoundInWorld] {
        placements.indices.compactMap { index in
            guard let sound = placements[index].sound else { return nil }
            let world = transform(of: placements[index], on: ground) * SIMD4(sound.offset, 1)
            return CarriedSoundInWorld(placement: index, name: sound.name,
                                       position: SIMD3(world.x, world.y, world.z), volume: sound.volume)
        }
    }

    /// The lights placements carry, moved into the world, and which placement each came from.
    ///
    /// **Through a ``TransformHierarchy``**, each light attached externally to its placement's
    /// transform: this is the case that type's `.external` attachment exists for, and a second
    /// consumer of it. The position goes through the whole transform, scale included; a cone's
    /// direction is turned by the placement's rotation alone, since a direction has no size.
    public func carriedLights(on ground: Ground) -> [CarriedLightInWorld] {
        let carriers = placements.indices.filter { placements[$0].light != nil }
        guard !carriers.isEmpty else { return [] }
        let offsets = carriers.map { index -> simd_float4x4 in
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4(placements[index].light!.position, 1)
            return m
        }
        guard var hierarchy = try? TransformHierarchy(attachments: carriers.indices.map { .external($0) },
                                                      localTransforms: offsets,
                                                      externalCount: carriers.count) else { return [] }
        let frames = carriers.map { transform(of: placements[$0], on: ground) }
        hierarchy.refresh(attachedTo: frames)

        return carriers.enumerated().map { slot, index in
            var light = placements[index].light!
            let world = hierarchy.worldTransform(of: slot)
            light.position = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
            if var cone = light.cone {
                let turn = frames[slot].withoutScale
                let d = turn * SIMD4(cone.direction, 0)
                cone.direction = simd_normalize(SIMD3(d.x, d.y, d.z))
                light.cone = cone
            }
            return CarriedLightInWorld(placement: index, light: light)
        }
    }

    /// Where a placement is, which way it faces and how big it is, as one matrix: scaled, turned by
    /// `yaw` about +Y, then moved to its anchored position.
    ///
    /// **The one definition, and it was missing.** Every consumer built this matrix by hand — the
    /// sample, a game's scatter, a game's renderer — and the engine's own bedding turned the other
    /// way from all of them. A light carried by a placement needed a transform to be carried by, which
    /// is what finally made the engine say what one is.
    public func transform(of placement: Placement, on ground: Ground) -> simd_float4x4 {
        Level.transform(yaw: placement.yaw, scale: placement.scale,
                        at: worldPosition(of: placement, on: ground))
    }

    /// The matrix for a yaw, a uniform scale and a position. **Right-handed about +Y**: positive yaw
    /// turns +X towards −Z, which is the turn `Camera.yaw` makes and every renderer here draws.
    public nonisolated static func transform(yaw: Float, scale: Float, at position: SIMD3<Float>) -> simd_float4x4 {
        let c = cos(yaw), s = sin(yaw)
        return simd_float4x4(columns: (SIMD4(c * scale, 0, -s * scale, 0),
                                         SIMD4(0, scale, 0, 0),
                                         SIMD4(s * scale, 0, c * scale, 0),
                                         SIMD4(position, 1)))
    }

    /// A ground-plane offset `(x, z)` turned by `yaw`, the same way ``transform(yaw:scale:at:)`` turns
    /// it.
    public nonisolated static func turned(_ offset: SIMD2<Float>, by yaw: Float) -> SIMD2<Float> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD2(offset.x * c + offset.y * s, -offset.x * s + offset.y * c)
    }

    /// The same, for a marker.
    public func worldPosition(of marker: Marker, on ground: Ground) -> SIMD3<Float> {
        switch marker.anchor {
        case .absolute: return marker.position
        default: return SIMD3(marker.position.x,
                              ground.height(atX: marker.position.x, z: marker.position.z) + marker.position.y,
                              marker.position.z)
        }
    }
}

// MARK: - Reading and writing

/// Why a level could not be loaded.
///
/// **Every failure ``Level/load(named:withExtension:bundle:)`` and ``Level/decode(from:)`` can meet**,
/// so a game can `catch` this alone and know it has them all. The underlying reason is kept as text
/// so the error stays `Equatable`.
public nonisolated enum LevelError: Error, CustomStringConvertible, Equatable, Sendable {
    /// No level by that name in the bundle.
    case notFound(String)
    /// The file is there and could not be read.
    case unreadable(String, reason: String)
    /// The data is not a level — not JSON, or JSON missing what a level must have.
    case malformed(String)
    /// Written by a newer format than this build reads.
    case unsupportedVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .notFound(let name):
            "no level named '\(name)' in the bundle"
        case .unreadable(let name, let reason):
            "level '\(name)' could not be read — \(reason)"
        case .malformed(let reason):
            "not a level file — \(reason)"
        case .unsupportedVersion(let found, let supported):
            "level format version \(found); this build understands \(supported)"
        }
    }
}

nonisolated extension Level {

    /// Decode a level, refusing one written by a newer format.
    ///
    /// - Throws: ``LevelError/malformed(_:)`` for data that is not a level, and
    ///   ``LevelError/unsupportedVersion(found:supported:)`` for one written by a newer format.
    public static func decode(from data: Data) throws -> Level {
        // The version first, alone: a newer file may not decode as this format at all, and "written by
        // a newer build" is the true answer, where "malformed" would send someone looking for damage.
        struct Version: Decodable { let formatVersion: Int }
        let decoder = JSONDecoder()
        do {
            let version = try decoder.decode(Version.self, from: data).formatVersion
            guard version <= Level.currentVersion else {
                throw LevelError.unsupportedVersion(found: version, supported: Level.currentVersion)
            }
            return try decoder.decode(Level.self, from: data)
        } catch let error as LevelError {
            throw error
        } catch {
            throw LevelError.malformed(String(describing: error))
        }
    }

    /// **From a bundle, never from an arbitrary path.** The engine has to run sandboxed or not — see
    /// the studio's distribution rule — so it may not assume it can read wherever it likes.
    ///
    /// - Throws: ``LevelError`` — not found, unreadable, malformed, or a newer format.
    public static func load(named name: String, withExtension fileExtension: String = "json",
                            bundle: Bundle) throws -> Level {
        guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
            throw LevelError.notFound(name)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LevelError.unreadable(name, reason: error.localizedDescription)
        }
        return try decode(from: data)
    }

    /// Encode, sorted and pretty-printed.
    ///
    /// **Both of those are for the diff, not for looks.** A level file is edited by tools and read by
    /// people in pull requests; unsorted keys mean a save with no changes still produces a diff, and
    /// one line of JSON means every change produces the same useless one-line diff.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
