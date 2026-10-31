//
//  OrbitCameraObstructionTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// The camera not clipping through the scenery, and the right stick that makes it matter.
@Suite("Orbit camera obstruction")
struct OrbitCameraObstructionTests {

    /// An upright box turned about its own vertical, as the world's solids are: its bounds, and its footprint when it
    /// is turned.
    private func upright(centre: SIMD3<Float>, halfExtents: SIMD3<Float>,
                         yaw: Float = 0) -> CharacterController.Surroundings.Solid {
        let c = abs(cos(yaw)), s = abs(sin(yaw))
        let across = SIMD3(c * halfExtents.x + s * halfExtents.z, halfExtents.y, s * halfExtents.x + c * halfExtents.z)
        let bounds = BoundingBox(minimum: centre - across, maximum: centre + across)
        guard yaw != 0 else { return .init(bounds: bounds) }
        return .init(bounds: bounds, footprint: .init(center: SIMD2(centre.x, centre.z),
                                                      halfSize: SIMD2(halfExtents.x, halfExtents.z), yaw: yaw))
    }

    /// A pillar two metres square, four tall, standing `z` metres behind the aim point along +Z.
    private func pillar(at z: Float, yaw: Float = 0) -> CharacterController.Surroundings.Solid {
        upright(centre: SIMD3(0, 2, z), halfExtents: SIMD3(0.8, 2, 0.8), yaw: yaw)
    }

    private func allowedDistance(aimPoint: SIMD3<Float>, direction: SIMD3<Float>, desired: Float,
                                 blockers: [CharacterController.Surroundings.Solid]) -> Float {
        OrbitCamera.allowedDistance(aimPoint: aimPoint, direction: direction, desired: desired,
                                    in: CharacterController.Surroundings(solids: blockers))
    }

    private let aim = SIMD3<Float>(0, 1.7, 0)
    private let behind = SIMD3<Float>(0, 0, 1)   // straight back, level
    private let minimumDistance = OrbitCamera.Tuning().minimumDistance

    @Test("Clear air gives the player the distance they asked for")
    func nothingInTheWayChangesNothing() {
        let allowed = allowedDistance(aimPoint: aim, direction: behind, desired: 7, blockers: [])
        #expect(allowed == 7)
    }

    @Test("A pillar between the character and the camera pulls the camera in front of it")
    func aPillarPullsTheCameraIn() {
        let allowed = allowedDistance(aimPoint: aim, direction: behind, desired: 7, blockers: [pillar(at: 5)])
        // The pillar's near face is at z = 4.2, and the probe radius takes another 0.4 off it.
        #expect(abs(allowed - 3.8) < 0.001)
    }

    /// The reason the boxes are grown rather than the ray being a ray: the camera sees a frustum,
    /// so a corner enters the picture while the camera's own point is still in clear air.
    @Test("The camera stops short of the surface, not on it")
    func theProbeHasWidth() {
        let onTheFace = allowedDistance(aimPoint: aim, direction: behind, desired: 7, blockers: [pillar(at: 5)])
        #expect(onTheFace < 4.2)
    }

    @Test("A pillar further away than the camera wants to be is not in the way")
    func distantBlockersAreIgnored() {
        let allowed = allowedDistance(aimPoint: aim, direction: behind, desired: 7, blockers: [pillar(at: 30)])
        #expect(allowed == 7)
    }

    @Test("A pillar to one side is not in the way")
    func blockersOffTheLineAreIgnored() {
        let aside = upright(centre: SIMD3(6, 2, 5), halfExtents: SIMD3(0.8, 2, 0.8))
        let allowed = allowedDistance(aimPoint: aim, direction: behind, desired: 7, blockers: [aside])
        #expect(allowed == 7)
    }

    @Test("The nearest of several blockers wins")
    func nearestWins() {
        let far = allowedDistance(aimPoint: aim, direction: behind, desired: 7, blockers: [pillar(at: 6)])
        let both = allowedDistance(aimPoint: aim, direction: behind,
                                   desired: 7, blockers: [pillar(at: 6), pillar(at: 3)])
        #expect(both < far)
    }

    /// Pillars turned to face the middle of a ring are why the test has to be an oriented one rather than an
    /// axis-aligned box wearing a rotation it ignores — and the footprint is where the turn is.
    @Test("A turned box is tested turned")
    func yawIsHonoured() {
        // A thin plank standing across the +X view, five metres out and set off to one side so it
        // reaches across the ray without ever containing its origin. A quarter turn swings it out
        // of the way — and an axis-aligned test that ignored the yaw would say it was still there.
        let plank = upright(centre: SIMD3(5, 1.7, 3), halfExtents: SIMD3(0.1, 2, 4))
        let turned = upright(centre: SIMD3(5, 1.7, 3), halfExtents: SIMD3(0.1, 2, 4), yaw: .pi / 2)

        let across = allowedDistance(aimPoint: aim, direction: SIMD3(1, 0, 0), desired: 7, blockers: [plank])
        let alongside = allowedDistance(aimPoint: aim, direction: SIMD3(1, 0, 0), desired: 7, blockers: [turned])
        #expect(across < 7, "standing across the view, the plank is in the way")
        #expect(alongside == 7, "turned a quarter, it is beside the view rather than across it")
    }

    @Test("The camera stays out of the ground")
    func theGroundIsAFloor() {
        // Tilted well down: the camera would otherwise be buried and the world would turn to fog.
        let steep = normalize(SIMD3<Float>(0, -1, 0.3))
        let allowed = allowedDistance(aimPoint: aim, direction: steep, desired: 7, blockers: [])
        let camera = aim + steep * allowed
        #expect(camera.y >= 0.49)
    }

    /// Standing in a doorway with the frame around your shoulders must not slam the view into the
    /// character's back.
    @Test("Being inside a blocker is not an obstruction")
    func insideIsNotAHit() {
        let around = upright(centre: aim, halfExtents: SIMD3(1, 2, 1))
        let allowed = allowedDistance(aimPoint: aim, direction: behind, desired: 7, blockers: [around])
        #expect(allowed == 7)
    }

    @Test("However tight the squeeze, the camera keeps a distance")
    func thereIsAFloorOnTheSqueeze() {
        let touching = upright(centre: SIMD3(0, 1.7, 0.5), halfExtents: SIMD3(2, 2, 0.1))
        let allowed = allowedDistance(aimPoint: aim, direction: behind, desired: 7, blockers: [touching])
        #expect(allowed == minimumDistance)
    }

    /// **The case that "inside a blocker is not an obstruction" gets wrong if it is written the
    /// obvious way.** A character with their back a hand's width from a wall puts the aim point inside the
    /// box once it is widened by the probe — and a rule that simply ignores that hands the camera
    /// the far side of the wall, where the player is looking at masonry with the game going on
    /// behind it.
    @Test("Pressed against a wall, the camera comes all the way in rather than through")
    func aWallAtYourBackIsStillAWall() {
        let wall = upright(centre: SIMD3(0, 1.7, 0.45), halfExtents: SIMD3(4, 2, 0.2))
        let allowed = allowedDistance(aimPoint: aim, direction: behind, desired: 7, blockers: [wall])
        #expect(allowed == minimumDistance)
    }

    // MARK: - Meshes, slopes, and the body's world

    /// A mesh is met at its face, less the probe's radius — the same distance a box of the same size gives.
    @Test("A mesh behind the character pulls the camera in front of it")
    func aMeshPullsTheCameraIn() {
        let wall = CollisionMesh(triangles: CollisionMesh.box(centre: SIMD3(0, 2, 5), halfExtents: SIMD3(2, 2, 0.8)))
        let allowed = OrbitCamera.allowedDistance(aimPoint: aim, direction: behind, desired: 7,
                                                  in: CharacterController.Surroundings(meshes: wall))
        #expect(abs(allowed - 3.8) < 0.001)
    }

    /// **Backing up a hillside is the everyday case.** The ground under the character is well below the
    /// camera; the slope behind them is not — and a check that only knew the height at the feet would
    /// let the camera sit inside the hill.
    @Test("The camera stops at the slope behind the character, not inside it")
    func cameraStopsAtTheHill() {
        // A plane rising one metre a metre toward −Z.
        let hillside: @Sendable (Float, Float) -> Float = { _, z in -z }
        // The character at the origin, shoulder height above the ground there.
        let aim = SIMD3<Float>(0, hillside(0, 0) + 1.7, 0)
        // Looking level, camera wanting to sit 12 m behind along −Z — which is uphill.
        let direction = SIMD3<Float>(0, 0, -1)
        let allowed = OrbitCamera.allowedDistance(aimPoint: aim, direction: direction, desired: 12,
                                                  in: CharacterController.Surroundings(groundHeight: hillside))
        // The slope rises 1 m a metre, so it climbs past shoulder height minus the clearance about
        // 1.2 m back. Anything near 12 would be a camera buried in the hillside.
        #expect(allowed < 2)
        let camera = aim + direction * allowed
        #expect(camera.y >= hillside(camera.x, camera.z) + 0.5 - 0.05)
    }

    @Test("Downhill behind the character, the camera is free to go all the way")
    func cameraFreeDownhill() {
        let hillside: @Sendable (Float, Float) -> Float = { _, z in -z }
        let aim = SIMD3<Float>(0, hillside(0, 0) + 1.7, 0)
        let allowed = OrbitCamera.allowedDistance(aimPoint: aim, direction: SIMD3(0, 0, 1), desired: 12,
                                                  in: CharacterController.Surroundings(groundHeight: hillside))
        #expect(allowed == 12)
    }

    /// **Ground that runs on overhead is not ground in the way** — a cave under a hill. The aim point is already
    /// below it, and answering "no distance" there would pin the camera at its minimum for as long as the character
    /// stood in the cave.
    @Test("Under ground that runs overhead, the camera is not pulled in by it")
    func groundOverheadIsNotInTheWay() {
        let overhead: @Sendable (Float, Float) -> Float = { _, _ in 6 }
        let allowed = OrbitCamera.allowedDistance(aimPoint: aim, direction: behind, desired: 7,
                                                  in: CharacterController.Surroundings(groundHeight: overhead))
        #expect(allowed == 7)
    }

    /// **The reason the camera asks the body's world rather than one of its own.** A pillar the camera refuses to
    /// sit behind and the body walks straight through is the game disagreeing with itself in front of the player.
    @Test("What stops the body is what stops the camera")
    func theCameraAndTheBodyAgree() {
        let world = CharacterController.Surroundings(solids: [pillar(at: 5)])
        var body = CharacterController(feet: SIMD3(0, 0, 0))
        // Backing into the pillar along +Z until it stops.
        for _ in 0..<240 {
            body.step(yaw: 0, input: MovementInput(forward: -1), deltaTime: 1.0 / 60, in: world)
        }
        #expect(body.feet.z < 4.2, "the body stops at the pillar's near face")
        let allowed = OrbitCamera.allowedDistance(aimPoint: body.feet + SIMD3(0, 1.7, 0), direction: behind,
                                                  desired: 7, in: world)
        #expect(allowed < 7, "the camera knows about the same pillar the body just stopped at")
    }

    // MARK: - How the camera takes it

    @Test("The camera goes in at once and comes back out gently")
    func inSnapsOutEases() {
        var camera = OrbitCamera()
        camera.distance = 7

        camera.constrain(to: 3, deltaTime: 1.0 / 60)
        #expect(camera.workingDistance == 3, "easing in means the pillar clips first")

        camera.constrain(to: 18, deltaTime: 1.0 / 60)
        #expect(camera.workingDistance > 3)
        #expect(camera.workingDistance < 7, "leaping back out is a lurch under a thumb doing nothing")
    }

    @Test("Coming out gets there")
    func easingConverges() {
        var camera = OrbitCamera()
        camera.constrain(to: 2, deltaTime: 1)
        // **Long enough for the half-life in use, not a frame count from when it was 0.18.**
        for _ in 0..<Int(camera.tuning.recoveryHalfLife * 60 * 12) {
            camera.constrain(to: 18, deltaTime: 1.0 / 60)
        }
        #expect(camera.workingDistance == camera.distance)
    }

    /// The failure this prevents: squeezing past a pillar quietly resetting how far back the player
    /// had set the camera, so the zoom appears to drift on its own.
    @Test("An obstruction does not steal the player's zoom")
    func zoomSurvivesAnObstruction() {
        var camera = OrbitCamera()
        camera.zoom(by: 5)
        let asked = camera.distance
        camera.constrain(to: 2, deltaTime: 1.0 / 60)
        #expect(camera.distance == asked)
        // **Long enough for the half-life in use, not a frame count from when it was 0.18.**
        for _ in 0..<Int(camera.tuning.recoveryHalfLife * 60 * 12) {
            camera.constrain(to: 18, deltaTime: 1.0 / 60)
        }
        #expect(camera.workingDistance == asked)
    }

    /// A wheel zoom must arrive on the frame it was asked for; only the scenery's own changes are
    /// smoothed.
    @Test("Zooming is not eased")
    func zoomIsImmediate() {
        var camera = OrbitCamera()
        camera.constrain(to: 18, deltaTime: 1)
        camera.zoom(by: -3)
        #expect(camera.workingDistance == camera.distance)
    }

    /// **The failure a player described as "two jagged motions".** The ease ran from
    /// the obstruction all the way to the *maximum* distance while the view showed
    /// `min(distance, clearance)` — so everything above the player's own zoom was invisible, and the
    /// picture arrived the instant the eased value crossed it. A recovery has to be gradual over the
    /// part that can be seen.
    @Test("Coming out from behind scenery is gradual, not a snap")
    func recoveryIsVisiblyEased() {
        var camera = OrbitCamera()
        camera.zoom(by: -3)                       // a player zoomed in, well inside the full range
        let asked = camera.distance
        camera.constrain(to: 1, deltaTime: 1.0 / 60)
        #expect(camera.workingDistance == 1)      // in at once

        camera.constrain(to: camera.tuning.distanceRange.upperBound, deltaTime: 1.0 / 60)
        let afterOneFrame = camera.workingDistance
        #expect(afterOneFrame > 1, "the camera did not move out at all")
        #expect(afterOneFrame < asked, "one frame put the camera all the way back — that is the snap")

        // **Timed to nine tenths of the way back, not to the last millimetre.** The tail is
        // invisible and ends in a snap (see `constrain`); what a player feels is the bulk of the
        // move, and for a half-life curve that is 3.3 of them — so a curve of the shape this is
        // meant to be lands between two and five whatever the number is set to.
        var frames = 0
        let mostOfTheWay = 1 + (asked - 1) * 0.9
        while camera.workingDistance < mostOfTheWay, frames < 1200 {
            camera.constrain(to: camera.tuning.distanceRange.upperBound, deltaTime: 1.0 / 60)
            frames += 1
        }
        let halfLives = Float(frames) / 60 / camera.tuning.recoveryHalfLife
        #expect(halfLives > 2, "nine tenths of the way back inside two half-lives is a snap")
        #expect(halfLives < 5, "the camera is not easing on the half-life it was given")
    }

    @Test("The camera sits where the obstruction ray was cast")
    func directionMatchesPlacement() {
        var camera = OrbitCamera()
        camera.orbit(byYaw: 0.7, pitch: 0.2)
        let derived = camera.aimPoint + camera.offsetDirection * camera.workingDistance
        #expect(distance(derived, camera.position) < 1e-4)
        #expect(abs(length(camera.offsetDirection) - 1) < 1e-5)
    }

    /// The whole of what a game calls once a step: ask the world along the camera's own line, then take it in.
    @Test("Keeping clear asks along the camera's own line and takes it in at once")
    func keepClearPullsIn() {
        var camera = OrbitCamera()
        camera.pitch = 0
        camera.shoulderHeight = 1.7
        camera.keepClear(of: CharacterController.Surroundings(solids: [pillar(at: 5)]), deltaTime: 1.0 / 60)
        #expect(abs(camera.workingDistance - 3.8) < 0.001)
        #expect(camera.distance == camera.tuning.restingDistance, "the player's zoom is untouched")
    }
}
