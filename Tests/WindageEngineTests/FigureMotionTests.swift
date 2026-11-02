//
//  FigureMotionTests.swift
//  WindageEngineTests
//

import Foundation
import Testing
@testable import WindageEngine

/// A figure's walking, jumping and one-shots (``FigureMotion``), moved with it from the game it was written for — pinned,
/// since the only other way to check them is holding a key down and looking.
@Suite("How a figure is moving")
struct FigureMotionTests {

    /// Every clip a second long, so a time is a fraction and a phase reads straight off it.
    private let second: (String) -> TimeInterval? = { _ in 1 }
    private let frame: TimeInterval = 1.0 / 60
    private let clips = LocomotionBlend.Clips(gaits: [.init("Walk", 1.45), .init("Run", 2.59), .init("Sprint", 7.24)])

    /// A gait with a strafe each side, and a crouched set — a figure that changes clip sets.
    private let directional = LocomotionBlend.Clips(gaits: [
        .init("Walk", 1.45, directions: [.init("WalkL", heading: .pi / 2, phase: 0.1),
                                         .init("WalkB", heading: .pi, phase: 0.5),
                                         .init("WalkR", heading: -.pi / 2)]),
    ])
    private let crouched = LocomotionBlend.Clips(gaits: [.init("CrouchWalk", 1.45)], idle: "CrouchIdle")

    private func run(_ motion: inout FigureMotion, for seconds: TimeInterval, body: FigureMotion.Body,
                     oneShots: [FigureMotion.OneShot] = [], clips: LocomotionBlend.Clips? = nil) -> [FigureMotion.Play] {
        var plays: [FigureMotion.Play] = []
        for _ in 0..<Int((seconds / frame).rounded()) {
            plays = motion.advance(by: frame, body: body, oneShots: oneShots, clips: clips ?? self.clips,
                                   duration: second)
        }
        return plays
    }

    private func weight(_ name: String, in plays: [FigureMotion.Play]) -> Float {
        plays.first { $0.name == name }?.weight ?? 0
    }

    private func time(_ name: String, in plays: [FigureMotion.Play]) -> TimeInterval? {
        plays.first { $0.name == name }?.time
    }

    @Test("Walking at the walk's own pace eases into the walk alone")
    func walks() {
        var motion = FigureMotion()
        let plays = run(&motion, for: 1, body: .init(groundSpeed: clips.gaits[0].speed))
        #expect(weight("Walk", in: plays) > 0.99)
        #expect(weight("Idle", in: plays) < 0.01)
    }

    @Test("The stride moves on with the pace, and backwards while backing away")
    func strideDirection() {
        var forward = FigureMotion()
        _ = run(&forward, for: 0.25, body: .init(groundSpeed: clips.gaits[0].speed))
        var back = FigureMotion()
        _ = run(&back, for: 0.25, body: .init(groundSpeed: clips.gaits[0].speed, backpedaling: true))
        #expect(abs(forward.walkPhase - 0.25) < 0.02, "a one-second walk a quarter played is a quarter through")
        #expect(abs(back.walkPhase - 0.75) < 0.02, "backing away runs the stride the other way")
    }

    @Test("A stride taken up again starts at the beginning of a stride")
    func strideRestarts() {
        var motion = FigureMotion()
        _ = run(&motion, for: 0.4, body: .init(groundSpeed: clips.gaits[0].speed))
        _ = run(&motion, for: 0.5, body: .init())
        let plays = motion.advance(by: frame, body: .init(groundSpeed: clips.gaits[0].speed), clips: clips,
                                   duration: second)
        #expect(abs(motion.walkPhase - frame) < 0.002)
        #expect(abs((time("Walk", in: plays) ?? 1) - frame) < 0.002)
    }

    @Test("A one-shot takes its own weight from everything else, at its own age")
    func oneShotOverrides() {
        var motion = FigureMotion()
        _ = run(&motion, for: 1, body: .init())
        let plays = motion.advance(by: frame, body: .init(), oneShots: [.init(clip: "Attack", age: 0.3, weight: 0.8)],
                                   clips: clips, duration: second)
        #expect(abs(weight("Attack", in: plays) - 0.8) < 0.001)
        #expect(abs(weight("Idle", in: plays) - 0.2) < 0.01)
        #expect(time("Attack", in: plays) == 0.3)
    }

    @Test("One-shots lie over each other in turn, and each holds its last frame")
    func oneShotsLayer() {
        var motion = FigureMotion()
        _ = run(&motion, for: 1, body: .init())
        let plays = motion.advance(by: frame, body: .init(),
                                   oneShots: [.init(clip: "Swipe", age: 0.2, weight: 1),
                                              .init(clip: "Hit", age: 5, weight: 0.75)],
                                   clips: clips, duration: second)
        #expect(abs(weight("Swipe", in: plays) - 0.25) < 0.001)
        #expect(abs(weight("Hit", in: plays) - 0.75) < 0.001)
        #expect(weight("Idle", in: plays) < 0.001)
        #expect((time("Hit", in: plays) ?? 0) > 0.99 && (time("Hit", in: plays) ?? 1) < 1, "a one-shot never loops")
    }

    @Test("A one-shot's envelope fades in, holds and fades out")
    func envelope() {
        typealias Shot = FigureMotion.OneShot
        #expect(Shot.envelope(at: 0.025, lasting: 1, fadeIn: 0.05, fadeOut: 0.2) == 0.5)
        #expect(Shot.envelope(at: 0.5, lasting: 1, fadeIn: 0.05, fadeOut: 0.2) == 1)
        #expect(abs(Shot.envelope(at: 0.9, lasting: 1, fadeIn: 0.05, fadeOut: 0.2) - 0.5) < 1e-5)
        #expect(Shot.envelope(at: 1, lasting: 1, fadeIn: 0.05, fadeOut: 0.2) == 0)
        #expect(Shot.envelope(at: -0.1, lasting: 1, fadeIn: 0.05, fadeOut: 0.2) == 0)
    }

    @Test("A jump plays from its first frame and holds its last")
    func jumpIsAOneShot() {
        var motion = FigureMotion()
        _ = run(&motion, for: 0.5, body: .init())
        let start = motion.advance(by: frame, body: .init(airborne: true, rising: true), clips: clips, duration: second)
        #expect(time("Jump", in: start) == 0)
        let late = run(&motion, for: 2, body: .init(airborne: true, rising: true))
        #expect((time("Jump", in: late) ?? 0) > 0.99)
        #expect((time("Jump", in: late) ?? 1) < 1)
    }

    @Test("A strafe plays the gait's direction, sampled at the shared phase plus its own offset")
    func strafes() {
        var motion = FigureMotion()
        let plays = run(&motion, for: 1, body: .init(groundSpeed: 1.45, heading: .pi / 2), clips: directional)
        #expect(weight("WalkL", in: plays) > 0.99)
        #expect(weight("Walk", in: plays) < 0.01)
        let expected = (motion.walkPhase + 0.1).truncatingRemainder(dividingBy: 1)
        #expect(abs((time("WalkL", in: plays) ?? -1) - expected) < 1e-4)
    }

    @Test("Offsets measured off the model are added to the clips' own")
    func measuredOffsets() {
        var motion = FigureMotion()
        let plays = motion.advance(by: 0.25, body: .init(groundSpeed: 1.45, heading: .pi), clips: directional,
                                   duration: second, strideOffsets: ["WalkB": 0.3])
        #expect(abs((time("WalkB", in: plays) ?? -1) - (0.25 + 0.5 + 0.3 - 1)) < 1e-4)
    }

    @Test("A stride from the last clip set easing out stays on the shared phase")
    func clipSetChange() {
        var motion = FigureMotion(easing: 0.025)
        _ = run(&motion, for: 0.5, body: .init(groundSpeed: 1.45), clips: clips)
        // Crouched: the walk is no stride of these clips, but it is still easing out, and must not jump to the loop clock.
        let plays = motion.advance(by: frame, body: .init(groundSpeed: 1.45), clips: crouched, duration: second)
        #expect(weight("Walk", in: plays) > 0)
        #expect(abs((time("Walk", in: plays) ?? -1) - motion.walkPhase) < 1e-4)
        #expect(weight("CrouchWalk", in: plays) > 0)
        let settled = run(&motion, for: 0.5, body: .init(groundSpeed: 1.45), clips: crouched)
        #expect(weight("CrouchWalk", in: settled) > 0.99)
        #expect(weight("Walk", in: settled) == 0, "a clip eased all the way out is let go")
    }

    @Test("The easing is the figure's own: a short half-life hands over sooner")
    func easing() {
        var slow = FigureMotion()
        var quick = FigureMotion(easing: 0.025)
        let a = run(&slow, for: 0.1, body: .init(groundSpeed: 1.45))
        let b = run(&quick, for: 0.1, body: .init(groundSpeed: 1.45))
        #expect(abs(weight("Walk", in: a) - 0.5) < 0.02, "a tenth of a second is one half-life")
        #expect(weight("Walk", in: b) > 0.9)
    }

    @Test("Figures started at different clocks idle out of step")
    func clocks() {
        var one = FigureMotion(), other = FigureMotion(clock: 0.37)
        let a = run(&one, for: 0.5, body: .init()), b = run(&other, for: 0.5, body: .init())
        #expect(abs((time("Idle", in: b) ?? 0) - (time("Idle", in: a) ?? 0) - 0.37) < 1e-6)
    }

    @Test("A speed, heading or age that is not a number poses nothing that is not one")
    func nonFinite() {
        var motion = FigureMotion()
        for value: Float in [.infinity, .nan] {
            let plays = motion.advance(by: frame, body: .init(groundSpeed: value, heading: value),
                                       oneShots: [.init(clip: "Attack", age: .nan, weight: 0.5)],
                                       clips: directional, duration: second)
            #expect(plays.allSatisfy { $0.time.isFinite && $0.weight.isFinite })
        }
        #expect(motion.walkPhase.isFinite)
    }
}
