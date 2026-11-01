//
//  LocomotionBlendTests.swift
//  WindageEngineTests
//

import Testing
@testable import WindageEngine

/// Which clip a character plays: moved with ``LocomotionBlend`` from the game it was written for, against the clips
/// that game measured — a walk authored at 1.45 m/s, a run at 2.59, a sprint at 7.24, each from its root motion.
@Suite("Which clip a character is playing")
struct LocomotionBlendTests {

    private let clips = LocomotionBlend.Clips(gaits: [.init("Walk", 1.45), .init("Run", 2.59), .init("Sprint", 7.24)])
    /// The game's own movement: 4.5 m/s, sprinting at 8.
    private let moving: Float = 4.5, sprinting: Float = 8

    private func blend(_ speed: Float) -> LocomotionBlend {
        LocomotionBlend.choose(airborne: false, rising: false, groundSpeed: speed, clips: clips)
    }

    private func weight(_ b: LocomotionBlend, _ clip: String) -> Float {
        b.weights.first { $0.clip == clip }?.weight ?? 0
    }

    @Test("Standing still is the idle, and nothing else")
    func standing() {
        let b = blend(0)
        #expect(weight(b, "Idle") == 1)
        #expect(b.weights.count == 1)
        #expect(b.strideReference == nil)
    }

    /// **The bug the type exists for**: 4.5 m/s on a walk authored at 1.45 is a walk cycle at 3.1×.
    @Test("Ordinary movement is not the walk clip played fast")
    func ordinaryMovementIsNotAWalk() {
        let b = blend(moving)
        #expect(weight(b, "Walk") == 0)
        #expect(b.strideReference == "Run")
    }

    /// **One clip, never two**: a single clip cannot cross its own legs.
    @Test("Exactly one gait plays at any speed")
    func oneGaitAtATime() {
        for step in 0...Int(sprinting * 4) {
            let b = blend(Float(step) * 0.25)
            #expect(b.weights.count == 1)
            #expect(b.weights[0].weight == 1)
        }
    }

    @Test("Sprinting reaches the sprint cycle")
    func sprintingReachesTheSprint() {
        let b = blend(sprinting)
        #expect(weight(b, "Sprint") == 1)
        #expect(b.strideReference == "Sprint")
    }

    /// Faster reads as hurrying, slower as slow motion: the slow side is held near 1.
    @Test("Nothing plays in slow motion; the stretching is all on the fast side")
    func paceStaysHonest() {
        for step in 0...Int(sprinting * 4) {
            let speed = Float(step) * 0.25
            let b = blend(speed)
            guard b.strideReference != nil, speed >= clips.gaits[0].speed else { continue }
            #expect(b.pace >= clips.slowestBelievablePlayback && b.pace < 2.5,
                    "pace was \(b.pace) at \(speed) m/s on \(b.strideReference ?? "-")")
        }
    }

    @Test("A slow drift is the idle, not a gait creeping along")
    func drifting() {
        #expect(weight(blend(0.4), "Idle") == 1)
    }

    /// **The crossover is where the faster clip becomes believable, not the geometric mean.**
    @Test("A gait is not taken up until it can be played at pace")
    func crossover() {
        let sprint = clips.gaits[2].speed
        let handover = sprint * clips.slowestBelievablePlayback
        #expect(blend(handover * 0.98).strideReference == "Run")
        #expect(blend(handover * 1.02).strideReference == "Sprint")
        #expect(blend((clips.gaits[1].speed * sprint).squareRoot()).strideReference == "Run")
    }

    @Test("Going up plays the rise; coming down plays the fall; and off the ground beats speed")
    func airborne() {
        let up = LocomotionBlend.choose(airborne: true, rising: true, groundSpeed: sprinting, clips: clips)
        #expect(weight(up, "Jump") == 1)
        let down = LocomotionBlend.choose(airborne: true, rising: false, groundSpeed: sprinting, clips: clips)
        #expect(weight(down, "Air") == 1)
        #expect(down.weights.count == 1)
    }

    @Test("A game's own names are the ones played")
    func ownNames() {
        let named = LocomotionBlend.Clips(gaits: [.init("A_Walk", 1.4)], idle: "A_Idle", rising: "A_Up", falling: "A_Down")
        #expect(LocomotionBlend.choose(airborne: false, rising: false, groundSpeed: 0, clips: named).weights[0].clip == "A_Idle")
        #expect(LocomotionBlend.choose(airborne: true, rising: true, groundSpeed: 0, clips: named).weights[0].clip == "A_Up")
        #expect(LocomotionBlend.choose(airborne: true, rising: false, groundSpeed: 0, clips: named).weights[0].clip == "A_Down")
        #expect(named.strides == ["A_Walk"])
    }
}

/// **Directions** (2026-10-31): a walk and a run that strafe and backpedal, a sprint that only goes forwards — the shape of a
/// soldier pack's eight ways, with a backward clip whose feet land half a cycle from the forward one's.
@Suite("Which way a character's stride goes")
struct LocomotionDirectionTests {

    private static func ways(_ name: String, back: Float) -> [LocomotionBlend.Direction] {
        [.init("\(name)FL", heading: .pi / 4), .init("\(name)L", heading: .pi / 2), .init("\(name)BL", heading: 3 * .pi / 4),
         .init("\(name)B", heading: .pi, phase: back), .init("\(name)BR", heading: -3 * .pi / 4),
         .init("\(name)R", heading: -.pi / 2), .init("\(name)FR", heading: -.pi / 4)]
    }
    private let clips = LocomotionBlend.Clips(gaits: [
        .init("Walk", 2, directions: ways("Walk", back: 0.45)),
        .init("Run", 4, directions: ways("Run", back: 0.53)),
        .init("Sprint", 7.24, phase: 0.78),
    ])

    private func blend(_ speed: Float, _ heading: Float) -> LocomotionBlend {
        LocomotionBlend.choose(airborne: false, rising: false, groundSpeed: speed, heading: heading, clips: clips)
    }
    private func weight(_ b: LocomotionBlend, _ clip: String) -> Float { b.weights.first { $0.clip == clip }?.weight ?? 0 }

    @Test("Straight ahead is the forward clip alone, at any speed")
    func ahead() {
        #expect(blend(2, 0).weights.map(\.clip) == ["Walk"])
        #expect(blend(4.5, 0).weights.map(\.clip) == ["Run"])
        #expect(blend(7, 0).weights.map(\.clip) == ["Sprint"])
    }

    @Test("Each of the eight ways is its own clip, whole")
    func eightWays() {
        let named: [(Float, String)] = [(.pi / 4, "RunFL"), (.pi / 2, "RunL"), (3 * .pi / 4, "RunBL"), (.pi, "RunB"),
                                        (-.pi, "RunB"), (-3 * .pi / 4, "RunBR"), (-.pi / 2, "RunR"), (-.pi / 4, "RunFR"),
                                        (2 * .pi + .pi / 2, "RunL")]
        for (heading, clip) in named {
            let b = blend(4, heading)
            #expect(b.weights.count == 1 && weight(b, clip) == 1, "\(heading) gave \(b.weights.map(\.clip))")
            #expect(b.strideReference == "Run", "the phase is the gait's, whichever way it goes")
        }
    }

    @Test("Between two ways, the two neighbours, weighted by nearness, summing to one")
    func between() {
        let b = blend(4, .pi / 8 * 3)        // 67.5°: three quarters of the way from front-left to left
        #expect(Set(b.weights.map(\.clip)) == ["RunFL", "RunL"])
        #expect(abs(weight(b, "RunL") - 0.5) < 1e-4)
        let c = blend(4, -.pi / 16)          // just right of ahead
        #expect(abs(weight(c, "Run") - 0.75) < 1e-4 && abs(weight(c, "RunFR") - 0.25) < 1e-4)
        // Across behind, where the headings wrap.
        let d = blend(4, .pi + .pi / 8)
        #expect(Set(d.weights.map(\.clip)) == ["RunB", "RunBR"])
        for step in 0..<64 {
            let e = blend(4, Float(step) / 64 * 2 * .pi - .pi)
            #expect(e.weights.count <= 2 && abs(e.weights.reduce(0) { $0 + $1.weight } - 1) < 1e-4)
        }
    }

    @Test("Turning the heading round, the weights move smoothly — no clip jumps in or out")
    func smooth() {
        var last = blend(4, 0)
        for step in 1...720 {
            let next = blend(4, Float(step) / 720 * 2 * .pi)
            for clip in clips.strides {
                #expect(abs(weight(next, clip) - weight(last, clip)) < 0.02, "\(clip) jumped at step \(step)")
            }
            last = next
        }
    }

    /// **The sprint has no backpedal**: played backing away it would moonwalk at speed.
    @Test("Off ahead, a gait with no directions gives way to one that has them")
    func sprintGivesWay() {
        #expect(blend(7, .pi / 8).strideReference == "Sprint", "a little off ahead, the sprint still")
        let back = blend(7, .pi)
        #expect(back.weights.map(\.clip) == ["RunB"])
        #expect(abs(back.pace - 7 / 4) < 1e-4, "the run stretched to cover it")
        #expect(blend(7, .pi / 2).weights.map(\.clip) == ["RunL"])
    }

    @Test("A game with no directions plays its gaits whatever the heading")
    func undirected() {
        let plain = LocomotionBlend.Clips(gaits: [.init("Walk", 1.45), .init("Run", 2.59)])
        let b = LocomotionBlend.choose(airborne: false, rising: false, groundSpeed: 2.5, heading: .pi, clips: plain)
        #expect(b.weights.map(\.clip) == ["Run"])
    }

    @Test("Every direction is a stride, and each is sampled at its gait's and its own offset")
    func offsets() {
        #expect(clips.strides.count == 17)
        #expect(clips.phaseOffset(of: "Walk") == 0)
        #expect(clips.phaseOffset(of: "WalkL") == 0)
        #expect(clips.phaseOffset(of: "WalkB") == 0.45)
        #expect(clips.phaseOffset(of: "RunB") == 0.53)
        #expect(clips.phaseOffset(of: "Sprint") == 0.78)
        #expect(clips.phaseOffset(of: "Idle") == 0)
    }

    @Test("The stride clock runs at the pace over the cycle, holds when still, and wraps")
    func clock() {
        var clock = StrideClock()
        clock.advance(by: 0.2, pace: 1, cycle: 0.8)
        #expect(abs(clock.phase - 0.25) < 1e-5)
        clock.advance(by: 1, pace: 0, cycle: 0.8)
        #expect(abs(clock.phase - 0.25) < 1e-5, "standing still holds the stride where it stopped")
        clock.advance(by: 0.6, pace: 2, cycle: 0.6)
        #expect(abs(clock.phase - 0.25) < 1e-4, "two whole cycles later, the same moment")
        // Each clip at its own offset, in its own seconds: the backward walk half a cycle on, the run in its 0.6 s.
        #expect(abs(clock.time(of: "WalkB", duration: 0.8, in: clips) - 0.7 * 0.8) < 1e-4)
        #expect(abs(clock.time(of: "Sprint", duration: 0.6, in: clips) - 0.03 * 0.6) < 1e-4)
        #expect(abs(StrideClock(phase: -0.25).phase - 0.75) < 1e-6)
    }
}

