import Testing
import simd
import WindageEngine
@testable import WindageSampleCore

/// **What the shipped levels promise about themselves** — checks on the files, not on code.
struct SampleLevelContentTests {

    /// **A brazier carries its own flame, above its rim.** The flame used to be a separate entry in
    /// the level's lights, kept over the brazier only by a test like this one; now the brazier holds
    /// it, and what is left to check is that it is there and not inside the bowl —
    /// The brazier's generator puts the rim at 1.08 m.
    @Test("Every brazier carries a lamp above its rim")
    func braziersCarryLamps() throws {
        let rim: Float = 1.08
        for index in SampleLevel.names.indices {
            let level = try SampleLevel.bundled(index)
            for brazier in level.placements where brazier.mesh == "brazier" {
                let lamp = try #require(brazier.light, "\(SampleLevel.names[index]): a brazier with no lamp")
                #expect(lamp.cone == nil)
                #expect(abs(lamp.position.x) < 1e-4 && abs(lamp.position.z) < 1e-4,
                        "\(SampleLevel.names[index]): the flame is not over the bowl")
                #expect(lamp.position.y > (rim + 0.3) * brazier.scale,
                        "\(SampleLevel.names[index]): the lamp is inside its bowl")
            }
        }
    }

    /// **No lamp floating in the air.** A light that points nowhere and belongs to nothing is exactly
    /// what the ruins had before the braziers — embers out of thin air. Aimed lights stay free: a
    /// spot on a pole the level does not draw is a stage light, and says so by having a cone.
    @Test("Every lamp that points nowhere belongs to something")
    func noFloatingLamps() throws {
        for index in SampleLevel.names.indices {
            let level = try SampleLevel.bundled(index)
            let floating = level.lights.filter { $0.cone == nil }
            #expect(floating.isEmpty, "\(SampleLevel.names[index]): \(floating.map(\.position)) float")
        }
    }

    /// **Every solid names what it is made of, and the sample can make that sound.** A solid with no
    /// surface falls back to stone with a line in the log; one with a surface the sample has no
    /// footsteps for would fall back silently. Both are gaps in the file, and this finds them first.
    @Test("Every solid, and the ground, names a surface the sample has footsteps for")
    func surfacesAreNamedAndHeard() throws {
        for index in SampleLevel.names.indices {
            let level = try SampleLevel.bundled(index)
            #expect(level.groundSurface.map(SampleLevel.footstepSurfaces.contains) == true,
                    "\(level.name) does not say what its ground is")
            for (i, placement) in level.placements.enumerated() where placement.tags.contains("solid") {
                #expect(placement.surface.map(SampleLevel.footstepSurfaces.contains) == true,
                        "\(level.name) #\(i) \(placement.mesh) is '\(placement.surface ?? "nothing")'")
            }
        }
    }

    /// The ruins' landing is boards laid where the stone treads end — the one place underfoot that
    /// changes material without changing shape, which is what the footstep has to follow.
    @Test("The ruins have a wooden landing at the top of stone stairs")
    func woodenLanding() throws {
        let ruins = try SampleLevel.bundled(1)
        // The lintel is cut from the same stone step, laid across two posts — it is not a tread.
        // The lintel and the lift are cut from the same steps — neither is a tread.
        let treads = ruins.placements.filter {
            ($0.mesh == "step" || $0.mesh == "step_wood") && !$0.tags.contains("lintel") && !$0.tags.contains("lift")
        }
        #expect(treads.filter { $0.surface == "wood" }.count == 3)
        #expect(treads.filter { $0.surface == "stone" }.count == 3)
    }

    /// **The lintel is there to be crouched under**: its underside above a crouched body and below a
    /// standing one, so walking under it means crouching and letting go under it means staying down.
    @Test("The ruins' lintel is low enough to need a crouch and high enough to allow one")
    func lintelNeedsACrouch() throws {
        let ruins = try SampleLevel.bundled(1)
        let lintels = ruins.placements.filter { $0.tags.contains("lintel") }
        #expect(lintels.count == 2)
        let tuning = CharacterController.Tuning()
        let crouchedTop = tuning.bodyHeight(for: tuning.crouchedEyeHeight)
        let standingTop = tuning.bodyHeight(for: tuning.eyeHeight)
        for lintel in lintels {
            #expect(lintel.position.y > crouchedTop && lintel.position.y < standingTop,
                    "the lintel's underside at \(lintel.position.y) m should lie between \(crouchedTop) and \(standingTop)")
        }
    }

    /// **The lift joins the ground to the landing**: at rest its top is a step up from the ground, and
    /// at the top of its travel it is level with the wooden landing beside it, so a player can step on
    /// at the bottom and walk off at the top.
    @Test("The ruins' lift rises from a step up to the landing's level")
    func liftReachesTheLanding() throws {
        let ruins = try SampleLevel.bundled(1)
        let lift = try #require(ruins.placements.first { $0.tags.contains("lift") })
        let landing = try #require(ruins.placements.first { $0.mesh == "step_wood" && !$0.tags.contains("lift") })
        let meshHeight: Float = 1                      // step_wood.obj is 1 m tall, standing on y = 0
        let restTop = lift.position.y + meshHeight
        #expect(restTop > 0 && restTop <= CharacterController.Tuning().stepHeight, "a step up from the ground: \(restTop)")
        #expect(abs(restTop + SampleLevel.liftRise - (landing.position.y + meshHeight)) < 1e-4)
        #expect(lift.tags.contains("solid") && lift.surface == "wood")
    }

    @Test("The lift's cycle eases from the bottom to the top and back, and joins up")
    func liftCycle() {
        let t = SampleLevel.self
        #expect(t.liftHeight(at: 0) == 0 && t.liftHeight(at: t.liftCycle - 1e-4) < 1e-3)
        #expect(t.liftHeight(at: t.liftPause + t.liftTravel + 0.1) == t.liftRise)
        #expect(abs(t.liftHeight(at: t.liftPause + t.liftTravel / 2) - t.liftRise / 2) < 1e-4)
        var previous: Float = 0, biggest: Float = 0
        for i in 1...Int(t.liftCycle * 120) {
            let h = t.liftHeight(at: Float(i) / 120)
            biggest = max(biggest, abs(h - previous))
            previous = h
        }
        #expect(biggest < 0.01, "a step of the lift jumped \(biggest) m")
    }

    /// **A fire you can see and not hear reads as a picture of a fire.** Every brazier carries the
    /// crackle, from its coals — which the brazier's generator puts at 0.97 m, domed to 1.0.
    @Test("Every brazier carries a crackle, from its coals")
    func braziersCrackle() throws {
        for index in SampleLevel.names.indices {
            let level = try SampleLevel.bundled(index)
            for brazier in level.placements where brazier.mesh == "brazier" {
                let sound = try #require(brazier.sound, "a silent brazier in \(level.name)")
                #expect(sound.name == "crackle")
                #expect(sound.offset.y > 0.9 && sound.offset.y < 1.2, "the crackle at \(sound.offset.y) m, not the coals")
            }
        }
    }

    /// A turntable is walked onto, not climbed: its top under the step height. `turntable.obj` is
    /// 0.2 m tall, standing on y = 0 (as the turntable is generated).
    @Test("The courtyard's turntable is a step up, solid, and made of stone")
    func turntable() throws {
        let courtyard = try SampleLevel.bundled(0)
        let table = try #require(courtyard.placements.first { $0.tags.contains("turntable") })
        #expect(table.position.y + 0.2 <= CharacterController.Tuning().stepHeight)
        #expect(table.tags.contains("solid") && table.surface == "stone")
    }

    /// **A mover's run is clear**: a slider or a piston pushes the player, and nothing else in a level
    /// can be pushed — so the ground its box sweeps, end to end along its facing, holds no other solid
    /// **that reaches above its base** (the landing a piston rides on does not), and not the spawn. Its
    /// box is taller than a step, so it is pushed against rather than stood on. `box.obj` is a unit cube
    /// centred on x and z, standing on y = 0; `step.obj` and `step_wood.obj` are 1 m tall.
    @Test("Every slider and piston is solid, taller than a step, and runs clear of everything")
    func movers() throws {
        var found = 0
        for index in SampleLevel.names.indices {
            let level = try SampleLevel.bundled(index)
            for mover in level.placements where mover.tags.contains("slider") || mover.tags.contains("piston") {
                found += 1
                #expect(mover.tags.contains("solid") && mover.surface == "wood")
                #expect(mover.scale > CharacterController.Tuning().stepHeight)
                let run = mover.tags.contains("piston") ? SampleLevel.pistonRun : SampleLevel.slideDistance
                let facing = Level.turned(SIMD2(1, 0), by: mover.yaw)
                let start = SIMD2(mover.position.x, mover.position.z), end = start + facing * run
                let half = mover.scale / 2
                let swept = (minX: min(start.x, end.x) - half, maxX: max(start.x, end.x) + half,
                             minZ: min(start.y, end.y) - half, maxZ: max(start.y, end.y) + half)
                for other in level.placements where other.tags.contains("solid") && other != mover
                    && !other.tags.contains("stop") {
                    // How high it reaches, where that is known; anything else counts as tall.
                    let tall: Float? = switch other.mesh {
                    case "box": other.scale
                    case "step", "step_wood": 1 + (other.tags.contains("lift") ? SampleLevel.liftRise : 0)
                    case "turntable": 0.2
                    default: nil
                    }
                    if let tall, other.position.y + tall <= mover.position.y + 1e-4 { continue }
                    // Half its size across and along, where the mesh is known — a body's width more, since
                    // a player squeezed between it and the mover is the case to avoid — and generously
                    // otherwise, as a square of its scale either side plus half a metre.
                    let body = CharacterController.Tuning().radius * 2
                    let size: SIMD2<Float> = switch other.mesh {
                    case "box": SIMD2(repeating: other.scale / 2 * Float(2).squareRoot())     // at any yaw
                    case "step", "step_wood": SIMD2(1.5, 0.5) * other.scale
                    case "turntable": SIMD2(2, 2)
                    default: SIMD2(repeating: other.scale * 1.5)
                    }
                    let reach = size + (tall == nil ? 0.5 : body)
                    let clear = other.position.x + reach.x < swept.minX || other.position.x - reach.x > swept.maxX
                        || other.position.z + reach.y < swept.minZ || other.position.z - reach.y > swept.maxZ
                    #expect(clear, "\(other.mesh) at \(other.position) is in the way of the \(level.name) mover at \(mover.position)")
                }
                for spawn in level.markers(ofKind: "spawn") {
                    let dx = max(swept.minX - spawn.position.x, 0, spawn.position.x - swept.maxX)
                    let dz = max(swept.minZ - spawn.position.z, 0, spawn.position.z - swept.maxZ)
                    #expect((dx * dx + dz * dz).squareRoot() > 1, "the \(level.name) mover runs over the spawn")
                }
            }
        }
        #expect(found == 2, "\(found) movers; the courtyard's slider and the ruins' piston make two")
    }

    /// **The courtyard's stop pins whoever the slider pushes to it**: clear of the slider's own run — it
    /// never touches the slider — but nearer the run's end than a body is wide, so a player pushed there
    /// cannot fit, and the slider must turn back. And off to one side of the run, clear of the push walk
    /// (z 9, since 2026-09-11), so that walk is still pushed the whole way.
    @Test("The courtyard's stop is nearer the slider's end than a body is wide, and clear of it")
    func stop() throws {
        let courtyard = try SampleLevel.bundled(0)
        let slider = try #require(courtyard.placements.first { $0.tags.contains("slider") })
        let stop = try #require(courtyard.placements.first { $0.tags.contains("stop") })
        let endFace = slider.position.x + SampleLevel.slideDistance + slider.scale / 2
        let stopFace = stop.position.x - stop.scale / 2
        let body = CharacterController.Tuning().radius * 2
        #expect(stopFace > endFace, "the slider runs into its stop")
        #expect(stopFace - endFace < body, "a body fits between the slider's end and the stop: \(stopFace - endFace) m")
        // Overlapping the slider's width — or it pins nobody — but not the push walk's body at z 9.
        let sliderZ = (slider.position.z - slider.scale / 2)...(slider.position.z + slider.scale / 2)
        let stopZ = (stop.position.z - stop.scale / 2)...(stop.position.z + stop.scale / 2)
        #expect(sliderZ.overlaps(stopZ))
        #expect(stopZ.upperBound < 9 - body / 2, "the stop reaches the push walk's line")
    }

    /// The ruins' piston stops with its face just past the landing's south edge — so it pushes whoever
    /// stands before it clean off at its full speed, then stops dead.
    @Test("The ruins' piston ends just past the landing's edge")
    func pistonEndsAtTheEdge() throws {
        let ruins = try SampleLevel.bundled(1)
        let piston = try #require(ruins.placements.first { $0.tags.contains("piston") })
        let facing = Level.turned(SIMD2(1, 0), by: piston.yaw)
        let face = piston.position.z + facing.y * SampleLevel.pistonRun - piston.scale / 2
        #expect(abs(facing.y + 1) < 1e-5, "the piston should run along −z")
        #expect(face < -1.5 && face > -1.6, "its face ends at z \(face), the landing's edge is −1.5")
    }
}

@Suite("The sample's slider, as something that can be turned back")
struct SlideRunTests {

    private let step: Float = 1.0 / 120

    /// To a millimetre, not exactly: it and the cycle each sum step lengths in `Float`, one per leg and
    /// one over the whole cycle, and they drift a fraction of a millisecond apart — 0.39 mm at the
    /// slider's speed, measured.
    @Test("Unobstructed, it runs the eased cycle to a millimetre")
    func matchesTheCycle() {
        var run = SampleLevel.SlideRun()
        var clock: Float = 0, worst: Float = 0
        for _ in 0..<Int(2 * SampleLevel.slideCycle / step) {
            _ = run.advance(by: step)
            clock = (clock + step).truncatingRemainder(dividingBy: SampleLevel.slideCycle)
            worst = max(worst, abs(run.offset - SampleLevel.slideOffset(at: clock)))
        }
        #expect(worst < 1e-3, "strayed \(worst) m from the cycle")
    }

    @Test("Turned back going out, it comes home from there and then runs its cycle again")
    func turnsBack() {
        var run = SampleLevel.SlideRun()
        while run.offset < 3 { _ = run.advance(by: step) }
        let at = run.offset
        run.turnBack()
        #expect(run.leg == .back && run.reversals == 1)
        // Home in the share of the travel time the way back is: 4 s × at/5.
        let home = SampleLevel.slideTravel * at / SampleLevel.slideDistance
        var took: Float = 0, last = at
        while run.leg == .back {
            _ = run.advance(by: step)
            took += step
            #expect(run.offset <= last + 1e-6, "went out again on the way home")
            last = run.offset
        }
        #expect(run.offset == 0 && abs(took - home) <= step, "home after \(took) s, the way back takes \(home)")
        // Then waits and goes out as ever.
        for _ in 0..<Int((SampleLevel.slidePause + 1) / step) { _ = run.advance(by: step) }
        #expect(run.leg == .out && run.offset > 0)
    }

    @Test("Coming home or waiting, being told to turn back changes nothing")
    func onlyGoingOut() {
        var run = SampleLevel.SlideRun()
        run.turnBack()
        #expect(run.leg == .waiting && run.reversals == 0)
        while run.leg != .back { _ = run.advance(by: step) }
        run.turnBack()
        #expect(run.reversals == 0)
    }
}
