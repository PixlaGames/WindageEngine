//
//  OneCourseTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// **One course that uses the whole body, at four step rates, giving one set of numbers.**
///
/// The rate independence was won a piece at a time — the flight, a landing's impact, the eye's
/// settling, the slide, all on 2026-09-11 — and each of those has a test of its own, over the
/// one thing it fixed, from rest. This is the capstone: eight seconds of walking, jumping, climbing,
/// sprinting, sliding, falling and landing, one after another, with every error the course collects
/// carried forward into the next thing rather than started afresh.
///
/// **Every number below is computed, not merely recorded**, which is what makes the four rates agreeing
/// mean something: four wrong answers can agree with each other.
///
/// ### The two rules a test like this lives or dies by
///
/// **Press the keys by the clock, not by the step count.** A jump on "the step where i == 72" is a jump
/// at a different moment at each rate, from a different place, and the rates are then being asked
/// different questions. Every boundary here is an elapsed time, and every one of them is a whole
/// number of steps at the *slowest* rate, so no boundary is rounded at any of them.
///
/// **A centimetre is as tight as this can be asked, and the floor is the float, not the physics.**
/// `feet` is a `Float` accumulating a step's travel 240 times a second; a plain eight-second walk in a
/// straight line — no jump, no slide, nothing but the addition — lands 0.1 mm from 48 m at 30 steps a
/// second, 0.6 mm at 240 and 1.8 mm at 480. The course agrees to about a millimetre and a half, which
/// is that and nothing else.
///
/// ### What it catches, switched off one at a time
///
/// | | what fails |
/// |---|---|
/// | the flight taken at the velocity a step ends at | the jump at all four rates, every landing at all four, the footsteps at 30 and 60 |
/// | a landing's speed read at the end of its step | every landing at all four rates — 0.41 m/s out at 30 |
/// | the slide read once a step | the ending, at all four — 0.246 m short at 30, 0.033 at 240 |
/// | the eye settled by `1 − rate·dt` | **nothing here.** See below |
///
/// ### The one it cannot catch, and why that is not a gap to fill
///
/// **A law whose clock starts at a collision cannot be pinned by a course.** The eye's settling is
/// kicked when the feet climb something, and a climb happens on whichever step the body's next position
/// first overlaps the tread — a moment the step grid rounds, by up to 33 ms at 30 a second. The lag half
/// a second later is therefore `e^(−12·Δ)` of what it should be, Δ being that rounding: a third either
/// way, on a quantity of about a centimetre. Placing a tread so that contact lands exactly on a step
/// boundary at all four rates only moves the problem, because "exactly" is a float comparison against an
/// accumulated position, and it then climbs a step early or late depending on the last bit.
///
/// So the settling is pinned where it can be — between two consecutive steps of one run, which is what
/// `CharacterStepRateTests.settleLeavesItsShare` does — and this course does not pretend to. Switching
/// the exponential back to `1 − rate·dt` does move what the *sample* prints (the eye reads 1.70 m above
/// the feet at the top of the ruins' stairs at 30 steps a second where it reads 1.69), and that number
/// is deliberately not among the recorded walks: it sits on the rounding of the printed centimetre, which
/// is a coin toss to record, not a check.
@Suite("Character controller — one course, four rates")
struct OneCourseTests {

    static let tuning = CharacterController.Tuning()
    static let rates: [Float] = [30, 60, 120, 240]

    /// What the course gives: where it ends, how hard each landing was, how high the jump went and how
    /// many times a foot came down.
    struct Run {
        var feet = SIMD3<Float>.zero
        var eye = SIMD3<Float>.zero
        var impacts: [Float] = []
        var jumpApex: Float = 0
        var footsteps = 0
    }

    /// Flat ground, a cliff three metres down beyond `z = −50`, and three treads to climb and walk off.
    /// Each tread is 0.4 m, inside the 0.45 m step, so they are climbed rather than jumped.
    static var world: CharacterController.Surroundings {
        CharacterController.Surroundings(
            groundHeight: { _, z in z > -50 ? 0 : -3 },
            solids: [
                .init(bounds: BoundingBox(minimum: SIMD3(-3, 0, -10.2), maximum: SIMD3(3, 0.4, -8.8))),
                .init(bounds: BoundingBox(minimum: SIMD3(-3, 0, -11.6), maximum: SIMD3(3, 0.8, -10.2))),
                .init(bounds: BoundingBox(minimum: SIMD3(-3, 0, -13.0), maximum: SIMD3(3, 1.2, -11.6))),
            ]
        )
    }

    /// Forward the whole way; jump at half a second; sprint from three; crouch — so, slide — from
    /// three and a half until five. 8.2 s in all.
    static func course(at rate: Float) -> Run {
        let dt = 1 / rate
        var c = CharacterController(feet: .zero)
        var run = Run()
        let w = world
        for i in 0..<Int(rate * 8.2) {
            let t = Float(i) / rate
            c.step(yaw: 0,
                   input: MovementInput(forward: 1, isSprinting: t >= 3.0 && t < 3.5),
                   isJumpHeld: t >= 0.5 && t < 0.6,
                   isCrouching: t >= 3.5 && t < 5.0,
                   deltaTime: dt,
                   in: w)
            // The jump is over well before the first tread, so this is the jump's height and not a stair's.
            if t < 1.3 { run.jumpApex = max(run.jumpApex, c.feet.y) }
            for event in c.events {
                switch event {
                case .landed(let speed): run.impacts.append(speed)
                case .stride: run.footsteps += 1
                case .jumped: break
                }
            }
        }
        run.feet = c.feet
        run.eye = c.eye
        return run
    }

    /// **Where the course ends is the sum of what each part of it is worth**, and not one of those
    /// terms is a reading taken off the run:
    ///
    /// | | seconds | at | metres |
    /// |---|---|---|---|
    /// | walk, with a jump and three treads inside it | 0 → 3.0 | 6 m/s | 18 |
    /// | sprint | 3.0 → 3.5 | 18 m/s | 9 |
    /// | slide | 3.5 → 4.65 | `∫ r^0.35` of it | 16.138 |
    /// | crouched walk, the slide spent | 4.65 → 5.0 | 2.7 m/s | 0.945 |
    /// | walk, over the cliff and on | 5.0 → 8.2 | 6 m/s | 19.2 |
    ///
    /// A jump and a fall cost nothing across, because the body holds its walking speed through the air.
    static var courseLength: Float {
        let t = tuning
        let crouched = t.walkSpeed * t.crouchedSpeedFraction
        let slide = t.slideDuration * (crouched + (t.sprintSpeed - crouched) / (t.slideEasing + 1))
        return t.walkSpeed * 3.0
            + t.sprintSpeed * 0.5
            + slide
            + crouched * (1.5 - t.slideDuration)   // what is left of the crouch once the slide is spent
            + t.walkSpeed * 3.2
    }

    @Test("The course ends in the same place however often the game steps", arguments: rates)
    func sameEnd(rate: Float) {
        let run = Self.course(at: rate)
        #expect(abs(-run.feet.z - Self.courseLength) < 0.01,
                "at \(rate) steps a second the course ended at z \(run.feet.z); its parts add to \(-Self.courseLength)")
        #expect(run.feet.x == 0, "at \(rate) a second it wandered to x \(run.feet.x)")
        #expect(run.feet.y == -3, "at \(rate) a second it ended at y \(run.feet.y), not on the floor of the drop")
        // Stood up again, settled, the landing spring recovered: the eye is its own height above the feet.
        #expect(abs(run.eye.y - (run.feet.y + Self.tuning.eyeHeight)) < 1e-3,
                "at \(rate) a second the eye ended \(run.eye.y - run.feet.y) m up, not \(Self.tuning.eyeHeight)")
    }

    /// Three landings, each at the speed of the ground it reached: back from the jump at exactly the
    /// speed it left at, then `√(2gh)` off the top tread and off the cliff.
    @Test("Every landing hits at the speed its own fall reaches", arguments: rates)
    func sameImpacts(rate: Float) {
        let g = Self.tuning.gravity
        let wanted: [Float] = [Self.tuning.jumpSpeed, (2 * g * 1.2).squareRoot(), (2 * g * 3).squareRoot()]
        let got = Self.course(at: rate).impacts
        #expect(got.count == wanted.count, "at \(rate) a second it landed \(got.count) times, not \(wanted.count): \(got)")
        for (a, b) in zip(got, wanted) {
            #expect(abs(a - b) < 1e-3, "at \(rate) a second a landing read \(a) m/s where the ground is reached at \(b)")
        }
    }

    /// The jump inside the course rises what a 6.3 m/s jump rises, less the half step the feet can be
    /// past the top before they are looked at.
    @Test("The jump in the middle of it rises the same", arguments: rates)
    func sameApex(rate: Float) {
        let exact = Self.tuning.jumpSpeed * Self.tuning.jumpSpeed / (2 * Self.tuning.gravity)
        let sampling = 0.5 * Self.tuning.gravity * (1 / rate / 2) * (1 / rate / 2)
        let apex = Self.course(at: rate).jumpApex
        #expect(apex <= exact + 1e-5 && apex >= exact - sampling - 1e-5,
                "at \(rate) a second the jump reached \(apex), a \(Self.tuning.jumpSpeed) m/s jump reaches \(exact)")
    }

    /// **And the feet come down the same number of times.** A stride is distance, not time, so the
    /// count is the course's length divided among the gaits that covered it — but the phase is carried
    /// through every jump, tread and slide, so one gait ending a step early at one rate would show here
    /// and nowhere else.
    @Test("A foot comes down the same number of times", arguments: rates)
    func sameFootsteps(rate: Float) {
        #expect(Self.course(at: rate).footsteps == 14,
                "at \(rate) steps a second a foot came down \(Self.course(at: rate).footsteps) times, not 14")
    }
}
