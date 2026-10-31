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
