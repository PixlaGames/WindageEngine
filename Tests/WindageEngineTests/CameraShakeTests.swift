//
//  CameraShakeTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// The shake's arithmetic.
///
/// **Feel is the one thing nobody thinks to test, and the one thing that is tuned most often.** Each number in
/// ``CameraShake`` was chosen for a reason written down beside it; these are the checks that stop the reason and the
/// number drifting apart — a punch that no longer returns to zero, a shake that stacks.
@Suite("Camera shake")
struct CameraShakeTests {

    private let tuning = CameraShake.Tuning()

    @Test("A camera nobody has hit does not move")
    func restingCameraIsStill() {
        var camera = CameraShake()
        camera.advance(by: 1.0 / 60)
        #expect(camera.offset == .zero)
    }

    /// **The reason trauma exists rather than a shake per hit.** Amplitudes that sum give a camera
    /// that is calm at one hit and unreadable at five.
    @Test("Five blows in a row do not stack into an unreadable screen")
    func traumaCannotStack() {
        var camera = CameraShake()
        for _ in 0..<5 { camera.took(force: 1) }
        #expect(camera.trauma == 1)
        camera.advance(by: 1.0 / 60)
        let shake = (camera.offset * camera.offset).sum().squareRoot()
        #expect(shake <= tuning.shakeDistance * 1.01)
    }

    /// Squared, so halving the trauma quarters the movement: small hits stay a tremor.
    @Test("Displacement is trauma squared, not trauma")
    func traumaIsSquared() {
        func shake(after trauma: Float) -> Float {
            var camera = CameraShake()
            camera.took(force: 1)
            // Bleed down to the trauma we want, then read it without advancing the noise further.
            camera.advance(by: (1 - trauma) * tuning.traumaLife)
            return (camera.offset * camera.offset).sum().squareRoot()
        }
        let full = shake(after: 1)
        let half = shake(after: 0.5)
        // Quarter, not half — allow slack for where the noise happens to be.
        #expect(half < full * 0.5)
    }

    @Test("Trauma bleeds away to nothing on its own")
    func traumaDecays() {
        var camera = CameraShake()
        camera.took(force: 1)
        camera.advance(by: tuning.traumaLife)
        #expect(camera.trauma == 0)
        #expect(camera.offset == .zero)
    }

    /// **Landing a blow leans the camera into it.** The direction is the caller's; the length is
    /// ours, so a caller handing over an unnormalised vector cannot throw the screen.
    @Test("A punch goes the way it was aimed, whatever length the caller passed")
    func punchIsNormalised() {
        var near = CameraShake(), far = CameraShake()
        near.landed(force: 0.72, towards: SIMD3(0, 0, 1))
        far.landed(force: 0.72, towards: SIMD3(0, 0, 400))
        #expect(abs(near.kick.z - far.kick.z) < 0.0001)
        #expect(near.kick.z > 0)
    }

    @Test("A blow aimed nowhere is ignored rather than dividing by zero")
    func zeroDirectionIsSafe() {
        var camera = CameraShake()
        camera.landed(force: 1, towards: .zero)
        #expect(camera.kick == .zero)
        #expect(camera.trauma == 0)
    }

    @Test("A punch settles back rather than overshooting")
    func punchDecaysToZero() {
        var camera = CameraShake()
        camera.landed(force: 1, towards: SIMD3(1, 0, 0))
        let start = camera.kick.x
        #expect(start > 0)
        var previous = start
        for _ in 0..<20 {
            camera.advance(by: tuning.kickHalfLife / 2)
            #expect(camera.kick.x <= previous, "a punch must never grow on its way home")
            #expect(camera.kick.x >= 0, "a punch must not overshoot past where it started")
            previous = camera.kick.x
        }
        // **Exponential decay never actually arrives**, which is why there is a threshold below
        // which the offset is snapped away rather than carried forever. Given long enough, the
        // camera is exactly where it started — not a tenth of a millimetre from it.
        camera.advance(by: tuning.kickHalfLife * 20)
        #expect(camera.kick == .zero)
    }

    /// **Landing and taking a blow are separate channels**, so the two cannot cancel.
    @Test("Taking a blow while landing one does not cancel either")
    func channelsAreIndependent() {
        var camera = CameraShake()
        camera.landed(force: 0.72, towards: SIMD3(1, 0, 0))
        let kick = camera.kick
        camera.took(force: 0.72)
        #expect(camera.kick == kick)
        #expect(camera.trauma > 0)
    }

    /// **Time, not frames.** A shake keyed to frame count runs at double speed on a 120 Hz display,
    /// which is a bug nobody finds until somebody with a better monitor says it feels wrong.
    @Test("The same second of shake is the same shake at any frame rate")
    func shakeIsTimeKeyed() {
        func offset(steps: Int) -> SIMD3<Float> {
            var camera = CameraShake()
            camera.took(force: 1)
            for _ in 0..<steps { camera.advance(by: 0.24 / Float(steps)) }
            return camera.offset
        }
        let at60 = offset(steps: 15)
        let at120 = offset(steps: 30)
        let apart = ((at60 - at120) * (at60 - at120)).sum().squareRoot()
        #expect(apart < 0.01, "60 Hz and 120 Hz disagree by \(apart) m after the same 0.24 s")
    }

    /// The noise has to be *smooth*: white noise at frame rate is a blur, and what reads as an
    /// impact is the camera being carried somewhere and hauled back.
    @Test("The shake is carried, not scattered")
    func shakeIsSmooth() {
        var camera = CameraShake()
        camera.took(force: 1)
        var previous = camera.offset
        var worst: Float = 0
        for _ in 0..<30 {
            camera.advance(by: 1.0 / 240)
            let step = ((camera.offset - previous) * (camera.offset - previous)).sum().squareRoot()
            worst = max(worst, step)
            previous = camera.offset
        }
        // A quarter of a 240 Hz frame's travel against the full amplitude would be scatter.
        #expect(worst < tuning.shakeDistance * 0.5)
    }
}

/// Whether any of this is actually visible.
///
/// **The test that had to exist, because the first version was invisible and passed everything.** Every curve was
/// correct, every decay behaved, nothing stacked — and a routine blow moved the camera by **0.3% of the screen's
/// height**, about two pixels, measured off real frames. Feel is the one thing that can be entirely right in its
/// arithmetic and entirely absent on screen.
///
/// **In fractions of screen height, not pixels**, at ``OrbitCamera``'s default framing, which the defaults are set for.
@Suite("Whether a shake can actually be seen")
struct CameraShakeVisibilityTests {

    /// What the camera can see, top to bottom, at the distance an orbit camera sits by default.
    private static let visibleHeight: Float = {
        let camera = OrbitCamera()
        return 2 * camera.distance * tanf(camera.fieldOfView / 2)
    }()

    /// A displacement as a fraction of the screen's height, 0…1.
    private func onScreen(_ metres: Float) -> Float { metres / Self.visibleHeight }

    /// The largest the camera gets after one blow, sampled finely enough not to miss a peak.
    private func peakOffset(_ apply: (inout CameraShake) -> Void) -> Float {
        var camera = CameraShake()
        apply(&camera)
        var peak: Float = 0
        // 1 ms steps for a second: the shake runs at 20 Hz, and sampling at frame rate aliases.
        for _ in 0..<1000 {
            camera.advance(by: 0.001)
            peak = max(peak, (camera.offset * camera.offset).sum().squareRoot())
        }
        return peak
    }

    /// **A routine blow is still a thing that happened to you.** Below about half a percent nothing
    /// is being communicated, and the player is right to say combat feels like nothing.
    @Test("A half-force blow taken is visible")
    func anOrdinaryBlowIsVisible() {
        let seen = onScreen(peakOffset { $0.took(force: 0.5) })
        #expect(seen > 0.008, "a half-force blow moves the camera \(seen * 100)% of screen height")
        // And not so far that something chewing on you makes the game unplayable.
        #expect(seen < 0.025)
    }

    @Test("A full-force blow is a jolt, and still within reason")
    func aFatalBlowIsAJolt() {
        let seen = onScreen(peakOffset { $0.took(force: 1) })
        #expect(seen > 0.035, "a full-force blow moves \(seen * 100)% of screen height")
        #expect(seen < 0.09, "past about 9% a camera is being thrown, not jolted")
    }

    /// **The most-felt number in the whole feel layer**, because it happens on every swing rather
    /// than on the rare occasions somebody lands one on you.
    @Test("Landing a half-force blow leans the camera enough to notice")
    func landingIsFelt() {
        let seen = onScreen(peakOffset { $0.landed(force: 0.5, towards: SIMD3(0, 0, 1)) })
        #expect(seen > 0.008, "landing a blow moves \(seen * 100)% of screen height")
        #expect(seen < 0.04)
    }

    @Test("Harder blows are felt harder, all the way up")
    func visibilityIsOrdered() {
        let blow = peakOffset { $0.took(force: 0.5) }
        let heavy = peakOffset { $0.took(force: 0.72) }
        let fatal = peakOffset { $0.took(force: 1) }
        #expect(blow < heavy)
        #expect(heavy < fatal)
    }

    /// **The shake has to survive the frame rate.** At 24 Hz there are two and a half 60 Hz frames
    /// to an oscillation, which aliases into a slower, uglier wobble than the one asked for — so the
    /// rate is capped against the frame rate the game is built for rather than chosen by ear.
    @Test("The shake is slow enough to survive a 60 Hz display")
    func shakeSurvivesTheFrameRate() {
        // Nyquist: at least two samples per oscillation, and in practice three to look intended.
        #expect(CameraShake.Tuning().shakeRate <= 60 / 3)
    }
}
