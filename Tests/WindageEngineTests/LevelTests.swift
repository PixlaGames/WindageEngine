import Testing
import Foundation
import simd
@testable import WindageEngine

/// The format's contract. **A level file outlives the code that wrote it**, so what is guarded here
/// is round-tripping, defaults, and refusing a file this build cannot honestly read.
struct LevelTests {

    private func sample() -> Level {
        Level(name: "TEST RANGE",
              settings: ["sunAngle": 42.5, "par": 90],
              placements: [
                Placement(mesh: "wall", position: SIMD3(-60, 0, -560)),
                Placement(mesh: "hab", position: SIMD3(12, 0, -600), yaw: 0.4,
                          anchor: .beddedFootprint, tags: ["solid"]),
                Placement(mesh: "sign", position: SIMD3(0, 14, -300), scale: 2,
                          anchor: .absolute, tags: ["decorative", "emissive"]),
              ],
              markers: [
                Marker(kind: "firing-position", name: "THE BROW", position: SIMD3(0, 0, 14), yaw: 0.06),
                Marker(kind: "target", position: SIMD3(-4, 0, -150), values: ["range": 150]),
              ])
    }

    private typealias Placement = Level.Placement
    private typealias Marker = Level.Marker

    @Test("A level survives the round trip unchanged")
    func roundTrips() throws {
        let original = sample()
        let decoded = try Level.decode(from: try original.encoded())
        #expect(decoded == original)
    }

    /// **Encoding twice must give byte-identical output**, or every save produces a diff whether or
    /// not anything changed, and the format stops being reviewable.
    @Test("Encoding is stable")
    func encodingIsStable() throws {
        let level = sample()
        #expect(try level.encoded() == level.encoded())
        let reEncoded = try Level.decode(from: try level.encoded()).encoded()
        #expect(try reEncoded == level.encoded())
    }

    /// Defaults are omitted, so a level of mostly-default props is a small file and a small diff.
    @Test("Defaults are not written out")
    func defaultsAreOmitted() throws {
        let level = Level(name: "bare", placements: [Placement(mesh: "rock", position: .zero)])
        let json = String(data: try level.encoded(), encoding: .utf8)!
        #expect(!json.contains("\"yaw\""))
        #expect(!json.contains("\"scale\""))
        #expect(!json.contains("\"anchor\""))
        #expect(!json.contains("\"tags\""))
        #expect(json.contains("\"mesh\""))
    }

    /// And a file that omits them decodes to those same defaults.
    @Test("An omitted field decodes to its default")
    func omittedFieldsTakeDefaults() throws {
        let json = """
        {"formatVersion":1,"name":"minimal","settings":{},"markers":[],
         "placements":[{"mesh":"rock","position":[1,2,3]}]}
        """
        let level = try Level.decode(from: Data(json.utf8))
        let placement = try #require(level.placements.first)
        #expect(placement.yaw == 0)
        #expect(placement.scale == 1)
        #expect(placement.anchor == .ground)
        #expect(placement.tags.isEmpty)
        #expect(placement.position == SIMD3(1, 2, 3))
    }

    /// **A newer file must be refused, not partly read.** Loading it anyway drops whatever this build
    /// does not understand, and the symptom is level geometry quietly missing.
    @Test("A newer format version is refused")
    func refusesANewerVersion() throws {
        let json = """
        {"formatVersion":999,"name":"future","settings":{},"placements":[],"markers":[]}
        """
        #expect(throws: LevelError.unsupportedVersion(found: 999, supported: Level.currentVersion)) {
            try Level.decode(from: Data(json.utf8))
        }
        // **Even when it would not decode as this format**: "written by a newer build" is the true
        // answer, where "malformed" would send someone looking for damage.
        let reshaped = #"{"formatVersion": 2, "placements": "now an object of some kind"}"#
        #expect(throws: LevelError.unsupportedVersion(found: 2, supported: Level.currentVersion)) {
            try Level.decode(from: Data(reshaped.utf8))
        }
    }

    @Test("A missing level names itself in the error")
    func missingLevelIsNamed() {
        #expect(throws: LevelError.notFound("nope")) {
            try Level.load(named: "nope", bundle: .module)
        }
    }

    /// **Every failure is a `LevelError`**, so a game catching that one type has them all. A decode
    /// failure used to escape as a `DecodingError`, which `LoadError` did not mention.
    @Test("Data that is not a level is a LevelError too")
    func malformedDataIsALevelError() {
        for json in ["not json at all", #"{"name": "no version"}"#,
                     #"{"formatVersion": 1, "placements": [{"position": [0, 0, 0]}]}"#] {
            #expect(performing: { try Level.decode(from: Data(json.utf8)) }, throws: { error in
                guard case .malformed = error as? LevelError else { return false }
                return true
            })
        }
    }

    @Test("Queries filter by tag and kind, in file order")
    func queries() {
        let level = sample()
        #expect(level.placements(tagged: "solid").map(\.mesh) == ["hab"])
        #expect(level.placements(tagged: "decorative").map(\.mesh) == ["sign"])
        #expect(level.markers(ofKind: "target").count == 1)
        #expect(level.markers(ofKind: "firing-position").first?.name == "THE BROW")
        #expect(level.markers(ofKind: "nothing-of-the-sort").isEmpty)
    }

    /// The engine must not learn what a marker means. If this list ever needs extending to make a
    /// game work, the game is asking the format to have an opinion it must not have.
    @Test("The engine has no opinion about what a kind or tag means")
    func kindsAreOpen() {
        let level = Level(name: "any", markers: [
            Marker(kind: "anchorage", position: .zero),
            Marker(kind: "whatever-a-game-wants", position: .zero),
        ])
        #expect(level.markers(ofKind: "anchorage").count == 1)
        #expect(level.markers(ofKind: "whatever-a-game-wants").count == 1)
    }
}

/// Anchors are the reason a level survives its terrain changing, so the arithmetic is pinned.
struct LevelAnchorTests {

    /// A slope: ground falls one metre per metre of +x.
    private let slope = Level.Ground(
        height: { x, _ in -x },
        footprintCorners: { $0 == "hab" ? [SIMD2(-10, 0), SIMD2(10, 0)] : [] })

    private let level = Level(name: "anchors")

    @Test("Absolute keeps the height it was given")
    func absolute() {
        let placement = Level.Placement(mesh: "sign", position: SIMD3(5, 42, 0), anchor: .absolute)
        #expect(level.worldPosition(of: placement, on: slope) == SIMD3(5, 42, 0))
    }

    @Test("Ground puts y on top of the ground under the origin")
    func ground() {
        let placement = Level.Placement(mesh: "rock", position: SIMD3(5, 0, 0), anchor: .ground)
        #expect(level.worldPosition(of: placement, on: slope) == SIMD3(5, -5, 0))
        let raised = Level.Placement(mesh: "rock", position: SIMD3(5, 2, 0), anchor: .ground)
        #expect(level.worldPosition(of: raised, on: slope) == SIMD3(5, -3, 0))
    }

    /// **The lowest corner, not the origin.** A twenty-metre building centred at x = 0 spans
    /// x = −10…+10, so on this slope its low corner is at −10 m of height; bedding to the origin
    /// would leave that end ten metres in the air.
    @Test("Bedded takes the lowest ground under the footprint")
    func bedded() {
        let placement = Level.Placement(mesh: "hab", position: SIMD3(0, 0, 0), anchor: .beddedFootprint)
        #expect(level.worldPosition(of: placement, on: slope) == SIMD3(0, -10, 0))
    }

    /// And it follows the placement's rotation, or a turned building beds to the wrong corner.
    @Test("Bedding respects yaw")
    func beddedRotates() {
        // Rotated a quarter turn, the footprint now runs along z, where this ground is flat.
        let placement = Level.Placement(mesh: "hab", position: SIMD3(0, 0, 0),
                                        yaw: .pi / 2, anchor: .beddedFootprint)
        let y = level.worldPosition(of: placement, on: slope).y
        #expect(abs(y) < 0.001, "a turned building bedded to a corner it no longer has")
    }

    @Test("A mesh with no footprint beds on its origin")
    func noFootprint() {
        let placement = Level.Placement(mesh: "unknown", position: SIMD3(3, 0, 0), anchor: .beddedFootprint)
        #expect(level.worldPosition(of: placement, on: slope) == SIMD3(3, -3, 0))
    }

    // MARK: - The sky the level is under

    /// **The round trip has to be stable, not exact.** A sky is stored as two angles and rebuilt as a
    /// direction, which is lossy on the first hop by construction — what matters is that saving a
    /// loaded level and loading it again gives the same thing, because that is what the editor does
    /// every time somebody presses save.
    @Test("A sky survives being saved and loaded")
    func skyRoundTrips() throws {
        let original = Level(name: "SKY",
                             sky: ProceduralSky(zenith: SIMD3(0.1, 0.2, 0.3),
                                                horizon: SIMD3(0.4, 0.5, 0.6),
                                                ground: SIMD3(0.05, 0.04, 0.03),
                                                sunPitchDegrees: 22, sunYawDegrees: 137,
                                                sunRadiance: SIMD3(300, 200, 100),
                                                sunAngularRadius: 0.08))
        let once = try Level.decode(from: original.encoded())
        let twice = try Level.decode(from: once.encoded())
        #expect(once == twice, "a level does not survive a second save")

        let sky = try #require(once.sky)
        #expect(sky.zenith == SIMD3(0.1, 0.2, 0.3))
        #expect(sky.sunRadiance == SIMD3(300, 200, 100))
        #expect(abs(sky.sunPitchDegrees - 22) < 1e-3)
        #expect(abs(sky.sunYawDegrees - 137) < 1e-3)
        #expect(abs(sky.sunAngularRadius - 0.08) < 1e-6)
    }

    /// **A level file is edited by hand as often as by a tool**, so a sky that names one field and
    /// takes the rest as read has to be legal — otherwise the simplest edit is the longest one.
    @Test("A sky may name only the fields it cares about")
    func partialSkyDecodes() throws {
        let json = """
        {"formatVersion": 1, "name": "PARTIAL", "settings": {}, "placements": [], "markers": [],
         "sky": {"sunPitch": 5}}
        """
        let level = try Level.decode(from: Data(json.utf8))
        let sky = try #require(level.sky)
        #expect(abs(sky.sunPitchDegrees - 5) < 1e-3)
        #expect(sky.zenith == ProceduralSky().zenith, "an unnamed field did not fall back")
    }

    @Test("A colour that is not three numbers is refused")
    func malformedColorIsRejected() {
        let json = """
        {"formatVersion": 1, "name": "BAD", "settings": {}, "placements": [], "markers": [],
         "sky": {"zenith": [0.5, 0.5]}}
        """
        #expect(throws: LevelError.self) { try Level.decode(from: Data(json.utf8)) }
    }

    /// A wider sun is both softer *and* stronger, because it is more sky. Deriving the irradiance
    /// rather than storing it is what makes that fall out instead of being two numbers to keep in
    /// step.
    @Test("Irradiance follows from the sun's radiance and its size")
    func irradianceFollowsTheDisc() {
        let small = ProceduralSky(sunRadiance: SIMD3(repeating: 100), sunAngularRadius: 0.05)
        let wide = ProceduralSky(sunRadiance: SIMD3(repeating: 100), sunAngularRadius: 0.10)
        #expect(wide.sunIrradiance.x > small.sunIrradiance.x * 3.5)
        // And it is genuinely a small number: radiance used as an intensity is ~100x too bright.
        #expect(small.sunIrradiance.x < 1)
    }

    @Test("Sun angles survive the trip through a direction")
    func sunAnglesRoundTrip() {
        for (pitch, yaw) in [(Float(0), Float(0)), (34, 295), (11, -120), (75, 180)] {
            var sky = ProceduralSky()
            sky.sunPitchDegrees = pitch
            sky.sunYawDegrees = yaw
            #expect(abs(sky.sunPitchDegrees - pitch) < 1e-2, "pitch \(pitch)")
            let recovered = sky.sunYawDegrees
            // Yaw comes back wrapped to -180…180, which is the same direction.
            let difference = abs((recovered - yaw).truncatingRemainder(dividingBy: 360))
            #expect(min(difference, 360 - difference) < 1e-2, "yaw \(yaw) came back \(recovered)")
        }
    }
}

/// **One definition of where a placement is.** Bedding turned the other way from every renderer until
/// 2026-09-11, and no test said so because none asked where the corners it sampled actually were.
@Suite("Placement transform")
struct PlacementTransformTests {

    /// Positive yaw turns +X towards −Z — the turn `Camera` makes, and the one every renderer draws.
    @Test("The turn is right-handed about +Y, like the camera's")
    func handedness() {
        let m = Level.transform(yaw: .pi / 2, scale: 1, at: .zero)
        let x = m * SIMD4<Float>(1, 0, 0, 0)
        #expect(abs(x.x) < 1e-6 && abs(x.z + 1) < 1e-6, "+X went to \(x)")
        // And a camera at that yaw has the same right-hand side.
        let camera = Camera(position: .zero, yaw: .pi / 2)
        #expect(simd_distance(SIMD3(x.x, x.y, x.z), camera.right) < 1e-6)
    }

    @Test("turned(_:by:) is the matrix's turn")
    func turnedMatchesMatrix() {
        for yaw in stride(from: Float(-3), through: 3, by: 0.37) {
            let m = Level.transform(yaw: yaw, scale: 1, at: .zero)
            let world = m * SIMD4<Float>(2, 0, -0.7, 1)
            let turned = Level.turned(SIMD2(2, -0.7), by: yaw)
            #expect(abs(world.x - turned.x) < 1e-5 && abs(world.z - turned.y) < 1e-5)
        }
    }

    /// **The corners bedding samples are the corners the placement is drawn with.** An asymmetric
    /// footprint, turned, on a slope — the case where the old rotation sampled its mirror image.
    @Test("Bedding samples the ground under the corners the placement is drawn with")
    func beddingUsesDrawnCorners() {
        let corners: [SIMD2<Float>] = [SIMD2(-1, -4), SIMD2(-1, 1), SIMD2(9, -4), SIMD2(9, 1)]
        let sampled = SampledPoints()
        let ground = Level.Ground(
            height: { x, z in sampled.add(SIMD2(x, z)); return 0.1 * x - 0.05 * z },
            footprintCorners: { _ in corners })
        let placement = Level.Placement(mesh: "long", position: SIMD3(20, 0, -5), yaw: 0.6,
                                        scale: 1.5, anchor: .beddedFootprint)
        let level = Level(name: "slope", placements: [placement])
        _ = level.worldPosition(of: placement, on: ground)

        let m = Level.transform(yaw: 0.6, scale: 1.5, at: SIMD3(20, 0, -5))
        for corner in corners {
            let drawn = m * SIMD4<Float>(corner.x, 0, corner.y, 1)
            #expect(sampled.points.contains { simd_distance($0, SIMD2(drawn.x, drawn.z)) < 1e-4 },
                    "the corner drawn at \(drawn) was never sampled")
        }
    }

    /// And the height it lands at is the lowest of those drawn corners.
    @Test("A bedded placement sits on the lowest drawn corner")
    func sitsOnLowestDrawnCorner() {
        let corners: [SIMD2<Float>] = [SIMD2(-1, -4), SIMD2(-1, 1), SIMD2(9, -4), SIMD2(9, 1)]
        let height: @Sendable (Float, Float) -> Float = { x, z in 0.1 * x - 0.3 * z }
        let ground = Level.Ground(height: height, footprintCorners: { _ in corners })
        let placement = Level.Placement(mesh: "long", position: SIMD3(0, 0, 0), yaw: 0.8,
                                        anchor: .beddedFootprint)
        let level = Level(name: "slope", placements: [placement])
        let m = Level.transform(yaw: 0.8, scale: 1, at: .zero)
        let lowest = (corners.map { c -> Float in
            let w = m * SIMD4<Float>(c.x, 0, c.y, 1)
            return height(w.x, w.z)
        } + [height(0, 0)]).min()!
        #expect(abs(level.worldPosition(of: placement, on: ground).y - lowest) < 1e-5)
    }

    @Test("transform(of:on:) puts the placement where worldPosition says")
    func transformUsesTheAnchor() {
        let ground = Level.Ground(height: { _, _ in 3 })
        let placement = Level.Placement(mesh: "box", position: SIMD3(4, 0.5, -2), yaw: 1, scale: 2)
        let level = Level(name: "raised", placements: [placement])
        let m = level.transform(of: placement, on: ground)
        #expect(SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) == SIMD3(4, 3.5, -2))
        #expect(abs(simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)) - 2) < 1e-6)
    }
}

/// Collects where a ground function was asked for its height.
private final class SampledPoints: @unchecked Sendable {
    private(set) var points: [SIMD2<Float>] = []
    func add(_ point: SIMD2<Float>) { points.append(point) }
}

/// **A lamp that belongs to something goes where it goes.**
@Suite("Lights carried by placements")
struct CarriedLightTests {

    private let flat = Level.Ground(height: { _, _ in 0 })

    private func brazier(at position: SIMD3<Float>, yaw: Float = 0, scale: Float = 1) -> Level.Placement {
        Level.Placement(mesh: "brazier", position: position, yaw: yaw, scale: scale,
                        light: PunctualLight(position: SIMD3(0, 1.8, 0), color: SIMD3(60, 36, 18), range: 14))
    }

    @Test("A carried light sits at its offset from the placement")
    func offset() {
        let level = Level(name: "l", placements: [brazier(at: SIMD3(-4, 0, -10))])
        #expect(level.resolvedLights(on: flat).map(\.position) == [SIMD3(-4, 1.8, -10)])
    }

    /// **The whole point.** The editor moves a placement; the lamp has to go with it.
    @Test("Moving the placement in the editor moves its light")
    func editorMovesTheLight() {
        var editor = LevelEditor(level: Level(name: "l", placements: [brazier(at: SIMD3(-4, 0, -10))]))
        editor.select(0)
        editor.move(by: SIMD3(3, 0, 0))
        #expect(editor.level.resolvedLights(on: flat).first?.position == SIMD3(-1, 1.8, -10))
    }

    @Test("Copying a placement copies its light")
    func copyCopiesTheLight() {
        var editor = LevelEditor(level: Level(name: "l", placements: [brazier(at: .zero)]))
        editor.select(0)
        editor.duplicate()
        #expect(editor.level.resolvedLights(on: flat).count == 2)
    }

    /// An offset to the side turns with the placement, by the same turn it is drawn with.
    @Test("An offset turns with the placement")
    func offsetTurns() {
        var carrier = brazier(at: .zero, yaw: .pi / 2)
        carrier.light?.position = SIMD3(1, 1, 0)
        let light = Level(name: "l", placements: [carrier]).resolvedLights(on: flat)[0]
        let drawn = Level.transform(yaw: .pi / 2, scale: 1, at: .zero) * SIMD4<Float>(1, 1, 0, 1)
        #expect(simd_distance(light.position, SIMD3(drawn.x, drawn.y, drawn.z)) < 1e-5)
    }

    /// A lamp on a post, aimed: turn the post and the beam turns with it — and stays a unit vector
    /// however the post is scaled.
    @Test("A carried spot's direction turns with the placement and ignores its scale")
    func coneTurns() {
        var post = Level.Placement(mesh: "post", position: .zero, yaw: .pi / 2, scale: 3)
        post.light = PunctualLight(position: SIMD3(0, 4, 0), color: SIMD3(repeating: 100), range: 20,
                                   cone: .init(direction: SIMD3(1, 0, 0), innerAngle: 0.2, outerAngle: 0.4))
        let light = Level(name: "l", placements: [post]).resolvedLights(on: flat)[0]
        let direction = light.cone!.direction
        #expect(abs(direction.x) < 1e-5 && abs(direction.z + 1) < 1e-5, "\(direction)")
        #expect(abs(simd_length(direction) - 1) < 1e-5)
        // The offset does scale: a post three times the size holds its lamp three times as high.
        #expect(abs(light.position.y - 12) < 1e-4)
        #expect(light.range == 20, "a light's reach is the lamp's, not the post's")
    }

    @Test("Free-standing lights come first, then carried ones in placement order")
    func order() {
        let sun = PunctualLight(position: SIMD3(0, 9, 0), color: SIMD3(repeating: 1), range: 30)
        let level = Level(name: "l", lights: [sun],
                          placements: [brazier(at: SIMD3(1, 0, 0)),
                                       Level.Placement(mesh: "box", position: .zero),
                                       brazier(at: SIMD3(2, 0, 0))])
        #expect(level.resolvedLights(on: flat).map(\.position.x) == [0, 1, 2])
        #expect(level.carriedLights(on: flat).map(\.placement) == [0, 2])
    }

    @Test("A carried light survives a save and a load, and a placement without one writes nothing")
    func codable() throws {
        let level = Level(name: "l", placements: [brazier(at: .zero), Level.Placement(mesh: "box", position: .zero)])
        let data = try JSONEncoder().encode(level)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.components(separatedBy: "\"light\"").count == 2, "only the brazier should write a light")
        let back = try JSONDecoder().decode(Level.self, from: data)
        #expect(back.resolvedLights(on: flat) == level.resolvedLights(on: flat))
    }
}

@Suite("What things are made of")
struct SurfaceTests {

    private let level = Level(name: "t", placements: [
        Level.Placement(mesh: "step", position: .zero, tags: ["solid"], surface: "stone"),
        Level.Placement(mesh: "deck", position: SIMD3(0, 0, -1), tags: ["solid"], surface: "wood"),
        Level.Placement(mesh: "mystery", position: SIMD3(0, 0, -2), tags: ["solid"]),
    ], groundSurface: "dirt")

    @Test("The surface underfoot comes from the placement stood on, or the ground")
    func underfoot() {
        #expect(level.surface(standingOn: 0) == "stone")
        #expect(level.surface(standingOn: 1) == "wood")
        #expect(level.surface(standingOn: nil) == "dirt")
    }

    /// **Not the ground's**: a crate with no surface is a gap in the level, and borrowing "dirt"
    /// for it would make that gap sound fine.
    @Test("A placement that names no surface says so, rather than borrowing the ground's")
    func unnamedIsNil() {
        #expect(level.surface(standingOn: 2) == nil)
        #expect(level.surface(standingOn: 99) == nil)
    }

    @Test("Surfaces round-trip, and are left out of the file when not set")
    func roundTrip() throws {
        let data = try JSONEncoder().encode(level)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"groundSurface\":\"dirt\"") && text.contains("\"surface\":\"wood\""), "\(text)")
        #expect(text.components(separatedBy: "\"surface\"").count == 3, "only the two named placements carry one")
        let back = try JSONDecoder().decode(Level.self, from: data)
        #expect(back.placements.map(\.surface) == ["stone", "wood", nil])
        #expect(back.groundSurface == "dirt")
    }

    @Test("A level written before surfaces loads with none")
    func olderLevel() throws {
        let json = #"{ "formatVersion": 1, "placements": [ { "mesh": "box", "position": [0, 0, 0] } ] }"#
        let old = try JSONDecoder().decode(Level.self, from: Data(json.utf8))
        #expect(old.groundSurface == nil && old.placements[0].surface == nil)
    }

    @Test("A copy made in the editor is made of the same thing")
    func duplicateKeepsSurface() {
        var editor = LevelEditor(level: level)
        editor.select(1)
        editor.duplicate()
        #expect(editor.selected?.surface == "wood")
    }
}

@Suite("Sounds carried by placements")
struct CarriedSoundTests {

    private let flat = Level.Ground(height: { _, _ in 0 })

    /// The one initializer takes every field; `sound` used to be settable only after the fact.
    @Test("A placement is made with its sound")
    func madeWithItsSound() {
        let crackle = Level.CarriedSound(name: "crackle", offset: SIMD3(0, 1, 0))
        let brazier = Level.Placement(mesh: "brazier", position: .zero, surface: "metal", sound: crackle)
        #expect(brazier.sound == crackle && brazier.surface == "metal")
    }

    @Test("A carried sound is in the world where its placement puts it, and moves with it")
    func placedAndMoved() {
        var brazier = Level.Placement(mesh: "brazier", position: SIMD3(4, 0, -2), yaw: .pi / 2, scale: 2)
        brazier.sound = Level.CarriedSound(name: "crackle", offset: SIMD3(0.5, 1, 0), volume: 0.6)
        var level = Level(name: "t", placements: [Level.Placement(mesh: "box", position: .zero), brazier])
        var sounds = level.carriedSounds(on: flat)
        #expect(sounds.count == 1 && sounds[0].placement == 1 && sounds[0].name == "crackle" && sounds[0].volume == 0.6)
        // Scaled by 2 and turned a quarter: the +x offset of 0.5 becomes 1 m along −z, the height 2 m.
        #expect(simd_distance(sounds[0].position, SIMD3(4, 2, -3)) < 1e-4, "\(sounds[0].position)")
        level.placements[1].position.x += 3
        sounds = level.carriedSounds(on: flat)
        #expect(abs(sounds[0].position.x - 7) < 1e-4)
    }

    @Test("A carried sound round-trips, with its defaults left out of the file")
    func roundTrip() throws {
        var p = Level.Placement(mesh: "brazier", position: .zero)
        p.sound = Level.CarriedSound(name: "crackle", offset: SIMD3(0, 1, 0))
        let data = try JSONEncoder().encode(p)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("crackle") && !text.contains("volume"), "\(text)")
        #expect(try JSONDecoder().decode(Level.Placement.self, from: data) == p)
        let bare = try JSONDecoder().decode(Level.Placement.self, from: Data(#"{ "mesh": "box", "position": [0, 0, 0] }"#.utf8))
        #expect(bare.sound == nil)
    }
}
