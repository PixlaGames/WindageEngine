//
//  CharacterControllerTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// A hillside that is rough everywhere: a long slope, plus bumps at two scales. Stands in for the
/// fractal terrain the walking half was tuned on — what matters is that there is always a bump.
private let hillside: @Sendable (Float, Float) -> Float = { x, z in
    -z * 0.18 + 0.35 * sin(x * 0.9) * cos(z * 1.3) + 0.08 * sin(x * 5.1 + z * 4.3)
}

private let step: Float = 1.0 / 120
private let flat = CharacterController.Surroundings()

/// Boxes as solids that stand still and are their own plan.
private func boxes(_ boxes: [BoundingBox]) -> [CharacterController.Surroundings.Solid] {
    boxes.map { .init(bounds: $0) }
}

private func run(_ controller: inout CharacterController,
                 seconds: Float,
                 yaw: Float = 0,
                 _ input: MovementInput = MovementInput(),
                 isJumpHeld jump: Bool = false,
                 isCrouching crouching: Bool = false,
                 in world: CharacterController.Surroundings = flat) {
    for _ in 0..<Int((seconds / step).rounded()) {
        controller.step(yaw: yaw, input: input, isJumpHeld: jump, isCrouching: crouching,
                        deltaTime: step, in: world)
    }
}

private func ground(_ p: SIMD3<Float>) -> SIMD2<Float> { SIMD2(p.x, p.z) }

/// A box standing on the ground at the origin's z, `height` tall, starting `ahead` metres in front.
private func ledge(height: Float, ahead: Float = 2, depth: Float = 4) -> BoundingBox {
    BoundingBox(minimum: SIMD3(-3, 0, -ahead - depth), maximum: SIMD3(3, height, -ahead))
}

// MARK: - Walking, carried over

@Suite("Character controller — walking")
struct CharacterWalkingTests {

    private var forwards: MovementInput { MovementInput(forward: 1) }

    /// **The bug the free-flying camera had.** Walking along the look direction means aiming at your
    /// feet walks you into the hill at `cos θ`. The controller never sees pitch; this pins it.
    @Test("The walk speed is the walk speed, on the level")
    func walkSpeedIsExact() {
        var c = CharacterController(feet: .zero)
        run(&c, seconds: 2, forwards)
        let crossed = simd_distance(ground(c.feet), .zero)
        let expected = Float(Int((2 / step).rounded())) * step * c.tuning.walkSpeed
        #expect(abs(crossed - expected) < 0.01, "crossed \(crossed) m rather than \(expected)")
    }

    /// Horizontal speed is the same downhill, uphill and across. A shooter that drags on an incline
    /// feels broken.
    @Test("The slope does not change how fast the ground goes by")
    func slopeDoesNotChangeGroundSpeed() {
        let world = CharacterController.Surroundings(groundHeight: hillside)
        for (name, yaw) in [("uphill", Float(0)), ("downhill", Float.pi), ("across", Float.pi / 2)] {
            var c = CharacterController(feet: SIMD3(0, hillside(0, 0), 0))
            run(&c, seconds: 1.5, yaw: yaw, forwards, in: world)
            let crossed = simd_distance(ground(c.feet), .zero)
            let expected = Float(Int((1.5 / step).rounded())) * step * c.tuning.walkSpeed
            #expect(abs(crossed - expected) < 0.01, "\(name): crossed \(crossed) m against \(expected)")
        }
    }

    @Test("The feet stay on the terrain, and the eye stays near its height above it")
    func followsTheGround() {
        let world = CharacterController.Surroundings(groundHeight: hillside)
        var c = CharacterController(feet: SIMD3(0, hillside(0, 0), 0))
        var worst: Float = 0
        for _ in 0..<(120 * 10) {
            c.step(yaw: 0, input: forwards, deltaTime: step, in: world)
            #expect(abs(c.feet.y - hillside(c.feet.x, c.feet.z)) < 1e-4)
            worst = max(worst, abs(c.eye.y - hillside(c.feet.x, c.feet.z) - c.tuning.eyeHeight))
        }
        #expect(c.isGrounded)
        #expect(worst < 0.35, "the eye drifted \(worst) m from its standing height")
    }

    /// **Settling, not snapping.** There is always a bump; tracking it exactly at 120 Hz reads as a
    /// jitter.
    @Test("The eye is steadier than the ground")
    func eyeIsSteadierThanTheGround() {
        let world = CharacterController.Surroundings(groundHeight: hillside)
        var c = CharacterController(feet: SIMD3(0, hillside(0, 0), 0))
        var eyeJerk: Float = 0, groundJerk: Float = 0
        var previousEye = c.eye.y, previousGround = c.feet.y
        for _ in 0..<(120 * 4) {
            c.step(yaw: .pi / 2, input: forwards, deltaTime: step, in: world)
            eyeJerk = max(eyeJerk, abs(c.eye.y - previousEye))
            groundJerk = max(groundJerk, abs(c.feet.y - previousGround))
            previousEye = c.eye.y
            previousGround = c.feet.y
        }
        #expect(eyeJerk < groundJerk, "the eye moved \(eyeJerk) m a step against the ground's \(groundJerk)")
    }

    /// **Normalising the direction threw the deflection away**: every push past the dead zone walked
    /// at full speed, so the stick's response curve reached the look and never the feet.
    @Test("A stick pushed part of the way walks part of the speed")
    func stickPartWayWalksPartSpeed() {
        var c = CharacterController(feet: .zero)
        run(&c, seconds: 1, MovementInput(forward: 0.3))
        #expect(abs(simd_length(ground(c.feet)) - 1.8) < 0.01,
                "a stick at 0.3 should cover 0.3 of 6 m, not all of it: \(simd_length(ground(c.feet)))")
        var camera = Camera()
        for _ in 0..<120 { camera.advance(MovementInput(forward: 0.3), deltaTime: step) }
        #expect(abs(simd_length(camera.position) - 1.8) < 0.01, "the flying camera had the same fault")
    }

    @Test("Walking diagonally is not faster")
    func diagonalIsNotFaster() {
        var straight = CharacterController(feet: .zero)
        var angled = CharacterController(feet: .zero)
        run(&straight, seconds: 1, forwards)
        run(&angled, seconds: 1, MovementInput(forward: 1, strafe: 1))
        #expect(abs(simd_length(ground(straight.feet)) - simd_length(ground(angled.feet))) < 0.05)
    }

    @Test("No input means no movement")
    func standingStillIsStill() {
        var c = CharacterController(feet: SIMD3(2, 0, 3))
        run(&c, seconds: 3)
        #expect(c.feet == SIMD3(2, 0, 3))
        #expect(c.isGrounded)
    }
}

// MARK: - Crouch and slide, carried over

@Suite("Character controller — crouch and slide")
struct CharacterPostureTests {

    private var running: MovementInput { MovementInput(forward: 1, isSprinting: true) }

    @Test("Crouching lowers the eye and standing raises it again")
    func postureChanges() {
        var c = CharacterController(feet: .zero)
        run(&c, seconds: 2, isCrouching: true)
        #expect(abs(c.eye.y - c.tuning.crouchedEyeHeight) < 0.02)
        run(&c, seconds: 2)
        #expect(abs(c.eye.y - c.tuning.eyeHeight) < 0.02)
    }

    @Test("The posture moves at a rate, not instantly")
    func postureIsNotATeleport() {
        var c = CharacterController(feet: .zero)
        let before = c.eye.y
        c.step(yaw: 0, input: MovementInput(), isCrouching: true, deltaTime: step, in: flat)
        let moved = before - c.eye.y
        #expect(moved > 0)
        #expect(moved < c.tuning.postureRate * step * 1.5)
    }

    /// **The cost. Without it the posture is free and you would simply hold it.**
    @Test("Crouched you move much slower, and cannot sprint")
    func crouchingCostsSpeed() {
        var standing = CharacterController(feet: .zero)
        var crouched = CharacterController(feet: .zero)
        var sprintCrouched = CharacterController(feet: .zero)
        run(&standing, seconds: 2, MovementInput(forward: 1))
        run(&crouched, seconds: 2, MovementInput(forward: 1), isCrouching: true)
        run(&sprintCrouched, seconds: 2, running, isCrouching: true)
        let a = simd_length(ground(standing.feet)), b = simd_length(ground(crouched.feet))
        #expect(b < a * 0.6)
        #expect(abs(simd_length(ground(sprintCrouched.feet)) - b) < 0.01, "sprint worked from a crouch")
    }

    /// Sprints, then crouches, and reports how far the slide carried and how long it lasted.
    private func slide(steering input: MovementInput? = nil)
        -> (distance: Float, seconds: Float, controller: CharacterController, start: SIMD2<Float>) {
        var c = CharacterController(feet: .zero)
        run(&c, seconds: 1, running)
        let start = ground(c.feet)
        var seconds: Float = 0
        // `repeat`: the slide only exists after the first crouching step.
        repeat {
            c.step(yaw: 0, input: input ?? running, isCrouching: true, deltaTime: step, in: flat)
            seconds += step
        } while c.isSliding && seconds < 5
        return (simd_distance(ground(c.feet), start), seconds, c, start)
    }

    @Test("Crouching while sprinting slides instead of stopping")
    func itSlides() {
        let result = slide()
        let crouchWalk = CharacterController.Tuning().walkSpeed
            * CharacterController.Tuning().crouchedSpeedFraction * result.seconds
        #expect(result.distance > crouchWalk * 2, "no momentum: \(result.distance) m")
        #expect(abs(result.seconds - CharacterController.Tuning().slideDuration) < 0.05)
        // Momentum, not a way to travel.
        #expect(result.distance < 18, "a \(result.distance) m slide is a way of getting places")
    }

    @Test("Holding crouch does not restart the slide")
    func slideDoesNotChain() {
        var c = slide().controller
        for _ in 0..<600 {
            c.step(yaw: 0, input: running, isCrouching: true, deltaTime: step, in: flat)
            #expect(!c.isSliding)
        }
    }

    @Test("You cannot slide from a standstill or a walk")
    func slideNeedsSprintSpeed() {
        var still = CharacterController(feet: .zero)
        still.step(yaw: 0, input: MovementInput(), isCrouching: true, deltaTime: step, in: flat)
        #expect(!still.isSliding)

        var walking = CharacterController(feet: .zero)
        run(&walking, seconds: 1, MovementInput(forward: 1))
        walking.step(yaw: 0, input: MovementInput(forward: 1), isCrouching: true, deltaTime: step, in: flat)
        #expect(!walking.isSliding)
    }

    /// **Committed.** Entered running down −Z with a hard left demanded throughout.
    @Test("A slide goes where it was entered, not where the stick says")
    func slideIsCommitted() {
        let result = slide(steering: MovementInput(strafe: -1, isSprinting: true))
        let travel = ground(result.controller.feet) - result.start
        #expect(travel.y < -8, "it barely carried forward: \(travel)")
        #expect(abs(travel.x) < abs(travel.y) * 0.4, "that is steering, not sliding: \(travel)")
        #expect(abs(travel.x) > 0.3, "no influence at all — a rail: \(travel)")
    }

    @Test("The slide's camera dip peaks early and recovers")
    func dipRecovers() {
        var c = CharacterController(feet: .zero)
        run(&c, seconds: 1, running)
        #expect(c.slideCameraDip == 0)
        var samples: [Float] = []
        repeat {
            c.step(yaw: 0, input: running, isCrouching: true, deltaTime: step, in: flat)
            samples.append(c.slideCameraDip)
        } while c.isSliding
        let peak = samples.min() ?? 0
        #expect(peak < -0.05)
        #expect(c.slideCameraDip == 0)
        #expect((samples.firstIndex(of: peak) ?? samples.count) < samples.count / 3)
    }
}

// MARK: - Standing on things: new

@Suite("Character controller — standing on things")
struct CharacterFootingTests {

    private var forwards: MovementInput { MovementInput(forward: 1) }

    /// **Stairs.** Below the step height, a ledge is walked up without a jump, and the feet end up
    /// exactly on its top.
    @Test("A ledge below the step height is walked onto")
    func stepsUpALowLedge() {
        let world = CharacterController.Surroundings(solids: boxes([ledge(height: 0.3)]))
        var c = CharacterController(feet: .zero)
        run(&c, seconds: 1, forwards, in: world)
        #expect(c.feet.z < -2.5, "it did not get onto the ledge: \(c.feet)")
        #expect(abs(c.feet.y - 0.3) < 1e-4)
        #expect(c.isGrounded)
    }

    /// **A crate is cover.** Taller than a step, it stops you, and you stay on the ground in front of
    /// it rather than climbing it or sinking into it.
    @Test("A crate taller than the step height stops you")
    func crateStops() {
        let crate = ledge(height: 1.5)
        let world = CharacterController.Surroundings(solids: boxes([crate]))
        var c = CharacterController(feet: .zero)
        run(&c, seconds: 2, forwards, in: world)
        #expect(c.feet.y == 0)
        #expect(c.feet.z >= crate.maximum.z + c.tuning.radius - 1e-3,
                "walked into the crate: feet at \(c.feet.z), face at \(crate.maximum.z)")
        #expect(c.feet.z < crate.maximum.z + c.tuning.radius + 0.05,
                "stopped short of the crate: \(c.feet.z)")
    }

    /// **Met, not stopped short of.** Refusing a blocked step outright leaves the player wherever
    /// the last whole step ended — found in the sample as a 4 cm gap at a walk and 15 cm at a sprint.
    @Test("Running into a wall ends touching it, at a walk or a sprint")
    func wallIsMet() {
        let crate = ledge(height: 1.5)
        let world = CharacterController.Surroundings(solids: boxes([crate]))
        for input in [MovementInput(forward: 1), MovementInput(forward: 1, isSprinting: true)] {
            var c = CharacterController(feet: .zero)
            run(&c, seconds: 1, input, in: world)
            let gap = c.feet.z - (crate.maximum.z + c.tuning.radius)
            #expect(gap >= 0 && gap < 0.01, "\(input.isSprinting ? "sprinting" : "walking"): \(gap) m short")
        }
    }

    /// **Walking into a wall at an angle slides along it.** Refusing the whole move is what makes a
    /// wall feel like glue — and is also the only way out of a corner.
    @Test("A wall hit at an angle is slid along, not stuck to")
    func slidesAlongWalls() {
        let wall = BoundingBox(minimum: SIMD3(-50, 0, -2), maximum: SIMD3(50, 3, -1))
        let world = CharacterController.Surroundings(solids: boxes([wall]))
        var c = CharacterController(feet: .zero)
        // Forward and right at once, into a wall that runs left–right.
        run(&c, seconds: 2, MovementInput(forward: 1, strafe: 1), in: world)
        #expect(c.feet.x > 5, "it stuck to the wall: \(c.feet)")
        #expect(c.feet.z > -1 + c.tuning.radius - 1e-3)
    }

    /// **Walking off an edge falls**, and lands on whatever is below.
    @Test("Walking off something taller than a step falls, and lands")
    func fallsOffAnEdge() {
        let platform = BoundingBox(minimum: SIMD3(-3, 0, -3), maximum: SIMD3(3, 1.2, 3))
        let world = CharacterController.Surroundings(solids: boxes([platform]))
        var c = CharacterController(feet: SIMD3(0, 1.2, 0))
        var wasAirborne = false
        for _ in 0..<(120 * 2) {
            c.step(yaw: 0, input: forwards, deltaTime: step, in: world)
            if !c.isGrounded { wasAirborne = true }
        }
        #expect(wasAirborne, "it walked off a 1.2 m drop without leaving the ground")
        #expect(c.isGrounded)
        #expect(c.feet.y == 0)
        #expect(c.feet.z < -3)
    }

    /// Down a step is not a fall: the feet follow it, and the eye eases after them.
    @Test("Stepping down a low ledge stays grounded")
    func stepsDown() {
        let platform = BoundingBox(minimum: SIMD3(-3, 0, -3), maximum: SIMD3(3, 0.3, 3))
        let world = CharacterController.Surroundings(solids: boxes([platform]))
        var c = CharacterController(feet: SIMD3(0, 0.3, 0))
        for _ in 0..<(120 * 2) {
            c.step(yaw: 0, input: forwards, deltaTime: step, in: world)
            #expect(c.isGrounded, "a 30 cm step down became a fall at \(c.feet)")
        }
        #expect(c.feet.y == 0)
    }

    /// **The feet move at once; the eye follows.** Stairs that snapped the eye would stutter.
    @Test("Stepping up moves the feet at once and the eye over a moment")
    func eyeEasesUpAStep() {
        let world = CharacterController.Surroundings(solids: boxes([ledge(height: 0.4, ahead: 0.5)]))
        var c = CharacterController(feet: .zero)
        var eyeRise: [Float] = []
        var previous = c.eye.y
        for _ in 0..<60 {
            c.step(yaw: 0, input: forwards, deltaTime: step, in: world)
            eyeRise.append(c.eye.y - previous)
            previous = c.eye.y
        }
        #expect(abs(c.feet.y - 0.4) < 1e-4)
        #expect((eyeRise.max() ?? 0) < 0.2, "the eye jumped \(eyeRise.max() ?? 0) m in one step")
    }

    @Test("A jump clears a low wall but not a crate")
    func jumpHeight() {
        var c = CharacterController(feet: .zero)
        var apex: Float = 0
        c.step(yaw: 0, input: MovementInput(), isJumpHeld: true, deltaTime: step, in: flat)
        for _ in 0..<(120 * 2) {
            c.step(yaw: 0, input: MovementInput(), isJumpHeld: true, deltaTime: step, in: flat)
            apex = max(apex, c.feet.y)
        }
        #expect(apex > 0.9 && apex < 1.2, "a jump reached \(apex) m")
        #expect(c.isGrounded)
    }

    /// **Holding jump is one jump.** Without the edge, holding the key bounces for ever.
    @Test("Holding jump does not bounce")
    func holdingJumpIsOneJump() {
        var c = CharacterController(feet: .zero)
        var takeoffs = 0
        var wasGrounded = true
        for _ in 0..<(120 * 3) {
            c.step(yaw: 0, input: MovementInput(), isJumpHeld: true, deltaTime: step, in: flat)
            if wasGrounded && !c.isGrounded { takeoffs += 1 }
            wasGrounded = c.isGrounded
        }
        #expect(takeoffs == 1)
    }

    /// **Coyote time.** A jump pressed just after running off an edge still counts.
    @Test("A jump just after leaving an edge still jumps")
    func coyoteTime() {
        let platform = BoundingBox(minimum: SIMD3(-3, 0, -3), maximum: SIMD3(3, 1.2, 0))
        let world = CharacterController.Surroundings(solids: boxes([platform]))
        var c = CharacterController(feet: SIMD3(0, 1.2, -1))
        // Walk off the +z edge (yaw π faces +z) until airborne, then press jump two steps later.
        while c.isGrounded { c.step(yaw: .pi, input: forwards, deltaTime: step, in: world) }
        c.step(yaw: .pi, input: forwards, deltaTime: step, in: world)
        let before = c.verticalVelocity
        c.step(yaw: .pi, input: forwards, isJumpHeld: true, deltaTime: step, in: world)
        #expect(c.verticalVelocity > before + 3, "the late jump was eaten: \(c.verticalVelocity)")
    }

    /// **Jump buffering.** Pressed a moment before landing, it jumps on landing.
    @Test("A jump pressed just before landing jumps on landing")
    func jumpBuffer() {
        var c = CharacterController(feet: SIMD3(0, 0.6, 0))
        c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: flat)   // falling
        while c.feet.y > 0.08 { c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: flat) }
        c.step(yaw: 0, input: MovementInput(), isJumpHeld: true, deltaTime: step, in: flat)  // pressed in the air
        var rose = false
        for _ in 0..<12 {
            c.step(yaw: 0, input: MovementInput(), isJumpHeld: false, deltaTime: step, in: flat)
            if c.verticalVelocity > 3 { rose = true }
        }
        #expect(rose, "a jump pressed just before landing was lost")
    }

    @Test("No jump out of a slide")
    func noJumpFromSlide() {
        var c = CharacterController(feet: .zero)
        run(&c, seconds: 1, MovementInput(forward: 1, isSprinting: true))
        c.step(yaw: 0, input: MovementInput(forward: 1, isSprinting: true), isCrouching: true,
               deltaTime: step, in: flat)
        #expect(c.isSliding)
        c.step(yaw: 0, input: MovementInput(forward: 1, isSprinting: true), isJumpHeld: true, isCrouching: true,
               deltaTime: step, in: flat)
        #expect(c.isGrounded)
    }

    /// A head against the underside of something stops the rise, rather than passing through.
    @Test("A jump under a low ceiling stops at the ceiling")
    func ceilingStopsAJump() {
        let ceiling = BoundingBox(minimum: SIMD3(-3, 2.2, -3), maximum: SIMD3(3, 2.5, 3))
        let world = CharacterController.Surroundings(solids: boxes([ceiling]))
        var c = CharacterController(feet: .zero)
        var highestHead: Float = 0
        c.step(yaw: 0, input: MovementInput(), isJumpHeld: true, deltaTime: step, in: world)
        for _ in 0..<120 {
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: world)
            highestHead = max(highestHead, c.bounds.maximum.y)
        }
        #expect(highestHead <= 2.2 + 1e-3, "the head reached \(highestHead) m into a ceiling at 2.2")
        #expect(c.isGrounded)
    }

    /// **A fast fall cannot skip a thin floor.** Landing is measured from where the feet were.
    @Test("A long fall lands on a thin platform rather than passing through it")
    func fastFallLands() {
        let slab = BoundingBox(minimum: SIMD3(-3, 4.95, -3), maximum: SIMD3(3, 5, 3))
        let world = CharacterController.Surroundings(solids: boxes([slab]))
        var c = CharacterController(feet: SIMD3(0, 60, 0))
        run(&c, seconds: 4, in: world)
        #expect(abs(c.feet.y - 5) < 1e-4, "fell to \(c.feet.y)")
        #expect(c.isGrounded)
    }

    /// Standing on a crate and walking across it is not walking into it.
    @Test("Walking across the top of a solid is not blocked by it")
    func walksAcrossATop() {
        let top = BoundingBox(minimum: SIMD3(-5, 0, -20), maximum: SIMD3(5, 1.5, 5))
        let world = CharacterController.Surroundings(solids: boxes([top]))
        var c = CharacterController(feet: SIMD3(0, 1.5, 0))
        run(&c, seconds: 2, forwards, in: world)
        #expect(c.feet.z < -10)
        #expect(abs(c.feet.y - 1.5) < 1e-4)
    }
}

// MARK: - Footfalls and landings

@Suite("Character controller — what it reports")
struct CharacterEventTests {

    private func strides(_ c: inout CharacterController, seconds: Float, _ input: MovementInput,
                         isCrouching crouching: Bool = false,
                         in world: CharacterController.Surroundings = flat) -> [CharacterController.Event] {
        var all: [CharacterController.Event] = []
        for _ in 0..<Int((seconds / step).rounded()) {
            c.step(yaw: 0, input: input, isCrouching: crouching, deltaTime: step, in: world)
            all += c.events
        }
        return all
    }

    private func strideCount(_ events: [CharacterController.Event]) -> Int {
        events.filter { if case .stride = $0 { true } else { false } }.count
    }

    /// A cadence the ear takes for feet: about two a second walking, more sprinting, fewer crouched.
    @Test("Walking, sprinting and crouching step at different rates")
    func cadence() {
        var walk = CharacterController(feet: .zero)
        var sprint = CharacterController(feet: .zero)
        var crouch = CharacterController(feet: .zero)
        let w = strideCount(strides(&walk, seconds: 4, MovementInput(forward: 1))) / 4
        let s = strideCount(strides(&sprint, seconds: 4, MovementInput(forward: 1, isSprinting: true))) / 4
        let c = strideCount(strides(&crouch, seconds: 4, MovementInput(forward: 1), isCrouching: true)) / 4
        #expect(w >= 2 && w <= 3, "walking \(w) a second")
        #expect(s > w, "sprinting \(s) against walking \(w)")
        #expect(c < w, "crouched \(c) against walking \(w)")
    }

    /// **Distance covered, not asked for.** Pushing into a wall asks for six metres a second.
    @Test("Walking into a wall does not march on the spot")
    func noStepsAgainstAWall() {
        let world = CharacterController.Surroundings(solids: boxes([ledge(height: 2, ahead: 0.35)]))
        var c = CharacterController(feet: .zero)
        _ = strides(&c, seconds: 0.5, MovementInput(forward: 1), in: world)     // reach the wall
        let pressed = strides(&c, seconds: 3, MovementInput(forward: 1), in: world)
        #expect(strideCount(pressed) == 0, "\(strideCount(pressed)) footsteps against a wall")
    }

    @Test("Standing still makes no footsteps")
    func stillIsSilent() {
        var c = CharacterController(feet: .zero)
        #expect(strides(&c, seconds: 3, MovementInput()).isEmpty)
    }

    /// Not a whole stride's silence after the key goes down.
    @Test("The first footstep comes soon after setting off")
    func firstStepIsPrompt() {
        var c = CharacterController(feet: .zero)
        var seconds: Float = 0
        while seconds < 2 {
            c.step(yaw: 0, input: MovementInput(forward: 1), deltaTime: step, in: flat)
            seconds += step
            if c.events.contains(where: { if case .stride = $0 { true } else { false } }) { break }
        }
        let strideTime = c.tuning.walkStride / c.tuning.walkSpeed
        #expect(seconds < strideTime * 0.6, "the first step took \(seconds) s of a \(strideTime) s stride")
    }

    /// **A foot on every tread.** Distance alone climbs a flight of stairs in half the footsteps,
    /// because a stride at these speeds is longer than a tread.
    @Test("Climbing stairs sounds a foot on each tread")
    func stairsGetAFootEach() {
        // Four 0.3 m treads, 1 m deep, rising away along −z.
        var treads: [BoundingBox] = []
        for i in 0..<4 {
            let near = -Float(i + 1), far = -Float(i + 2), top = 0.3 * Float(i + 1)
            treads.append(BoundingBox(minimum: SIMD3<Float>(-3, 0, far), maximum: SIMD3<Float>(3, top, near)))
        }
        let landing = BoundingBox(minimum: SIMD3(-3, 0, -12), maximum: SIMD3(3, 1.2, -5))
        var c = CharacterController(feet: .zero)
        var climbSteps = 0
        for _ in 0..<(120 * 2) {
            let before = c.feet.y
            c.step(yaw: 0, input: MovementInput(forward: 1), deltaTime: step,
                   in: CharacterController.Surroundings(solids: boxes(treads + [landing])))
            let rose = c.feet.y > before + 0.1
            if rose && c.events.contains(where: { if case .stride = $0 { true } else { false } }) {
                climbSteps += 1
            }
        }
        #expect(abs(c.feet.y - 1.2) < 1e-4)
        #expect(climbSteps >= 4, "\(climbSteps) footsteps for four treads")
    }

    /// **The mirror of the climb**: descending the same four treads sounded one footstep at first,
    /// against the climb's four. Walked from mirrored starts — a metre short of the stairs either way —
    /// so the stride arrives at the first tread edge in the same phase, down as well as up.
    @Test("Coming down stairs sounds as many footsteps on the treads as going up")
    func descendingMatchesClimbing() {
        var treads: [BoundingBox] = []
        for i in 0..<4 {
            let near = -Float(i + 1), far = -Float(i + 2), top = 0.3 * Float(i + 1)
            treads.append(BoundingBox(minimum: SIMD3<Float>(-3, 0, far), maximum: SIMD3<Float>(3, top, near)))
        }
        let landing = BoundingBox(minimum: SIMD3(-3, 0, -12), maximum: SIMD3(3, 1.2, -5))
        let world = CharacterController.Surroundings(solids: boxes(treads + [landing]))
        func treadSteps(from start: SIMD3<Float>, yaw: Float) -> Int {
            var c = CharacterController(feet: start)
            var count = 0
            for _ in 0..<240 {
                let before = c.feet.y
                c.step(yaw: yaw, input: MovementInput(forward: 1), deltaTime: step, in: world)
                if abs(c.feet.y - before) > 0.1 && c.events.contains(where: { if case .stride = $0 { true } else { false } }) {
                    count += 1
                }
            }
            return count
        }
        let up = treadSteps(from: SIMD3(0, 0, 0), yaw: 0)
        let down = treadSteps(from: SIMD3(0, 1.2, -6), yaw: .pi)
        #expect(up >= 3, "the climb itself: \(up)")
        #expect(down == up, "\(down) footsteps coming down four treads, \(up) going up")
    }

    /// A gentle slope is not stairs, in either direction: no extra footfalls going down one.
    @Test("Walking down a slope keeps its ordinary stride")
    func slopeDownIsNotStairs() {
        let slope = CharacterController.Surroundings(groundHeight: { _, z in 0.15 * z })
        var c = CharacterController(feet: SIMD3(0, 1.5, 10), tuning: CharacterController.Tuning())
        var strides = 0
        for _ in 0..<120 {
            c.step(yaw: 0, input: MovementInput(forward: 1), deltaTime: step, in: slope)
            strides += c.events.filter { if case .stride = $0 { true } else { false } }.count
        }
        // Six metres at 2.6 m a stride, from a first step at 0.6: two or three — not one per bump.
        #expect(strides >= 2 && strides <= 3, "\(strides) footsteps walking six metres down a slope")
    }

    @Test("Feet alternate")
    func feetAlternate() {
        var c = CharacterController(feet: .zero)
        let feet = strides(&c, seconds: 3, MovementInput(forward: 1)).compactMap { event -> CharacterController.Foot? in
            if case .stride(let foot, _) = event { foot } else { nil }
        }
        #expect(feet.count > 4)
        #expect(zip(feet, feet.dropFirst()).allSatisfy { $0 != $1 })
    }

    /// A slide is a body skidding; footsteps under it would be feet that are not moving.
    @Test("A slide makes no footsteps")
    func slideIsSilent() {
        var c = CharacterController(feet: .zero)
        _ = strides(&c, seconds: 1, MovementInput(forward: 1, isSprinting: true))
        c.step(yaw: 0, input: MovementInput(forward: 1, isSprinting: true), isCrouching: true, deltaTime: step, in: flat)
        var during: [CharacterController.Event] = []
        while c.isSliding {
            c.step(yaw: 0, input: MovementInput(forward: 1, isSprinting: true), isCrouching: true,
                   deltaTime: step, in: flat)
            if c.isSliding { during += c.events }
        }
        #expect(strideCount(during) == 0)
    }

    @Test("A fall lands once, with the speed it hit at")
    func landing() {
        var c = CharacterController(feet: SIMD3(0, 1.8, 0))
        var landings: [Float] = []
        for _ in 0..<(120 * 2) {
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: flat)
            for case .landed(let speed) in c.events { landings.append(speed) }
        }
        #expect(landings.count == 1)
        // From rest through 1.8 m at 20 m/s²: √(2 · 20 · 1.8) ≈ 8.5 m/s.
        #expect(abs((landings.first ?? 0) - (2 * 20 * 1.8 as Float).squareRoot()) < 0.4)
    }

    /// Down a stair is not a landing — the body never left the ground.
    @Test("Stepping down a stair is not a landing")
    func stairIsNotALanding() {
        let platform = BoundingBox(minimum: SIMD3(-3, 0, -3), maximum: SIMD3(3, 0.3, 3))
        let world = CharacterController.Surroundings(solids: boxes([platform]))
        var c = CharacterController(feet: SIMD3(0, 0.3, 0))
        let events = strides(&c, seconds: 2, MovementInput(forward: 1), in: world)
        #expect(!events.contains { if case .landed = $0 { true } else { false } })
    }

    @Test("A jump is reported, and so is coming down from it")
    func jumpAndLand() {
        var c = CharacterController(feet: .zero)
        var events: [CharacterController.Event] = []
        c.step(yaw: 0, input: MovementInput(), isJumpHeld: true, deltaTime: step, in: flat)
        events += c.events
        for _ in 0..<120 {
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: flat)
            events += c.events
        }
        #expect(events.first == .jumped)
        #expect(events.contains { if case .landed = $0 { true } else { false } })
    }

    /// What a footstep needs to sound like anything: which surface is underfoot.
    @Test("It knows which solid it is standing on, and when it is on the terrain")
    func knowsTheGround() {
        let slab = BoundingBox(minimum: SIMD3(-3, 0, -8), maximum: SIMD3(3, 0.3, -2))
        let world = CharacterController.Surroundings(solids: boxes([ledge(height: 5, ahead: 30), slab]))
        var c = CharacterController(feet: .zero)
        c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: world)
        #expect(c.groundSolid == nil)
        _ = strides(&c, seconds: 0.8, MovementInput(forward: 1), in: world)
        #expect(c.groundSolid == 1, "on the slab, which is solid 1")
        _ = strides(&c, seconds: 1.2, MovementInput(forward: 1), in: world)
        #expect(c.groundSolid == nil, "off the far end, back on the terrain")
    }

    @Test("Events are this step's only")
    func eventsClear() {
        var c = CharacterController(feet: SIMD3(0, 0.5, 0))
        var sawLanding = false
        for _ in 0..<120 {
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: flat)
            if c.events.contains(where: { if case .landed = $0 { true } else { false } }) { sawLanding = true; break }
        }
        #expect(sawLanding)
        c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: flat)
        #expect(c.events.isEmpty)
    }
}

// MARK: - The landing dip

@Suite("Character controller — the landing dip")
struct CharacterLandingDipTests {

    /// Drops from a height and records the compression every step from the landing on.
    private func drop(from height: Float) -> (curve: [Float], impact: Float, controller: CharacterController) {
        var c = CharacterController(feet: SIMD3(0, height, 0))
        var curve: [Float] = []
        var impact: Float = 0
        var landed = false
        for _ in 0..<(120 * 3) {
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: flat)
            for case .landed(let speed) in c.events { impact = speed; landed = true }
            if landed { curve.append(c.landingCompression) }
        }
        return (curve, impact, c)
    }

    @Test("A fall dips as far as its impact says, and no further")
    func depthFollowsImpact() {
        let result = drop(from: 1.8)
        let tuning = CharacterController.Tuning()
        let expected = (result.impact - tuning.landingSoftImpact)
            / (tuning.landingHardImpact - tuning.landingSoftImpact)
        let peak = result.curve.max() ?? 0
        #expect(abs(peak - expected) < expected * 0.12, "peaked at \(peak) against \(expected)")
    }

    /// **Down fast enough to be the impact, up slowly enough to be the legs.**
    @Test("It bottoms out quickly and recovers within half a second, without bouncing")
    func shape() {
        let curve = drop(from: 1.8).curve
        let peakStep = curve.firstIndex(of: curve.max() ?? 0) ?? 0
        let peakSeconds = Float(peakStep) * step
        #expect(peakSeconds > 0.04 && peakSeconds < 0.11, "lowest at \(peakSeconds) s")
        #expect(curve[Int(0.5 / step)] < 0.03, "still \(curve[Int(0.5 / step)]) compressed at 0.5 s")
        #expect(curve.allSatisfy { $0 >= 0 }, "the legs overshot and lifted the eye")
        // Critically damped: after the lowest point, it only ever comes back up.
        #expect(zip(curve[peakStep...], curve[(peakStep + 1)...]).allSatisfy { $0 >= $1 - 1e-6 })
    }

    @Test("A harder landing dips deeper, up to a limit")
    func harderIsDeeper() {
        let low = drop(from: 0.8).curve.max() ?? 0
        let high = drop(from: 2.5).curve.max() ?? 0
        let extreme = drop(from: 30).curve.max() ?? 0
        #expect(high > low)
        #expect(extreme < 1.12, "the hardest landing compressed \(extreme)")
    }

    /// A fall shorter than a step is a step down, not a landing, so the soft case is a small hop.
    @Test("A landing too soft to feel does not dip")
    func softIsFlat() {
        var tuning = CharacterController.Tuning()
        tuning.jumpSpeed = 2.5                       // lands at 2.5 m/s, under the soft threshold
        var c = CharacterController(feet: .zero, tuning: tuning)
        var landed = false
        c.step(yaw: 0, input: MovementInput(), isJumpHeld: true, deltaTime: step, in: flat)
        for _ in 0..<120 {
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: flat)
            if c.events.contains(where: { if case .landed = $0 { true } else { false } }) { landed = true }
            #expect(c.landingCompression == 0)
        }
        #expect(landed)
    }

    /// The exact step lands on the same curve however long the step is.
    @Test("The dip is the same at 60 Hz and 240 Hz")
    func stepSizeIndependent() {
        func peak(hz: Float) -> Float {
            let dt = 1 / hz
            var c = CharacterController(feet: SIMD3(0, 1.8, 0))
            var deepest: Float = 0
            for _ in 0..<Int(hz * 2) {
                c.step(yaw: 0, input: MovementInput(), deltaTime: dt, in: flat)
                deepest = max(deepest, c.landingCompression)
            }
            return deepest
        }
        // Not identical — the landing speed itself depends on where the step boundaries fall.
        #expect(abs(peak(hz: 60) - peak(hz: 240)) < 0.06, "\(peak(hz: 60)) against \(peak(hz: 240))")
    }

    /// The legs take the weight — the eye really is lower — while the feet stay on the ground.
    @Test("The eye drops and the feet do not")
    func eyeNotFeet() {
        var c = CharacterController(feet: SIMD3(0, 1.8, 0))
        var deepest: Float = 0
        for _ in 0..<(120 * 2) {
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: flat)
            if c.isGrounded {
                #expect(c.feet.y == 0)
                deepest = max(deepest, c.tuning.eyeHeight - (c.eye.y - c.feet.y))
            }
        }
        #expect(deepest > 0.05, "the eye dropped only \(deepest) m")
        #expect(abs(deepest - (drop(from: 1.8).curve.max() ?? 0) * c.tuning.landingDropMax) < 0.01)
    }

    @Test("The view tips down with the drop, and comes back")
    func viewTips() {
        var c = CharacterController(feet: SIMD3(0, 1.8, 0))
        var lowest: Float = 0
        for _ in 0..<(120 * 2) {
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: flat)
            lowest = min(lowest, c.landingCameraDip)
        }
        #expect(lowest < -0.02)
        #expect(abs(c.landingCameraDip) < 1e-3)
    }

    @Test("Stepping down a stair does not dip")
    func stairsDoNotDip() {
        let platform = BoundingBox(minimum: SIMD3(-3, 0, -3), maximum: SIMD3(3, 0.3, 3))
        var c = CharacterController(feet: SIMD3(0, 0.3, 0))
        for _ in 0..<(120 * 2) {
            c.step(yaw: 0, input: MovementInput(forward: 1), deltaTime: step,
                   in: CharacterController.Surroundings(solids: boxes([platform])))
            #expect(c.landingCompression == 0)
        }
    }
}

// MARK: - Head bob

@Suite("Character controller — head bob")
struct CharacterHeadBobTests {

    /// Steps the body and hands back each step's bob, and whether a foot came down on it.
    private func samples(_ c: inout CharacterController, seconds: Float, _ input: MovementInput,
                         isJumpHeld jump: Bool = false, isCrouching crouching: Bool = false,
                         in world: CharacterController.Surroundings = flat) -> [(bob: SIMD2<Float>, footfall: Bool)] {
        var out: [(SIMD2<Float>, Bool)] = []
        for _ in 0..<Int((seconds / step).rounded()) {
            c.step(yaw: 0, input: input, isJumpHeld: jump, isCrouching: crouching, deltaTime: step, in: world)
            out.append((c.headBob, c.events.contains { if case .stride = $0 { true } else { false } }))
        }
        return out
    }

    private func span(_ values: [Float]) -> Float { (values.max() ?? 0) - (values.min() ?? 0) }

    private func settled(_ input: MovementInput, isCrouching crouching: Bool = false) -> [(bob: SIMD2<Float>, footfall: Bool)] {
        var c = CharacterController(feet: .zero)
        _ = samples(&c, seconds: 1.5, input, isCrouching: crouching)
        return samples(&c, seconds: 2, input, isCrouching: crouching)
    }

    @Test("Standing still does not bob")
    func stillIsStill() {
        var c = CharacterController(feet: .zero)
        let bobs = samples(&c, seconds: 1, MovementInput())
        #expect(bobs.allSatisfy { $0.bob == .zero })
    }

    @Test("A walk bobs by the tuned amounts, up and down and side to side")
    func walkAmplitude() {
        let t = CharacterController.Tuning()
        let bobs = settled(MovementInput(forward: 1))
        let rise = span(bobs.map(\.bob.y)), sway = span(bobs.map(\.bob.x))
        #expect(abs(rise - 2 * t.bobRise) < 0.1 * 2 * t.bobRise, "rise \(rise)")
        #expect(abs(sway - 2 * t.bobSway) < 0.1 * 2 * t.bobSway, "sway \(sway)")
    }

    /// **The head is lowest as the foot lands** — which is what ties the bob to the footsteps a
    /// player hears. A bob out of phase with them reads as the camera wobbling on its own.
    @Test("The head is at its lowest as each foot comes down")
    func lowestAtFootfall() {
        let t = CharacterController.Tuning()
        let footfalls = settled(MovementInput(forward: 1)).filter(\.footfall)
        #expect(footfalls.count >= 3)
        for f in footfalls { #expect(f.bob.y < -0.9 * t.bobRise, "a foot landed with the head at \(f.bob.y)") }
    }

    /// Two dips for every sway: the sway leans one way for a step and the other way for the next.
    @Test("The sway changes side with every step: a figure-eight, not a loop")
    func swayAlternates() {
        let bobs = settled(MovementInput(forward: 1))
        var sides: [Float] = []
        var widest: Float = 0
        for sample in bobs {
            if sample.footfall {
                if widest != 0 { sides.append(widest) }
                widest = 0
            } else if abs(sample.bob.x) > abs(widest) {
                widest = sample.bob.x
            }
        }
        #expect(sides.count >= 3)
        for (a, b) in zip(sides, sides.dropFirst()) { #expect(a * b < 0, "two steps leaned the same way: \(sides)") }
    }

    @Test("A sprint bobs more than a walk, and a crouch less")
    func gaitScales() {
        let t = CharacterController.Tuning()
        let walk = span(settled(MovementInput(forward: 1)).map(\.bob.y))
        let sprint = span(settled(MovementInput(forward: 1, isSprinting: true)).map(\.bob.y))
        let crouch = span(settled(MovementInput(forward: 1), isCrouching: true).map(\.bob.y))
        #expect(abs(sprint / walk - t.bobSprintScale) < 0.1, "sprint \(sprint) against walk \(walk)")
        #expect(abs(crouch / walk - t.bobCrouchScale) < 0.1, "crouch \(crouch) against walk \(walk)")
    }

    /// **Eased out, not switched off** — stopping mid-stride must not park the view off centre and
    /// then snap it back.
    @Test("Stopping lets the bob die away smoothly")
    func stopsSmoothly() {
        var c = CharacterController(feet: .zero)
        _ = samples(&c, seconds: 2, MovementInput(forward: 1))
        var last = c.headBob, biggestJump: Float = 0
        for sample in samples(&c, seconds: 0.8, MovementInput()) {
            biggestJump = max(biggestJump, simd_length(sample.bob - last))
            last = sample.bob
        }
        #expect(simd_length(c.headBob) < 0.001, "still bobbing \(c.headBob) after stopping")
        #expect(biggestJump < 0.002, "the bob jumped \(biggestJump) m in one step")
    }

    @Test("Pushing into a wall does not bob")
    func wallDoesNotBob() {
        var c = CharacterController(feet: .zero)
        let wall = BoundingBox(minimum: SIMD3(-3, 0, -2), maximum: SIMD3(3, 3, -1))
        let world = CharacterController.Surroundings(solids: boxes([wall]))
        _ = samples(&c, seconds: 1.5, MovementInput(forward: 1), in: world)
        let bobs = samples(&c, seconds: 1, MovementInput(forward: 1), in: world)
        #expect(bobs.allSatisfy { simd_length($0.bob) < 0.0005 })
    }

    /// Neither the air nor a slide has footfalls, so neither has a bob.
    @Test("No bob in the air or in a slide")
    func airAndSlide() {
        let t = CharacterController.Tuning()
        var c = CharacterController(feet: .zero)
        _ = samples(&c, seconds: 1.5, MovementInput(forward: 1))
        let flight = samples(&c, seconds: 0.5, MovementInput(forward: 1), isJumpHeld: true)
        #expect(simd_length(flight.last!.bob) < 0.1 * t.bobRise, "bobbing in mid-air: \(flight.last!.bob)")

        var s = CharacterController(feet: .zero)
        _ = samples(&s, seconds: 1.5, MovementInput(forward: 1, isSprinting: true))
        let slide = samples(&s, seconds: 0.6, MovementInput(forward: 1, isSprinting: true), isCrouching: true)
        #expect(s.isSliding)
        #expect(simd_length(slide.last!.bob) < 0.1 * t.bobRise, "bobbing through a slide: \(slide.last!.bob)")
    }

    /// **The case that needed ``CharacterController/headBob``'s catch-up.** A step up jumps the stride
    /// phase to a footfall, and a bob read straight off the phase jumped with it — every tread.
    @Test("Climbing stairs does not jolt the bob")
    func stairsDoNotJolt() {
        var treads: [BoundingBox] = []
        for i in 0..<4 {
            let near = -Float(i + 1), far = -Float(i + 2), top = 0.3 * Float(i + 1)
            treads.append(BoundingBox(minimum: SIMD3<Float>(-3, 0, far), maximum: SIMD3<Float>(3, top, near)))
        }
        let landing = BoundingBox(minimum: SIMD3(-3, 0, -12), maximum: SIMD3(3, 1.2, -5))
        let world = CharacterController.Surroundings(solids: boxes(treads + [landing]))
        var c = CharacterController(feet: SIMD3(0, 0, 6))
        _ = samples(&c, seconds: 1.2, MovementInput(forward: 1), in: flat)   // up to speed on the flat
        var last = c.headBob, biggestJump: Float = 0
        for sample in samples(&c, seconds: 1.5, MovementInput(forward: 1), in: world) {
            biggestJump = max(biggestJump, simd_length(sample.bob - last))
            last = sample.bob
        }
        #expect(abs(c.feet.y - 1.2) < 1e-4, "did not climb the stairs")
        #expect(biggestJump < 0.004, "the bob jumped \(biggestJump) m in one step on the stairs")
    }
}

// MARK: - Room to stand

@Suite("Character controller — room to stand")
struct CharacterHeadroomTests {

    /// A beam across the path, its underside at 1.5 m: a crouched body (1.2 m) goes under it, a
    /// standing one (1.85 m) does not.
    private let world = CharacterController.Surroundings(solids: boxes([
        BoundingBox(minimum: SIMD3(-3, 1.5, -4.5), maximum: SIMD3(3, 2.5, -3.5)),
    ]))

    /// Crouches, and walks until the feet are under the middle of the beam.
    private func underTheBeam() -> CharacterController {
        var c = CharacterController(feet: .zero)
        run(&c, seconds: 1, isCrouching: true, in: world)
        while c.feet.z > -4 {
            c.step(yaw: 0, input: MovementInput(forward: 1), isCrouching: true, deltaTime: step, in: world)
        }
        return c
    }

    /// **The bug**: the body rose into the beam, 35 cm of head inside the stone, and every move after
    /// that was refused because the body already overlapped the beam. Stuck until crouching again.
    @Test("Letting go of crouch under a beam keeps the body down")
    func staysDownUnderABeam() {
        var c = underTheBeam()
        run(&c, seconds: 1, isCrouching: false, in: world)
        #expect(c.isCrouchForced)
        #expect(abs(c.eye.y - c.tuning.crouchedEyeHeight) < 1e-4, "stood to \(c.eye.y) under a 1.5 m beam")
        #expect(c.bounds.maximum.y < 1.5, "the head is inside the beam: \(c.bounds.maximum.y)")
    }

    @Test("Walking out from under it stands up, at once and on its own")
    func standsWhenClear() {
        var c = underTheBeam()
        run(&c, seconds: 0.5, isCrouching: false, in: world)
        var stoodAt: Float?
        for _ in 0..<240 {
            c.step(yaw: 0, input: MovementInput(forward: 1), isCrouching: false, deltaTime: step, in: world)
            if stoodAt == nil && c.eye.y > c.tuning.crouchedEyeHeight + 0.01 { stoodAt = c.feet.z }
        }
        #expect(!c.isCrouchForced)
        #expect(abs(c.eye.y - c.tuning.eyeHeight) < 1e-4, "never stood: \(c.eye.y)")
        // The beam ends at z = −4.5 and the body is 0.3 either side of its feet.
        #expect(stoodAt.map { $0 < -4.8 && $0 > -5.0 } == true, "began to stand at z \(stoodAt ?? .nan)")
    }

    /// Held down is crouched in every respect: a crouched walk's speed, and no sprint.
    @Test("Held down under a beam, the walk is a crouched walk and cannot sprint")
    func heldDownIsCrouched() {
        var c = underTheBeam()
        run(&c, seconds: 0.5, isCrouching: false, in: world)
        let before = c.feet
        c.step(yaw: .pi / 2, input: MovementInput(forward: 1, isSprinting: true), isCrouching: false, deltaTime: step, in: world)
        let speed = simd_distance(ground(before), ground(c.feet)) / step
        let crouchedSpeed = c.tuning.walkSpeed * c.tuning.crouchedSpeedFraction
        #expect(abs(speed - crouchedSpeed) < 0.01, "moved at \(speed) m/s under the beam, sprint held")
    }

    /// **Found by the sample**: the walk stops a body against a face to within the collision
    /// tolerance, and the first headroom check counted that touch as the beam being overhead — a
    /// player who only walked up to a low beam was pushed into a crouch.
    @Test("Walking up to a low beam standing stops at it, still standing")
    func walkingUpToABeamStaysStanding() {
        var c = CharacterController(feet: SIMD3(0, 0, 6))
        run(&c, seconds: 2, MovementInput(forward: 1), in: world)
        #expect(abs(c.feet.z + 3.2) < 0.01, "should stop at the beam's face: \(c.feet.z)")
        #expect(!c.isCrouchForced)
        #expect(abs(c.eye.y - c.tuning.eyeHeight) < 1e-4, "walked into a crouch: eye \(c.eye.y)")
    }

    @Test("In the open, letting go of crouch stands as it always did")
    func openAirUnchanged() {
        var c = CharacterController(feet: .zero)
        run(&c, seconds: 1, isCrouching: true, in: world)
        run(&c, seconds: 1, isCrouching: false, in: world)
        #expect(!c.isCrouchForced && abs(c.eye.y - c.tuning.eyeHeight) < 1e-4)
    }
}

// MARK: - Something that moves

@Suite("Character controller — standing on something that moves")
struct CharacterPlatformTests {

    /// A 3 m square slab, its top at `top`, centred at `centre` on the ground plane.
    private func slab(top: Float, center: SIMD2<Float> = .zero) -> BoundingBox {
        BoundingBox(minimum: SIMD3(center.x - 1.5, top - 0.5, center.y - 1.5),
                    maximum: SIMD3(center.x + 1.5, top, center.y + 1.5))
    }

    /// Steps a body on a slab that moves by `velocity` each second, with `others` still around it.
    /// Returns the slab's final top and centre.
    @discardableResult
    private func ride(_ c: inout CharacterController, from top: Float, center: SIMD2<Float> = .zero,
                      velocity: SIMD3<Float>, seconds: Float, _ input: MovementInput = MovementInput(),
                      others: [BoundingBox] = []) -> (top: Float, center: SIMD2<Float>) {
        var top = top, center = center
        for _ in 0..<Int((seconds / step).rounded()) {
            let delta = velocity * step
            top += delta.y
            center += SIMD2(delta.x, delta.z)
            var world = CharacterController.Surroundings(solids: boxes([slab(top: top, center: center)] + others))
            world.solids[0].motion = delta
            c.step(yaw: 0, input: input, deltaTime: step, in: world)
        }
        return (top, center)
    }

    private func standing(on top: Float) -> CharacterController {
        var c = CharacterController(feet: SIMD3(0, top, 0))
        let still = CharacterController.Surroundings(solids: boxes([slab(top: top)]))
        for _ in 0..<60 { c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: still) }
        return c
    }

    @Test("A lift going up carries the body up with it, exactly")
    func carriedUp() {
        var c = standing(on: 0.3)
        let end = ride(&c, from: 0.3, velocity: SIMD3(0, 1.2, 0), seconds: 1)
        #expect(abs(c.feet.y - end.top) < 1e-4, "feet at \(c.feet.y), lift top at \(end.top)")
        #expect(c.isGrounded && c.groundSolid == 0)
        #expect(abs(c.eye.y - c.feet.y - c.tuning.eyeHeight) < 1e-4, "the eye should ride rigidly, not ease after it")
    }

    /// Faster than gravity would drop you: without the carry the body would fall behind and land.
    @Test("A lift going down keeps the body on it — no fall, no landing")
    func carriedDown() {
        var c = standing(on: 12)
        var landings = 0
        var top: Float = 12
        for _ in 0..<120 {
            let delta = SIMD3<Float>(0, -9, 0) * step
            top += delta.y
            var world = CharacterController.Surroundings(solids: boxes([slab(top: top)]))
            world.solids[0].motion = delta
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: world)
            landings += c.events.filter { if case .landed = $0 { true } else { false } }.count
            #expect(c.isGrounded)
        }
        #expect(abs(c.feet.y - top) < 1e-4 && landings == 0, "feet \(c.feet.y), top \(top), \(landings) landings")
    }

    @Test("Riding without walking makes no footsteps and no bob")
    func ridingIsNotWalking() {
        var c = standing(on: 0.3)
        var strides = 0
        var top: Float = 0.3, center = SIMD2<Float>(0, 0)
        for _ in 0..<240 {
            let delta = SIMD3<Float>(2, 0.5, 0) * step
            top += delta.y
            center += SIMD2(delta.x, delta.z)
            var world = CharacterController.Surroundings(solids: boxes([slab(top: top, center: center)]))
            world.solids[0].motion = delta
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: world)
            strides += c.events.filter { if case .stride = $0 { true } else { false } }.count
        }
        #expect(strides == 0 && c.headBob == .zero, "\(strides) footsteps riding a platform standing still")
        #expect(abs(c.feet.x - center.x) < 1e-3, "carried across with it")
    }

    @Test("Walking on a moving platform is walking relative to it")
    func walkingRelative() {
        var c = standing(on: 0.3)
        // The platform slides +x at 1 m/s; the body walks −z at 6 m/s for a quarter second.
        let end = ride(&c, from: 0.3, velocity: SIMD3(1, 0, 0), seconds: 0.25, MovementInput(forward: 1))
        #expect(abs(c.feet.x - end.center.x) < 1e-3, "kept the platform's sideways motion")
        #expect(abs(c.feet.z + 1.5) < 0.01, "walked its own 1.5 m on top of it: z \(c.feet.z)")
    }

    /// **The carry goes through collision**: a platform sliding under a wall does not take the body
    /// through it. The body stays at the wall until the platform leaves it behind.
    @Test("A platform does not carry the body through a wall")
    func notThroughWalls() {
        var c = standing(on: 0.3)
        let wall = BoundingBox(minimum: SIMD3(1, 0.3, -3), maximum: SIMD3(1.2, 3, 3))   // stands on the slab
        ride(&c, from: 0.3, velocity: SIMD3(2, 0, 0), seconds: 0.5, others: [wall])
        #expect(c.feet.x <= 1 - c.tuning.radius + 1e-3, "carried into the wall: x \(c.feet.x)")
        #expect(c.carried.x < 1e-6, "the carry should read as stopped at the wall: \(c.carried)")
    }

    @Test("Off the platform, nothing carries")
    func offIsOff() {
        var c = CharacterController(feet: SIMD3(5, 0, 0))
        var world = CharacterController.Surroundings(solids: boxes([slab(top: 1)]))
        world.solids[0].motion = SIMD3(0, 0.5, 0)
        for _ in 0..<30 { c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: world) }
        #expect(c.feet == SIMD3(5, 0, 0) && c.carried == .zero)
    }
}

// MARK: - Something that turns

@Suite("Character controller — standing on something that turns")
struct CharacterTurntableTests {

    /// A square table 4 m across, top at 0.2 m, its centre at `centre`. The box stays axis-aligned —
    /// as a turned solid's world bounds do — which is all the controller ever sees of it.
    private func table(at center: SIMD2<Float>) -> BoundingBox {
        BoundingBox(minimum: SIMD3(center.x - 2, 0, center.y - 2), maximum: SIMD3(center.x + 2, 0.2, center.y + 2))
    }

    /// Stands a body on the table at `offset` from its centre, then turns the table at `rate`
    /// radians a second for `seconds`, the centre sliding by `slide` a second. Returns the body, the
    /// centre where it ended, and the total turn reported.
    private func ride(offset: SIMD2<Float>, rate: Float, seconds: Float, slide: SIMD2<Float> = .zero,
                      _ input: MovementInput = MovementInput()) -> (CharacterController, SIMD2<Float>, Float, Int) {
        var center = SIMD2<Float>(1, -3)
        var c = CharacterController(feet: SIMD3(center.x + offset.x, 0.2, center.y + offset.y))
        let still = CharacterController.Surroundings(solids: boxes([table(at: center)]))
        for _ in 0..<30 { c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: still) }
        var total: Float = 0, strides = 0
        for _ in 0..<Int((seconds / step).rounded()) {
            let moved = slide * step
            center += moved
            var world = CharacterController.Surroundings(solids: boxes([table(at: center)]))
            world.solids[0].motion = SIMD3(moved.x, 0, moved.y)
            world.solids[0].turn = .init(about: center, by: rate * step)
            c.step(yaw: 0, input: input, deltaTime: step, in: world)
            total += c.turned
            strides += c.events.filter { if case .stride = $0 { true } else { false } }.count
        }
        return (c, center, total, strides)
    }

    @Test("A quarter turn carries the feet a quarter turn round the centre, at the same radius")
    func quarterTurn() {
        let (c, center, total, strides) = ride(offset: SIMD2(1.2, 0), rate: .pi / 2, seconds: 1)
        let now = SIMD2(c.feet.x, c.feet.z) - center
        let expected = Level.turned(SIMD2(1.2, 0), by: .pi / 2)
        #expect(simd_distance(now, expected) < 1e-3, "feet at \(now) from the centre, expected \(expected)")
        #expect(abs(simd_length(now) - 1.2) < 1e-3, "the radius changed: \(simd_length(now))")
        #expect(abs(total - .pi / 2) < 1e-4, "turned \(total) radians, the table turned π/2")
        #expect(strides == 0, "\(strides) footsteps standing still on a turning table")
    }

    @Test("At the centre the feet stay put, and the turn is still reported")
    func atTheCenter() {
        let (c, center, total, _) = ride(offset: .zero, rate: 1, seconds: 0.5)
        #expect(simd_distance(SIMD2(c.feet.x, c.feet.z), center) < 1e-4)
        #expect(abs(total - 0.5) < 1e-4)
    }

    /// A deck that sails and swings at once: the body keeps its place on it.
    @Test("A table that slides and turns at once keeps the body where it was on it")
    func slideAndTurn() {
        let (c, center, total, _) = ride(offset: SIMD2(0, 1.5), rate: 0.6, seconds: 1, slide: SIMD2(0.8, -0.4))
        let now = SIMD2(c.feet.x, c.feet.z) - center
        // **Against the turn the table made, not the one reported** — measured against the reported
        // turn, this passed with the turning carry switched off, because both were zero.
        let expected = Level.turned(SIMD2(0, 1.5), by: 0.6)
        #expect(abs(total - 0.6) < 1e-4)
        #expect(simd_distance(now, expected) < 2e-3, "drifted on the table: \(now) against \(expected)")
    }

    @Test("Off the table, nothing turns")
    func offTheTable() {
        var c = CharacterController(feet: SIMD3(10, 0, 10))
        var world = CharacterController.Surroundings(solids: boxes([table(at: .zero)]))
        world.solids[0].turn = .init(about: .zero, by: 0.1)
        for _ in 0..<30 { c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: world) }
        #expect(c.feet == SIMD3(10, 0, 10) && c.turned == 0)
    }
}

// MARK: - Leaving something that moves

@Suite("Character controller — leaving something that moves")
struct CharacterLeavingPlatformTests {

    private func slab(top: Float, center: SIMD2<Float> = .zero, half: Float = 1.5) -> BoundingBox {
        BoundingBox(minimum: SIMD3(center.x - half, top - 0.5, center.y - half),
                    maximum: SIMD3(center.x + half, top, center.y + half))
    }

    /// The highest the feet get above where they left, jumping from a slab moving at `velocity`.
    private func jumpApex(from velocity: SIMD3<Float>) -> (apex: Float, landedX: Float) {
        var top: Float = 1, center = SIMD2<Float>(0, 0)
        var c = CharacterController(feet: SIMD3(0, top, 0))
        func world(_ delta: SIMD3<Float>) -> CharacterController.Surroundings {
            var w = CharacterController.Surroundings(solids: boxes([slab(top: top, center: center, half: 20)]))
            w.solids[0].motion = delta
            return w
        }
        // Ride a moment, so the ground's speed is known, then jump and keep riding it underneath.
        for _ in 0..<30 {
            let d = velocity * step; top += d.y; center += SIMD2(d.x, d.z)
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: world(d))
        }
        let takeoff = c.feet.y
        var apex: Float = 0
        for i in 0..<120 {
            let d = velocity * step; top += d.y; center += SIMD2(d.x, d.z)
            c.step(yaw: 0, input: MovementInput(), isJumpHeld: i < 2, deltaTime: step, in: world(d))
            if !c.isGrounded { apex = max(apex, c.feet.y - takeoff) }
        }
        return (apex, c.feet.x)
    }

    /// **The point of it.** From a lift rising at 1.2 m/s the jump leaves at 6.3 + 1.2, and rises
    /// (7.5² − 6.3²) / 2g higher than from still ground — 0.414 m at this gravity.
    @Test("A jump from a rising lift goes higher, by what its speed adds")
    func jumpFromRisingLift() {
        let still = jumpApex(from: .zero).apex
        let rising = jumpApex(from: SIMD3(0, 1.2, 0)).apex
        let g = CharacterController.Tuning().gravity, j = CharacterController.Tuning().jumpSpeed
        let expected = ((j + 1.2) * (j + 1.2) - j * j) / (2 * g)
        #expect(abs((rising - still) - expected) < 0.02, "rose \(rising - still) m higher; the speeds say \(expected)")
    }

    /// Jumping on a train: you land where you jumped from on the train, not behind it.
    @Test("A jump from a platform sliding sideways keeps going with it through the air")
    func jumpKeepsSideways() {
        let (_, x) = jumpApex(from: SIMD3(2, 0, 0))
        // One second at 2 m/s: the platform went 2 m, and so did the body, air and all.
        let expected: Float = 2 * (30 + 120) * step
        #expect(abs(x - expected) < 0.05, "landed at x \(x), the platform took it to \(expected)")
    }

    @Test("Walking off the edge of a moving platform falls away at its speed")
    func stepOffKeepsSpeed() {
        var center = SIMD2<Float>(0, 0)
        var c = CharacterController(feet: SIMD3(1.2, 1, 0))
        var airborneX: [Float] = []
        for _ in 0..<120 {
            let d = SIMD3<Float>(0, 0, -1.5) * step
            center += SIMD2(d.x, d.z)
            var w = CharacterController.Surroundings(solids: boxes([slab(top: 1, center: center)]))
            w.solids[0].motion = d
            c.step(yaw: -.pi / 2, input: MovementInput(forward: 0.3), deltaTime: step, in: w)   // walk off +x
            if !c.isGrounded { airborneX.append(c.feet.z) }
        }
        #expect(airborneX.count > 2, "never left the platform")
        let drift = (airborneX.last! - airborneX.first!) / (Float(airborneX.count - 1) * step)
        #expect(abs(drift + 1.5) < 0.05, "fell with a drift of \(drift) m/s along the platform's way, it moved at −1.5")
    }

    /// A turning table flings you along its rim, not round it: the kept speed is ω·r, square to the
    /// radius where the feet left.
    @Test("A jump from a turning table leaves along the tangent, at the rim's speed")
    func jumpFromTurntable() {
        let rate: Float = .pi / 2, center = SIMD2<Float>(1, -3)
        let table = BoundingBox(minimum: SIMD3(center.x - 2, 0, center.y - 2), maximum: SIMD3(center.x + 2, 0.2, center.y + 2))
        var c = CharacterController(feet: SIMD3(center.x + 1.2, 0.2, center.y))
        var world = CharacterController.Surroundings(solids: boxes([table]))
        world.solids[0].turn = .init(about: center, by: rate * step)
        for _ in 0..<60 { c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: world) }
        let radius = SIMD2(c.feet.x, c.feet.z) - center
        c.step(yaw: 0, input: MovementInput(), isJumpHeld: true, deltaTime: step, in: world)
        #expect(!c.isGrounded, "did not leave the table")
        let speed = simd_length(c.airVelocity)
        #expect(abs(speed - rate * 1.2) < 0.01, "left at \(speed) m/s, the rim moves at \(rate * 1.2)")
        #expect(abs(simd_dot(c.airVelocity, radius)) / (speed * simd_length(radius)) < 0.02,
                "left at an angle to the tangent: \(c.airVelocity) against radius \(radius)")
    }

    @Test("Landing on still ground stops the kept speed")
    func landingStops() {
        var c = CharacterController(feet: SIMD3(0, 1, 0))
        var w = CharacterController.Surroundings(solids: boxes([slab(top: 1)]))
        w.solids[0].motion = SIMD3(2 * step, 0, 0)
        for i in 0..<10 { c.step(yaw: 0, input: MovementInput(), isJumpHeld: i == 9, deltaTime: step, in: w) }
        let still = CharacterController.Surroundings(solids: boxes([slab(top: 1, half: 30)]))
        for _ in 0..<120 { c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: still) }
        let x = c.feet.x
        for _ in 0..<60 { c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: still) }
        #expect(c.isGrounded && c.airVelocity == .zero && abs(c.feet.x - x) < 1e-5, "still drifting after landing")
    }
}

// MARK: - Something set down at an angle

@Suite("Character controller — solids turned about the vertical")
struct CharacterTurnedSolidTests {

    private typealias Footprint = CharacterController.Surroundings.Footprint
    private let root2 = Float(2).squareRoot()

    /// A 1.5 m crate turned 45° at the origin: its box, 2.12 m across, and its real plan.
    private let half: Float = 0.75
    private var crate: (box: BoundingBox, plan: Footprint) {
        let a = half * root2
        return (BoundingBox(minimum: SIMD3(-a, 0, -a), maximum: SIMD3(a, 1.5, a)),
                Footprint(center: .zero, halfSize: SIMD2(half, half), yaw: .pi / 4))
    }

    private func world(_ box: BoundingBox, _ plan: Footprint?) -> CharacterController.Surroundings {
        var w = CharacterController.Surroundings(solids: boxes([box]))
        w.solids[0].footprint = plan
        return w
    }

    /// Walks from `start` at `yaw` for `seconds`, returning where the feet ended, where they were
    /// when something first held them up, and the deepest the body's square got into the crate's
    /// diamond — measured here, independently of the controller.
    private func walk(from start: SIMD2<Float>, yaw: Float, seconds: Float, in w: CharacterController.Surroundings)
        -> (feet: SIMD2<Float>, firstHeld: SIMD2<Float>?, deepest: Float) {
        var c = CharacterController(feet: SIMD3(start.x, 0, start.y))
        var deepest: Float = -.greatestFiniteMagnitude
        var firstHeld: SIMD2<Float>?
        let free = CharacterController.Tuning().walkSpeed * step
        for i in 0..<Int(seconds / step) {
            let before = SIMD2(c.feet.x, c.feet.z)
            c.step(yaw: yaw, input: MovementInput(forward: 1), deltaTime: step, in: w)
            let now = SIMD2(c.feet.x, c.feet.z)
            if i > 10, firstHeld == nil, simd_distance(before, now) < 0.9 * free { firstHeld = now }
            // The square |x|,|z| < r against the diamond |x|+|z| < h√2: apart if any of the four axes
            // shows a gap. Depth is the least overlap over them.
            let p = SIMD2(c.feet.x, c.feet.z), r = CharacterController.Tuning().radius
            let a = half * root2
            let onX = r + a - abs(p.x), onZ = r + a - abs(p.y)
            let sum: Float = abs(p.x + p.y) / root2, difference: Float = abs(p.x - p.y) / root2
            let onU: Float = half + r * root2 - sum
            let onV: Float = half + r * root2 - difference
            deepest = max(deepest, min(onX, onZ, onU, onV))
        }
        return (SIMD2(c.feet.x, c.feet.z), firstHeld, deepest)
    }

    /// **The point of it.** Walking square at a face of the crate, the body's corner meets the face:
    /// it stops h + r√2 from the centre — within the collision's own band, between a millimetre in
    /// (still touching) and two out (the clearance a blocked move keeps). With the box alone the body
    /// was held up 0.75 m short of the face, at the box's corner, and slid off along the box.
    @Test("Walking square at a turned crate's face stops at the face, not its box")
    func stopsAtTheFace() {
        let (box, plan) = crate
        let r = CharacterController.Tuning().radius
        // Out along the face's normal (−sin, −cos of 45°) and walking back along it.
        let normal = -SIMD2<Float>(sin(Float.pi / 4), cos(Float.pi / 4))
        let yaw: Float = -3 * .pi / 4
        let (feet, _, deepest) = walk(from: normal * 3, yaw: yaw, seconds: 2, in: world(box, plan))
        let touching = half + r * root2
        let out = simd_dot(feet, normal)
        #expect(out >= touching - 0.001 && out <= touching + 0.002, "stopped \(out) m out, touching is \(touching)")
        #expect(abs(simd_dot(feet, SIMD2(normal.y, -normal.x))) < 1e-3, "slid \(feet) along the face walking square at it")
        #expect(deepest <= 1e-3, "went \(deepest) m into the crate")

        let held = walk(from: normal * 3, yaw: yaw, seconds: 2, in: world(box, nil)).firstHeld
        let short = held.map { simd_dot($0, normal) - touching } ?? 0
        #expect(short > 0.7, "with the box alone it was held up \(short) m short of the face")
    }

    /// Against a face at an angle both axes run into it, so the axis-at-a-time move alone would stick
    /// there. It slides up the face instead and round the corner, clearing it by the body's half-width.
    @Test("Walking into a turned face at an angle slides along it and round the corner")
    func slidesRound() {
        let (box, plan) = crate
        let r = CharacterController.Tuning().radius
        let (feet, _, deepest) = walk(from: SIMD2(-4, 0.4), yaw: -.pi / 2, seconds: 3, in: world(box, plan))
        #expect(feet.x > 3, "stuck at x \(feet.x)")
        // Clear of the corner by the body's half-width — and by up to one step's slide more, since the
        // last slide spends the rest of its step along the face even as the face ends.
        let clear = half * root2 + r
        let oneSlide = CharacterController.Tuning().walkSpeed * step / 2
        #expect(feet.y >= clear && feet.y <= clear + oneSlide, "went past at z \(feet.y), clearing the corner is \(clear)")
        #expect(deepest <= 1e-3, "went \(deepest) m into the crate")

        let boxed = walk(from: SIMD2(-4, 0.4), yaw: -.pi / 2, seconds: 3, in: world(box, nil)).feet
        #expect(abs(boxed.x - (-clear - 0.002)) < 1e-3, "with the box alone it stopped at x \(boxed.x)")
    }

    @Test("Past a turned slab's corner there is nothing to stand on")
    func noAirPastTheCorner() {
        // A 2 m slab 0.3 high at 45°: its box reaches 1.41 m along each axis, its corners only along
        // the diagonals. At (1.1, 1.1) the body is inside the box and clear of the slab.
        let a = root2
        let slab = BoundingBox(minimum: SIMD3(-a, 0, -a), maximum: SIMD3(a, 0.3, a))
        let plan = Footprint(center: .zero, halfSize: SIMD2(1, 1), yaw: .pi / 4)
        func drop(_ w: CharacterController.Surroundings) -> Float {
            var c = CharacterController(feet: SIMD3(1.1, 1, 1.1))
            for _ in 0..<120 { c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: w) }
            return c.feet.y
        }
        #expect(drop(world(slab, plan)) == 0, "stood on air past the corner")
        #expect(abs(drop(world(slab, nil)) - 0.3) < 1e-4, "the box alone should have held it up — the test is not testing anything")
        // And on the slab itself, it still stands.
        var c = CharacterController(feet: SIMD3(0.5, 1, 0))
        for _ in 0..<120 { c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: world(slab, plan)) }
        #expect(abs(c.feet.y - 0.3) < 1e-4)
    }

    @Test("Headroom under a turned beam is the beam's, not its box's")
    func headroomUnderATurnedBeam() {
        // A 2 m beam at 45°, its underside at 1.5 m: low enough to hold a standing body down.
        let a = root2
        let beam = BoundingBox(minimum: SIMD3(-a, 1.5, -a), maximum: SIMD3(a, 1.8, a))
        let plan = Footprint(center: .zero, halfSize: SIMD2(1, 1), yaw: .pi / 4)
        func heldDown(at x: Float, _ z: Float, _ w: CharacterController.Surroundings) -> Bool {
            var c = CharacterController(feet: SIMD3(x, 0, z))
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: w)
            return c.isCrouchForced
        }
        #expect(!heldDown(at: 1.1, 1.1, world(beam, plan)), "held down by the air past the beam's corner")
        #expect(heldDown(at: 1.1, 1.1, world(beam, nil)), "the box alone should have — the test is not testing anything")
        #expect(heldDown(at: 0.5, 0, world(beam, plan)), "not held down under the beam itself")
    }

    @Test("A footprint that is not turned collides exactly as the box does")
    func unturnedMatchesTheBox() {
        let box = BoundingBox(minimum: SIMD3(1, 0, -1), maximum: SIMD3(3, 1.5, 2))
        let plan = Footprint(center: SIMD2(2, 0.5), halfSize: SIMD2(1, 1.5), yaw: 0)
        for start in [SIMD2<Float>(-2, 0), SIMD2(-2, 1.9), SIMD2(-2, 2.25)] {
            let a = walk(from: start, yaw: -.pi / 2 + 0.3, seconds: 2, in: world(box, plan)).feet
            let b = walk(from: start, yaw: -.pi / 2 + 0.3, seconds: 2, in: world(box, nil)).feet
            #expect(simd_distance(a, b) < 1e-4, "from \(start): \(a) with the footprint, \(b) with the box")
        }
    }

    @Test("A volume's footprint: its centre, its size scaled, its yaw — and none for a tilted one")
    func footprintOfAVolume() {
        let local = BoundingBox(minimum: SIMD3(0, 0, -0.5), maximum: SIMD3(2, 1, 0.5))
        let placed = Volume(localBounds: local, transform: Level.transform(yaw: 0.8, scale: 1.5, at: SIMD3(6, 0, -3)))
        let f = Footprint(of: placed)
        #expect(f != nil)
        if let f {
            // The local middle (1, 0.5, 0) scaled and turned: 1.5 along (cos 0.8, −sin 0.8).
            let expected = SIMD2<Float>(6, -3) + Level.turned(SIMD2(1.5, 0), by: 0.8)
            #expect(simd_distance(f.center, expected) < 1e-5, "center \(f.center), expected \(expected)")
            #expect(simd_distance(f.halfSize, SIMD2(1.5, 0.75)) < 1e-5)
            #expect(abs(f.yaw - 0.8) < 1e-5)
            // Every corner of the plan inside the volume's world box, and touching it.
            let world = placed.worldBounds
            for sx: Float in [-1, 1] { for sz: Float in [-1, 1] {
                let corner = f.center + Level.turned(SIMD2(sx * f.halfSize.x, sz * f.halfSize.y), by: f.yaw)
                #expect(corner.x >= world.minimum.x - 1e-4 && corner.x <= world.maximum.x + 1e-4
                        && corner.y >= world.minimum.z - 1e-4 && corner.y <= world.maximum.z + 1e-4)
            } }
        }
        let tilt: Float = 0.3
        let tilted = matrix_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cos(tilt), sin(tilt), 0),
                                             SIMD4(0, -sin(tilt), cos(tilt), 0), SIMD4(0, 0, 0, 1)))
        #expect(Footprint(of: Volume(localBounds: local, transform: tilted)) == nil, "a tilted box has no rectangular plan")
    }
}

// MARK: - Something moving into you

@Suite("Character controller — pushed by something that moves")
struct CharacterPushedTests {

    private let r = CharacterController.Tuning().radius

    /// A 3 m slab, 1.5 m tall, its +x face at `face`.
    private func slab(face: Float, z: Float = 0) -> BoundingBox {
        BoundingBox(minimum: SIMD3(face - 3, 0, z - 2), maximum: SIMD3(face, 1.5, z + 2))
    }

    /// **The point of it.** A slab sliding at 1 m/s into a body standing in its way: once it arrives,
    /// the body keeps ahead of its face by its half-width and the clearance, every step, going at
    /// the slab's speed. Before this, the slab ended 0.30 m into the body and the body was stuck.
    @Test("A slab sliding into a body pushes it ahead of its face, at its speed")
    func pushedAhead() {
        var face: Float = -2
        var c = CharacterController(feet: .zero)
        var gaps: [Float] = [], speeds: [Float] = []
        var footsteps = 0
        for _ in 0..<360 {
            face += step
            var w = CharacterController.Surroundings(solids: boxes([slab(face: face)]))
            w.solids[0].motion = SIMD3(step, 0, 0)
            let before = c.feet.x
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: w)
            if face > -r { gaps.append(c.feet.x - face); speeds.append((c.feet.x - before) / step) }
            footsteps += c.events.filter { if case .stride = $0 { true } else { false } }.count
            #expect(c.pinnedBy == nil)
        }
        #expect(!gaps.isEmpty)
        let touching = r + 0.002
        #expect(gaps.allSatisfy { $0 >= r - 0.001 && $0 <= touching + 1e-4 },
                "the body was \(gaps.min()!)…\(gaps.max()!) m ahead of the face, touching is \(touching)")
        let steady = speeds.dropFirst(2)
        #expect(steady.allSatisfy { abs($0 - 1) < 1e-3 }, "pushed at \(steady.min()!)…\(steady.max()!) m/s, the slab goes 1")
        #expect(c.feet.x > 1)
        // Pushing is not walking.
        #expect(footsteps == 0, "\(footsteps) footsteps being pushed")
    }

    @Test("Pushed is not stuck: the body walks away from the slab afterwards")
    func walksAway() {
        var face: Float = -2
        var c = CharacterController(feet: .zero)
        for _ in 0..<240 {
            face += step
            var w = CharacterController.Surroundings(solids: boxes([slab(face: face)]))
            w.solids[0].motion = SIMD3(step, 0, 0)
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: w)
        }
        let at = c.feet.x
        let still = CharacterController.Surroundings(solids: boxes([slab(face: face)]))
        for _ in 0..<60 { c.step(yaw: -.pi / 2, input: MovementInput(forward: 1), deltaTime: step, in: still) }
        // Half a second at a walk: the whole 3 m, nothing held back by the slab it was pushed by.
        let walk = CharacterController.Tuning().walkSpeed * 0.5
        #expect(abs((c.feet.x - at) - walk) < 1e-3, "walked \(c.feet.x - at) m away in half a second, a walk is \(walk)")
    }

    @Test("Pushed against a wall, the body stops at the wall and says what pins it")
    func pinned() {
        var face: Float = -2
        var c = CharacterController(feet: .zero)
        let wall = BoundingBox(minimum: SIMD3(1, 0, -3), maximum: SIMD3(2, 3, 3))
        var firstPinned: Int?
        for i in 0..<360 {
            face += step
            var w = CharacterController.Surroundings(solids: boxes([slab(face: face), wall]))
            w.solids[0].motion = SIMD3(step, 0, 0)
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: w)
            if c.pinnedBy != nil && firstPinned == nil { firstPinned = i }
            #expect(c.feet.x + r <= 1 + 1e-4, "pushed \(c.feet.x + r - 1) m into the wall")
        }
        #expect(c.pinnedBy == 0, "pinned by \(String(describing: c.pinnedBy)), the slab is 0")
        // Pinned once the gap closed: the slab reached the wall less the body's width.
        let closes = Int(((1 - 2 * r) - (-2)) / step)
        #expect(firstPinned.map { abs($0 - closes) <= 2 } ?? false, "first pinned at step \(String(describing: firstPinned)), the gap closes at \(closes)")
    }

    /// **Found by the sample using `pinnedBy`.** A slab pins a body against a wall, a step's travel into
    /// it, and — as a door does — turns back. It is moving away now; the body must stay where the wall
    /// held it. Pushed "along the way it went, just clear of it", the body went out through the slab's
    /// far side and was carried home behind it: measured, 1.8 m through a slider in the sample.
    @Test("A slab turning back from a body it pinned leaves it there")
    func turningBackLeavesIt() {
        var face: Float = -2, speed: Float = 1
        var c = CharacterController(feet: .zero)
        let wall = BoundingBox(minimum: SIMD3(1, 0, -3), maximum: SIMD3(2, 3, 3))
        var pinnedOnce = false, pinnedAfter = 0
        for _ in 0..<480 {
            face += speed * step
            var w = CharacterController.Surroundings(solids: boxes([slab(face: face), wall]))
            w.solids[0].motion = SIMD3(speed * step, 0, 0)
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: w)
            if c.pinnedBy == 0 {
                if pinnedOnce { pinnedAfter += 1 }
                pinnedOnce = true
                // The door turns back — gently, as an eased one does from rest, so it is still into the
                // body for a few steps after. At full speed it is out of it in one, and nothing shows.
                speed = -0.1
            }
        }
        let held = 1 - r - 0.002
        #expect(pinnedOnce, "never pinned")
        #expect(abs(c.feet.x - held) < 1e-3, "the body is at \(c.feet.x), the wall held it at \(held)")
        #expect(pinnedAfter == 0, "still reported pinned \(pinnedAfter) steps after the slab turned away")
    }

    @Test("A slab sliding past, not into, leaves the body where it is")
    func slidingPast() {
        var face: Float = -2
        var c = CharacterController(feet: SIMD3(0, 0, 2 + r + 0.05))
        for _ in 0..<480 {
            face += step
            var w = CharacterController.Surroundings(solids: boxes([slab(face: face)]))
            w.solids[0].motion = SIMD3(step, 0, 0)
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: w)
        }
        #expect(abs(c.feet.x) < 1e-5 && abs(c.feet.z - (2 + r + 0.05)) < 1e-5, "moved to \(c.feet)")
    }

    /// A long arm turning about one end sweeps into the body: pushed round, never inside it.
    @Test("An arm turning into a body pushes it round, never inside it")
    func sweptByAnArm() {
        typealias Footprint = CharacterController.Surroundings.Footprint
        let rate: Float = .pi / 2, pivot = SIMD2<Float>(0, 0)
        var angle: Float = 0
        // A 4 m arm, 0.4 m wide, from the pivot out along +x; the body 2.5 m out, a little way round.
        var c = CharacterController(feet: SIMD3(Level.turned(SIMD2(2.5, 0), by: 0.6).x, 0,
                                                Level.turned(SIMD2(2.5, 0), by: 0.6).y))
        func arm(_ a: Float) -> (BoundingBox, Footprint) {
            let center = pivot + Level.turned(SIMD2(2, 0), by: a)
            let plan = Footprint(center: center, halfSize: SIMD2(2, 0.2), yaw: a)
            let reach = Level.turned(SIMD2(2, 0), by: a), side = Level.turned(SIMD2(0, 0.2), by: a)
            let ex = abs(reach.x) + abs(side.x), ez = abs(reach.y) + abs(side.y)
            return (BoundingBox(minimum: SIMD3(center.x - ex, 0, center.y - ez), maximum: SIMD3(center.x + ex, 1, center.y + ez)), plan)
        }
        var deepest: Float = -1
        for _ in 0..<120 {
            angle += rate * step
            let (box, plan) = arm(angle)
            var w = CharacterController.Surroundings(solids: boxes([box]))
            w.solids[0].footprint = plan
            w.solids[0].turn = .init(about: pivot, by: rate * step)
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: w)
            // How far the body's square is into the arm, on the arm's own axes (the body's corners).
            let local = Level.turned(SIMD2(c.feet.x, c.feet.z) - plan.center, by: -angle)
            let reachAcross = r * (abs(cos(angle)) + abs(sin(angle)))
            deepest = max(deepest, min(2 + reachAcross - abs(local.x), 0.2 + reachAcross - abs(local.y)))
        }
        #expect(deepest <= 1e-3, "the arm went \(deepest) m into the body")
        // Swept a quarter turn and more past where it stood, it is still 2.5 m out, and round with the arm.
        let now = SIMD2(c.feet.x, c.feet.z)
        #expect(abs(simd_length(now) - 2.5) < 0.2, "at radius \(simd_length(now))")
    }

    @Test("A slab low enough to step onto is stood on, not pushed against")
    func lowSlabIsSteppedOn() {
        var face: Float = -2
        var c = CharacterController(feet: .zero)
        for _ in 0..<240 {
            face += step
            var w = CharacterController.Surroundings(solids: boxes([BoundingBox(minimum: SIMD3(face - 3, 0, -2), maximum: SIMD3(face, 0.2, 2))]))
            w.solids[0].motion = SIMD3(step, 0, 0)
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: w)
        }
        #expect(abs(c.feet.y - 0.2) < 1e-4 && c.groundSolid == 0, "feet at \(c.feet.y), on \(String(describing: c.groundSolid))")
    }
}

// MARK: - Something round

@Suite("Character controller — round solids")
struct CharacterRoundSolidTests {

    private typealias Footprint = CharacterController.Surroundings.Footprint
    private let r = CharacterController.Tuning().radius
    private let root2 = Float(2).squareRoot()

    private func world(_ box: BoundingBox, _ plan: Footprint?) -> CharacterController.Surroundings {
        var w = CharacterController.Surroundings(solids: boxes([box]))
        w.solids[0].footprint = plan
        return w
    }

    /// A 4 m table 0.2 m high at the origin, its box the square round it.
    private let table = BoundingBox(minimum: SIMD3(-2, 0, -2), maximum: SIMD3(2, 0.2, 2))

    /// Walks from `start` at `yaw` until the feet rise, returning how far from the origin the body's
    /// centre was then — or nil if they never did.
    private func whereItRises(from start: SIMD2<Float>, yaw: Float, in w: CharacterController.Surroundings) -> Float? {
        var c = CharacterController(feet: SIMD3(start.x, 0, start.y))
        for _ in 0..<240 {
            c.step(yaw: yaw, input: MovementInput(forward: 1), deltaTime: step, in: w)
            if c.feet.y > 0.1 { return simd_length(SIMD2(c.feet.x, c.feet.z)) }
        }
        return nil
    }

    /// **The point of it.** Coming at a round table along a diagonal, the body's corner leads, and the
    /// feet should rise as it reaches the rim: R + r√2 from the centre, give or take one step's
    /// travel. Its square rises them 0.83 m sooner — at its own corner, 2√2 + r√2 out.
    @Test("Walking at a round table along a diagonal steps up at its rim, not its square's corner")
    func risesAtTheRim() {
        let start = SIMD2<Float>(-4, -4)
        let yaw: Float = -3 * .pi / 4                  // walking along (+x, +z)
        let oneStep = CharacterController.Tuning().walkSpeed * step
        let rim = 2 + r * root2
        let round = whereItRises(from: start, yaw: yaw, in: world(table, Footprint(center: .zero, radius: 2)))
        #expect(round.map { $0 <= rim + 1e-3 && $0 >= rim - oneStep - 1e-3 } ?? false,
                "rose at \(String(describing: round)) m out, the rim is \(rim)")
        let square = whereItRises(from: start, yaw: yaw, in: world(table, Footprint(center: .zero, halfSize: SIMD2(2, 2), yaw: 0)))
        let corner = (2 + r) * root2
        #expect(square.map { $0 <= corner + 1e-3 && $0 >= corner - oneStep - 1e-3 } ?? false,
                "its square rose it at \(String(describing: square)) m, its corner is \(corner)")
    }

    @Test("Past a round table's rim, where its square's corner is, there is nothing to stand on")
    func noAirPastTheRim() {
        // At (1.8, 1.8) the body's nearest corner is 2.12 m out: off the table, inside its square.
        func drop(_ plan: Footprint) -> Float {
            var c = CharacterController(feet: SIMD3(1.8, 1, 1.8))
            for _ in 0..<120 { c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: world(table, plan)) }
            return c.feet.y
        }
        #expect(drop(Footprint(center: .zero, radius: 2)) == 0, "stood on air past the rim")
        #expect(abs(drop(Footprint(center: .zero, halfSize: SIMD2(2, 2), yaw: 0)) - 0.2) < 1e-4,
                "its square should have held it up — the test is not testing anything")
        // Just inside the rim it stands: the corner at 1.98 m.
        var c = CharacterController(feet: SIMD3(1.1, 1, 1.1))
        for _ in 0..<120 { c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: world(table, Footprint(center: .zero, radius: 2))) }
        #expect(abs(c.feet.y - 0.2) < 1e-4)
    }

    /// A column 1 m across and 3 m tall. Face on, the body's flat face meets it: R + r from its centre.
    private let column = BoundingBox(minimum: SIMD3(-0.5, 0, -0.5), maximum: SIMD3(0.5, 3, 0.5))

    @Test("Walking square at a column stops with the body's face against it")
    func stopsAtAColumn() {
        var c = CharacterController(feet: SIMD3(-3, 0, 0))
        for _ in 0..<120 {
            c.step(yaw: -.pi / 2, input: MovementInput(forward: 1), deltaTime: step, in: world(column, Footprint(center: .zero, radius: 0.5)))
        }
        let out = -c.feet.x
        #expect(out >= 0.5 + r - 0.001 && out <= 0.5 + r + 0.002 && abs(c.feet.z) < 1e-5, "stopped at \(c.feet)")
    }

    /// **Off centre by more than the body's half-width**, its corner meets the curve and it glances
    /// off round the column, never into it — where the column's box would hold it for good. By less,
    /// the column's nearest point meets the body's flat face and it stops, as at a wall: that is a box
    /// body's nature, and the type's notes say so.
    @Test("Walking at a column off centre slides round it")
    func slidesRoundAColumn() {
        let plan = Footprint(center: .zero, radius: 0.5)
        var held = CharacterController(feet: SIMD3(-3, 0, 0.2))
        for _ in 0..<240 { held.step(yaw: -.pi / 2, input: MovementInput(forward: 1), deltaTime: step, in: world(column, plan)) }
        #expect(abs(held.feet.x + 0.5 + r) < 0.003, "0.2 m off centre, face on, it should stop at the column: \(held.feet)")
        var c = CharacterController(feet: SIMD3(-3, 0, 0.4))
        var deepest: Float = -1
        for _ in 0..<240 {
            c.step(yaw: -.pi / 2, input: MovementInput(forward: 1), deltaTime: step, in: world(column, plan))
            // The column's centre against the body's square, measured here.
            let q = abs(SIMD2(c.feet.x, c.feet.z)), out = simd_max(q - r, .zero)
            let beyond = simd_length_squared(out) > 0 ? simd_length(out) : max(q.x - r, q.y - r)
            deepest = max(deepest, 0.5 - beyond)
        }
        #expect(c.feet.x > 3, "stuck at \(c.feet)")
        #expect(deepest <= 1e-3, "went \(deepest) m into the column")
        var boxed = CharacterController(feet: SIMD3(-3, 0, 0.4))
        for _ in 0..<240 { boxed.step(yaw: -.pi / 2, input: MovementInput(forward: 1), deltaTime: step, in: world(column, nil)) }
        #expect(boxed.feet.x < -0.5, "its box should have held it — the test is not testing anything")
    }

    @Test("A round column sliding into a body pushes it, never into it")
    func pushedByAColumn() {
        var x: Float = -3
        var c = CharacterController(feet: SIMD3(0, 0, 0.3))
        var deepest: Float = -1
        for _ in 0..<360 {
            x += step
            let box = BoundingBox(minimum: SIMD3(x - 0.5, 0, -0.5), maximum: SIMD3(x + 0.5, 3, 0.5))
            var w = world(box, Footprint(center: SIMD2(x, 0), radius: 0.5))
            w.solids[0].motion = SIMD3(step, 0, 0)
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: w)
            let q = abs(SIMD2(c.feet.x - x, c.feet.z)), out = simd_max(q - r, .zero)
            let beyond = simd_length_squared(out) > 0 ? simd_length(out) : max(q.x - r, q.y - r)
            deepest = max(deepest, 0.5 - beyond)
        }
        #expect(deepest <= 1e-3, "the column went \(deepest) m into the body")
        #expect(c.feet.x > 0.5, "not pushed: \(c.feet)")
    }

    @Test("A disc from a volume: the circle its plan's square holds; none for a tilted one")
    func discOfAVolume() {
        let local = BoundingBox(minimum: SIMD3(-2, 0, -2), maximum: SIMD3(2, 0.2, 2))
        let placed = Volume(localBounds: local, transform: Level.transform(yaw: 0.7, scale: 1.5, at: SIMD3(-5, 0, 5)))
        let disc = Footprint(discOf: placed)
        #expect(disc?.radius == 3)
        #expect(disc.map { simd_distance($0.center, SIMD2(-5, 5)) < 1e-5 } ?? false)
        let tilt: Float = 0.3
        let tilted = matrix_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cos(tilt), sin(tilt), 0),
                                               SIMD4(0, -sin(tilt), cos(tilt), 0), SIMD4(0, 0, 0, 1)))
        #expect(Footprint(discOf: Volume(localBounds: local, transform: tilted)) == nil)
    }
}

// MARK: - Leaving after a push

@Suite("Character controller — the speed a push leaves you with")
struct CharacterPushKeptTests {

    private let r = CharacterController.Tuning().radius
    private let g = CharacterController.Tuning().gravity

    /// **The point of it.** Pushed at 1.5 m/s off a 1 m ledge, the body falls for √(2h/g) and goes
    /// 1.5 m/s across the whole time: it lands that much further out, give or take one step's travel.
    /// Before, it landed at the x it left from.
    @Test("Pushed off a ledge, the body flies on at the push's speed")
    func pushedOffALedge() {
        var face: Float = -2
        var c = CharacterController(feet: SIMD3(0, 1, 0))
        let ledge = BoundingBox(minimum: SIMD3(-10, 0, -3), maximum: SIMD3(1, 1, 3))
        var leftAt: Float?
        for _ in 0..<480 {
            // The pusher sits on the ledge and goes on a little past its edge, then stops.
            let move: Float = face < 1.3 ? 1.5 * step : 0
            face += move
            var w = CharacterController.Surroundings(solids: boxes([ledge, BoundingBox(minimum: SIMD3(face - 3, 1, -2), maximum: SIMD3(face, 2.5, 2))]))
            w.solids[1].motion = SIMD3(move, 0, 0)
            let wasGrounded = c.isGrounded
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: w)
            if wasGrounded && !c.isGrounded { leftAt = c.feet.x }
        }
        let flight = 1.5 * (2 * 1 / g).squareRoot()
        let went = c.feet.x - (leftAt ?? .nan)
        #expect(c.isGrounded && abs(c.feet.y) < 1e-4, "not down: \(c.feet)")
        #expect(abs(went - flight) < 1.5 * step + 1e-3, "landed \(went) m past where it left, the push's speed carries it \(flight)")
    }

    @Test("A jump while being pushed takes the push with it")
    func jumpWhilePushed() {
        var face: Float = -2
        var c = CharacterController(feet: .zero)
        var kept: SIMD2<Float>?
        for i in 0..<300 {
            face += 1.5 * step
            var w = CharacterController.Surroundings(solids: boxes([BoundingBox(minimum: SIMD3(face - 3, 0, -2), maximum: SIMD3(face, 1.5, 2))]))
            w.solids[0].motion = SIMD3(1.5 * step, 0, 0)
            c.step(yaw: 0, input: MovementInput(), isJumpHeld: i == 240, deltaTime: step, in: w)
            if i == 240 { kept = c.airVelocity }
        }
        #expect(kept.map { abs($0.x - 1.5) < 1e-3 && abs($0.y) < 1e-5 } ?? false, "jumped keeping \(String(describing: kept))")
    }

    @Test("On the ground, a push that stops leaves the body where it stopped")
    func noCoasting() {
        var face: Float = -2
        var c = CharacterController(feet: .zero)
        for _ in 0..<480 {
            let move: Float = face < 1 ? 1.5 * step : 0
            face += move
            var w = CharacterController.Surroundings(solids: boxes([BoundingBox(minimum: SIMD3(face - 3, 0, -2), maximum: SIMD3(face, 1.5, 2))]))
            w.solids[0].motion = SIMD3(move, 0, 0)
            c.step(yaw: 0, input: MovementInput(), deltaTime: step, in: w)
        }
        #expect(abs(c.feet.x - (1 + r + 0.002)) < 0.002, "coasted to \(c.feet.x)")
    }

    /// A step climbed on the way is not the ground's speed: 0.3 m in one step would be 36 m/s up. A
    /// jump pressed on the very step a carried body climbs rises as any jump from there does.
    @Test("A jump on the step a carried body climbs is an ordinary jump")
    func climbIsNotSpeed() {
        var x: Float = 0
        var c = CharacterController(feet: SIMD3(0, 0.5, 0))
        let ledge = BoundingBox(minimum: SIMD3(1.0, 0, -3), maximum: SIMD3(4, 0.8, 3))
        var apex: Float = 0, jumped = false
        for _ in 0..<240 {
            x += step
            var w = CharacterController.Surroundings(solids: boxes([BoundingBox(minimum: SIMD3(x - 5, 0, -2), maximum: SIMD3(x + 0.5, 0.5, 2)), ledge]))
            w.solids[0].motion = SIMD3(step, 0, 0)
            // Pressed on the step whose carry runs it into the ledge — the body is 0.3 m short of the
            // ledge's face at 1 m/s, so that is the step its box first reaches it.
            let reaching = !jumped && c.feet.x + r + step >= 1.0
            c.step(yaw: 0, input: MovementInput(), isJumpHeld: reaching, deltaTime: step, in: w)
            if reaching { jumped = true; #expect(c.feet.y > 0.79, "the jump step did not climb: \(c.feet.y)") }
            apex = max(apex, c.feet.y)
        }
        let ordinary = 0.8 + CharacterController.Tuning().jumpSpeed * CharacterController.Tuning().jumpSpeed / (2 * g)
        #expect(jumped && apex < ordinary + 0.05, "rose to \(apex), an ordinary jump from the ledge reaches \(ordinary)")
    }
}

// MARK: - A push in the air

@Suite("Character controller — pushed in the air")
struct CharacterAirPushTests {

    private let r = CharacterController.Tuning().radius

    /// A tall block at 1.5 m/s meets a body mid-jump and stops at `stopFace`. Returns where the body
    /// was when the block stopped, when that was, where it came down and when, and the speed it kept.
    private func jumpInFront(startFace: Float = -0.6, stopFace: Float = -0.1, wall: BoundingBox? = nil)
        -> (atStop: Float, stopStep: Int, landed: Float, landStep: Int, kept: Float) {
        var face = startFace
        var c = CharacterController(feet: .zero)
        var atStop: Float = .nan, stopStep = -1, landStep = -1, kept: Float = 0
        for i in 0..<240 {
            let move: Float = face < stopFace ? min(1.5 * step, stopFace - face) : 0
            if move == 0 && stopStep < 0 { stopStep = i; atStop = c.feet.x }
            face += move
            var solids = [BoundingBox(minimum: SIMD3(face - 3, 0, -2), maximum: SIMD3(face, 2.5, 2))]
            if let wall { solids.append(wall) }
            var w = CharacterController.Surroundings(solids: boxes(solids))
            w.solids[0].motion = SIMD3(move, 0, 0)
            let was = c.isGrounded
            c.step(yaw: 0, input: MovementInput(), isJumpHeld: i == 2, deltaTime: step, in: w)
            if !c.isGrounded { kept = max(kept, c.airVelocity.x) }
            if !was && c.isGrounded && landStep < 0 { landStep = i }
        }
        return (atStop, stopStep, c.feet.x, landStep, kept)
    }

    /// **The point of it.** The block stops with 0.29 s of the jump still to go: the body goes on at
    /// 1.5 m/s for all of it. Before, it came down exactly where the block left it.
    @Test("Shoved mid-jump, a body flies on at the pusher's speed after the pusher stops")
    func fliesOn() {
        let run = jumpInFront()
        #expect(run.stopStep > 0 && run.landStep > run.stopStep, "the block did not stop mid-flight: \(run)")
        let flight = Float(run.landStep - run.stopStep) * step
        let went = run.landed - run.atStop
        #expect(abs(went - 1.5 * flight) < 1.5 * step + 1e-3, "went \(went) m after the block stopped, 1.5 m/s for \(flight) s is \(1.5 * flight)")
    }

    /// Where in a step the block first reaches the body changes how far that step moves it — by up to
    /// a step's travel plus the clearance. The speed kept must not change with it.
    @Test("The speed kept is the pusher's, wherever in a step it first touches")
    func sameWhateverTheGap() {
        for part in stride(from: Float(0), to: 1, by: 0.2) {
            let run = jumpInFront(startFace: -0.6 - part * 1.5 * step)
            #expect(abs(run.kept - 1.5) < 1e-4, "starting \(part) of a step later, kept \(run.kept) m/s")
        }
    }

    @Test("Shoved into a wall mid-air, a body keeps nothing it could not go")
    func intoAWall() {
        // A wall just past where the body stands: the block pins it there, mid-jump, and stops.
        let wall = BoundingBox(minimum: SIMD3(r + 0.05, 0, -3), maximum: SIMD3(r + 1, 4, 3))
        let run = jumpInFront(stopFace: 0.1, wall: wall)
        #expect(run.landed <= r + 0.05 - r + 1e-3, "went through the wall to \(run.landed)")
    }
}

// MARK: - However often a game steps

@Suite("Character controller — the same at any step rate")
struct CharacterStepRateTests {

    private let tuning = CharacterController.Tuning()

    /// A jump, stepped at `rate` a second: the highest the feet were, and how long they were off the
    /// ground.
    private func jump(at rate: Float) -> (apex: Float, airborne: Float) {
        let dt = 1 / rate
        var c = CharacterController(feet: .zero)
        var apex: Float = 0, air = 0
        for i in 0..<Int(rate * 2) {
            c.step(yaw: 0, input: MovementInput(), isJumpHeld: i == 1, deltaTime: dt, in: CharacterController.Surroundings())
            apex = max(apex, c.feet.y)
            if !c.isGrounded { air += 1 }
        }
        return (apex, Float(air) * dt)
    }

    /// **The point of it.** v²/2g, whatever the rate: 0.9923 m for a 6.3 m/s jump at this gravity. The
    /// feet are only looked at once a step, so the highest *seen* can be half a step past the top —
    /// ½g(dt/2)² below it, 2.8 mm at 30 a second — and no more. Before: 0.890 m at 30, 0.940 at 60,
    /// 0.966 at 120, 0.979 at 240.
    @Test("A jump rises the same however often the game steps", arguments: [Float(30), 60, 120, 240])
    func sameApex(rate: Float) {
        let exact = tuning.jumpSpeed * tuning.jumpSpeed / (2 * tuning.gravity)
        let sampling = 0.5 * tuning.gravity * (1 / rate / 2) * (1 / rate / 2)
        let apex = jump(at: rate).apex
        #expect(apex <= exact + 1e-5 && apex >= exact - sampling - 1e-5,
                "at \(rate) steps a second the apex was \(apex), the height a \(tuning.jumpSpeed) m/s jump reaches is \(exact)")
    }

    /// **A landing's impact is the speed at the ground.** A fall from exactly 1 m hits at √(2gh) =
    /// 6.3246 m/s; the step's *final* speed made it 6.667 at 30 steps a second — 5% harder than the
    /// ground it hit, and the impact is what a landing's loudness, its dust and the camera's dip are made
    /// from.
    @Test("A landing hits at the speed the ground is reached at, at any step rate", arguments: [Float(30), 60, 120, 240])
    func sameImpact(rate: Float) {
        let dt = 1 / rate, height: Float = 1
        var c = CharacterController(feet: SIMD3(0, height, 0))
        var impact: Float?
        for _ in 0..<Int(rate * 2) {
            c.step(yaw: 0, input: MovementInput(), deltaTime: dt, in: CharacterController.Surroundings())
            for event in c.events { if case .landed(let speed) = event { impact = impact ?? speed } }
        }
        let exact = (2 * tuning.gravity * height).squareRoot()
        #expect(impact.map { abs($0 - exact) < 1e-3 } ?? false,
                "at \(rate) a second it landed at \(String(describing: impact)) m/s, the ground is reached at \(exact)")
    }

    /// **The eye settles by the same curve at any rate, and a slow game does not snap.** A step of
    /// `1/settleRate` — twelfths of a second here — closed the whole gap under `1 − rate·dt`, and past it
    /// the factor went negative. It leaves `e^(−rate·dt)` of the lag, whatever the step.
    @Test("However long the step, the eye keeps the share of its lag the rate says",
          arguments: [Float(10), 30, 120])
    func settleLeavesItsShare(rate: Float) {
        let dt = 1 / rate
        let ledge = BoundingBox(minimum: SIMD3(-2, 0, -6), maximum: SIMD3(2, 0.45, 0.5))
        var c = CharacterController(feet: SIMD3(0, 0, 2))
        var lag: Float?
        for _ in 0..<Int(rate) {
            c.step(yaw: 0, input: MovementInput(forward: 1), deltaTime: dt,
                   in: CharacterController.Surroundings(solids: boxes([ledge])))
            guard c.feet.y > 0.4 else { continue }              // up on the ledge
            let behind = c.feet.y + tuning.eyeHeight - c.eye.y
            if let lag {
                // **And there was a lag to keep.** At ten steps a second the old form closed the whole
                // gap in the step that climbed, so both readings were nothing and any ratio held: that
                // zero is the snap this is about.
                #expect(lag > 0.1, "at \(rate) a second the eye was only \(lag) m behind a 0.45 m climb: it snapped")
                #expect(abs(behind - lag * exp(-tuning.settleRate * dt)) < 1e-4,
                        "at \(rate) a second a step left \(behind) m of \(lag), and \(exp(-tuning.settleRate * dt)) of it is the rate")
                return
            }
            lag = behind
        }
        Issue.record("never climbed the ledge at \(rate) a second")
    }

    /// **A slide covers the ground its curve says, at any rate.** Its speed falls from a sprint's to a
    /// crouch's along `r^0.35`, which integrates over the whole slide to `T·(crouched + (sprint −
    /// crouched)/(e+1))` = 16.138 m. Read once a step and held, it came up short the coarser the steps:
    /// 15.847 m at 30 a second, 15.997 at 60, 16.069 at 120, 16.093 at 240.
    ///
    /// **The keys go by the clock, not by the step count** — a slide begun on "the twelfth step" begins at
    /// a different moment at each rate, and then the rates are being asked a different question.
    @Test("A slide covers the same ground however often the game steps", arguments: [Float(30), 60, 120, 240])
    func sameSlide(rate: Float) {
        let dt = 1 / rate
        var c = CharacterController(feet: .zero)
        var slid: Float = 0, time: Float = 0
        while time < 3 {
            let sprinting = time < 1
            let before = c.feet
            c.step(yaw: 0, input: MovementInput(forward: 1, isSprinting: sprinting), isCrouching: !sprinting,
                   deltaTime: dt, in: CharacterController.Surroundings())
            if c.slideProgress > 0 { slid += simd_distance(before, c.feet) }
            time += dt
        }
        let exact = tuning.slideDuration
            * (tuning.walkSpeed * tuning.crouchedSpeedFraction
               + (tuning.sprintSpeed - tuning.walkSpeed * tuning.crouchedSpeedFraction) / (tuning.slideEasing + 1))
        // The step a slide ends inside is not counted here — the slide is over by the time the step is
        // looked at — so the window can fall short by that step's crouched walk, and no more.
        let window = tuning.walkSpeed * tuning.crouchedSpeedFraction * dt
        #expect(abs(slid - exact) < 0.01 + window,
                "at \(rate) a second the slide covered \(slid) m, its curve integrates to \(exact)")
    }

    /// A rate per second closes the same share of the gap in a second, however it is cut up: half of it
    /// in half a second, twice, is the same as all of it once.
    @Test("A settle of a whole second is the same in one step or a hundred", arguments: [Float(1), 2, 10, 100])
    func settleAddsUp(steps: Float) {
        var c = CharacterController(feet: SIMD3(0, 1, 0))
        // Drop it onto a floor 1 m down, then let the eye catch up over exactly one second.
        let floor = BoundingBox(minimum: SIMD3(-5, 0, -5), maximum: SIMD3(5, 0, 5))
        var many = c
        for _ in 0..<Int(steps) { many.step(yaw: 0, input: MovementInput(), deltaTime: 1 / steps, in: .init(solids: boxes([floor]))) }
        c.step(yaw: 0, input: MovementInput(), deltaTime: 1, in: .init(solids: boxes([floor])))
        #expect(abs(many.eye.y - c.eye.y) < 2e-3, "\(steps) steps of a second left the eye at \(many.eye.y), one step at \(c.eye.y)")
    }

    /// And it is in the air for 2v/g, within a step: the flight a game's timing is built around.
    @Test("A jump lasts the same however often the game steps", arguments: [Float(30), 60, 120, 240])
    func sameFlight(rate: Float) {
        let exact = 2 * tuning.jumpSpeed / tuning.gravity
        let airborne = jump(at: rate).airborne
        #expect(abs(airborne - exact) <= 1 / rate + 1e-5, "at \(rate) a second it was airborne \(airborne) s, the flight is \(exact)")
    }
}

@Suite("Character controller — teleporting")
struct CharacterTeleportTests {

    /// **Respawning by making a new controller put the tuning back to the defaults** unless it was
    /// passed again; teleporting keeps it, and drops everything else the body was doing.
    @Test("A teleport keeps the tuning and drops the rest, as a fresh body would have it")
    func teleportKeepsTuning() {
        var tuning = CharacterController.Tuning()
        tuning.walkSpeed = 3
        var c = CharacterController(feet: .zero, tuning: tuning)
        run(&c, seconds: 1, MovementInput(forward: 1, isSprinting: true))
        run(&c, seconds: 0.2, MovementInput(forward: 1, isSprinting: true), isCrouching: true)
        #expect(c.isSliding)
        c.teleport(to: SIMD3(5, 2, 5))
        let fresh = CharacterController(feet: SIMD3(5, 2, 5), tuning: tuning)
        #expect(c.tuning.walkSpeed == 3)
        #expect(c.feet == fresh.feet && c.eye == fresh.eye && !c.isSliding && c.isGrounded == fresh.isGrounded)
        #expect(c.verticalVelocity == 0 && c.slideTimeRemaining == 0 && c.eyeHeight == tuning.eyeHeight)
        // And it walks the same from there.
        var a = c, b = fresh
        run(&a, seconds: 0.5, MovementInput(forward: 1))
        run(&b, seconds: 0.5, MovementInput(forward: 1))
        #expect(a.feet == b.feet && a.eye == b.eye)
    }

    @Test("The engine's walking speeds are the controller's own defaults")
    func literalDefaults() {
        let t = CharacterController.Tuning()
        #expect(t.walkSpeed == 6 && t.sprintSpeed == 18)
    }
}
