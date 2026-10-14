//
//  PunctualLightTests.swift
//  WindageEngineTests
//

import Testing
import Foundation
import simd
@testable import WindageEngine

@MainActor
struct PunctualLightTests {

    private func lamp(at position: SIMD3<Float>,
                      color: SIMD3<Float> = SIMD3(repeating: 10),
                      range: Float = 10) -> PunctualLight {
        PunctualLight(position: position, color: color, range: range)
    }

    /// **The range has to be a real edge.** A light still contributing where it is cut off draws a
    /// visible sphere on the floor.
    @Test("A light is exactly nothing at and beyond its range")
    func fallsToNothingAtRange() {
        let light = lamp(at: .zero, range: 10)
        #expect(light.attenuation(at: SIMD3(10, 0, 0)) == 0)
        #expect(light.attenuation(at: SIMD3(40, 0, 0)) == 0)
        #expect(light.attenuation(at: SIMD3(9.5, 0, 0)) > 0)
    }

    @Test("Falloff is inverse-square in the middle of the range")
    func fallsOffInverseSquare() {
        // A long range, so the window is close to 1 and the inverse square dominates.
        let light = lamp(at: .zero, range: 1000)
        let near = light.attenuation(at: SIMD3(2, 0, 0))
        let far = light.attenuation(at: SIMD3(4, 0, 0))
        #expect(abs(near / far - 4) < 0.05, "doubling the distance did not quarter the light")
    }

    @Test("Attenuation only ever decreases with distance")
    func attenuationIsMonotonic() {
        let light = lamp(at: .zero, range: 10)
        var previous = Float.greatestFiniteMagnitude
        for step in 1...200 {
            let value = light.attenuation(at: SIMD3(Float(step) * 0.06, 0, 0))
            #expect(value <= previous + 1e-6)
            previous = value
        }
    }

    /// A fragment exactly at a lamp's position is a division by zero, and the pixel that produces is
    /// not "very bright" — it is NaN, which draws black.
    @Test("Standing inside a light is bright, not NaN")
    func noSingularityAtTheLight() {
        let value = lamp(at: .zero).attenuation(at: .zero)
        #expect(value.isFinite && !value.isNaN)
        #expect(value > 0)
    }

    @Test("A light with no range lights nothing")
    func zeroRangeIsHarmless() {
        let dead = PunctualLight(position: .zero, color: SIMD3(repeating: 10), range: 0)
        #expect(dead.attenuation(at: SIMD3(1, 0, 0)) == 0)
        #expect(dead.attenuation(at: .zero) == 0)
    }

    /// **What the probe this came from had wrong.** It ranked lights by falloff alone, so a candle at
    /// one metre outranked a floodlight at ten — and the floodlight was the one dropped.
    @Test("Influence weighs brightness, not only distance")
    func influenceAccountsForBrightness() {
        let candle = lamp(at: SIMD3(1, 0, 0), color: SIMD3(repeating: 0.3), range: 40)
        let floodlight = lamp(at: SIMD3(10, 0, 0), color: SIMD3(repeating: 400), range: 40)
        #expect(candle.attenuation(at: .zero) > floodlight.attenuation(at: .zero),
                "the candle should be the nearer of the two")
        #expect(floodlight.influence(at: .zero) > candle.influence(at: .zero),
                "the brighter light lost to the nearer one")
    }

    /// Green carries most of perceived brightness and blue almost none, so a blue lamp of the same
    /// numeric magnitude is the one to drop first.
    @Test("Luminance is weighted the way an eye is")
    func luminanceIsPerceptual() {
        let green = PunctualLight.luminance(SIMD3(0, 1, 0))
        let red = PunctualLight.luminance(SIMD3(1, 0, 0))
        let blue = PunctualLight.luminance(SIMD3(0, 0, 1))
        #expect(green > red && red > blue)
        #expect(abs(PunctualLight.luminance(SIMD3(repeating: 1)) - 1) < 1e-5)
    }

    /// A long wall whose centre is out of range still has an end inside it.
    @Test("A light reaches a box by its nearest point, not its centre")
    func reachesByNearestPoint() {
        let wall = BoundingBox(minimum: SIMD3(-20, 0, -0.5), maximum: SIMD3(20, 3, 0.5))
        let light = lamp(at: SIMD3(19, 1, 0), range: 5)
        #expect(light.reaches(wall), "one end of the wall is plainly lit")
        #expect(light.influence(at: wall.closestPoint(to: light.position)) > 0)

        let center = (wall.minimum + wall.maximum) / 2
        #expect(light.influence(at: center) == 0, "the centre is out of range, which is the trap")
    }
}

@MainActor
struct LightSetTests {

    private func lamps(_ count: Int, spacing: Float = 1) -> [PunctualLight] {
        (0..<count).map {
            PunctualLight(position: SIMD3(Float($0) * spacing, 0, 0),
                          color: SIMD3(repeating: 10), range: 100)
        }
    }

    @Test("At most the budget comes back, strongest first")
    func budgetIsRespected() {
        let set = LightSet(lights: lamps(9), budget: 4)
        let chosen = set.affecting(SIMD3(-1, 0, 0))
        #expect(chosen.count == 4)
        // Nearest first: the lights are in a row and the point is off the near end.
        #expect(chosen.map(\.position.x) == [0, 1, 2, 3])
    }

    @Test("Lights out of range are not returned at all")
    func outOfRangeIsDropped() {
        let near = PunctualLight(position: .zero, color: SIMD3(repeating: 10), range: 5)
        let far = PunctualLight(position: SIMD3(100, 0, 0), color: SIMD3(repeating: 10), range: 5)
        let set = LightSet(lights: [near, far], budget: 4)
        #expect(set.affecting(SIMD3(1, 0, 0)) == [near])
        #expect(set.affecting(SIMD3(500, 0, 0)).isEmpty)
    }

    @Test("A budget of zero returns nothing rather than crashing")
    func zeroBudget() {
        #expect(LightSet(lights: lamps(4), budget: 0).affecting(.zero).isEmpty)
        #expect(LightSet(lights: lamps(4), budget: -3).affecting(.zero).isEmpty)
    }

    /// Selection per draw asks which lights matter to *this mesh*, so a light reaching any part of it
    /// counts.
    @Test("A box is lit by anything that reaches any part of it")
    func boxSelection() {
        let wall = BoundingBox(minimum: SIMD3(-20, 0, -0.5), maximum: SIMD3(20, 3, 0.5))
        let atEnd = PunctualLight(position: SIMD3(19, 1, 0), color: SIMD3(repeating: 10), range: 5)
        let miles = PunctualLight(position: SIMD3(500, 1, 0), color: SIMD3(repeating: 10), range: 5)
        let set = LightSet(lights: [atEnd, miles], budget: 4)
        #expect(set.affecting(wall) == [atEnd])
    }

    /// **The probe's real finding.** A hard budget cannot promise a smooth hand-over in an arbitrary
    /// arrangement — but where no more than the budget are meaningfully lit, nothing visible is ever
    /// dropped. That is a condition on the *level*, and this is what makes it checkable before it
    /// ships rather than after a flicker is reported.
    @Test("Over-subscription is detectable, and is a fact about the level")
    func overSubscription() {
        let tight = LightSet(lights: lamps(4, spacing: 0.5), budget: 4)
        #expect(!tight.isOverSubscribed(at: .zero))

        let crowded = LightSet(lights: lamps(7, spacing: 0.5), budget: 4)
        #expect(crowded.isOverSubscribed(at: .zero), "seven lights on top of each other fit a budget of four")

        // Spread far enough apart and the same seven are fine: only a few matter anywhere.
        let spread = LightSet(lights: lamps(7, spacing: 400), budget: 4)
        #expect(!spread.isOverSubscribed(at: .zero))
    }

    @Test("A level can be swept for the places that are over-subscribed")
    func sweepingALevel() {
        let set = LightSet(lights: lamps(7, spacing: 0.5), budget: 4)
        let bad = set.overSubscribedPoints(among: [.zero, SIMD3(1, 0, 0), SIMD3(900, 0, 0)])
        #expect(bad.count == 2)
        #expect(!bad.contains(SIMD3(900, 0, 0)))
    }
}

@MainActor
struct SpotLightTests {

    private func spot(pointing direction: SIMD3<Float>,
                      inner: Float = 15, outer: Float = 30,
                      at position: SIMD3<Float> = .zero,
                      range: Float = 20) -> PunctualLight {
        PunctualLight(position: position, color: SIMD3(repeating: 10), range: range,
                      cone: PunctualLight.Cone(direction: direction,
                                               innerAngle: Float.radians(fromDegrees: inner),
                                               outerAngle: Float.radians(fromDegrees: outer)))
    }

    /// **A point light is a spot with no cone, and the shader must not have to branch on it.** The
    /// angular expression evaluates to exactly 1 with a scale of 0 and an offset of 1.
    @Test("A light with no cone is lit in every direction")
    func noConeLightsEverything() {
        let point = PunctualLight(position: .zero, color: SIMD3(repeating: 10), range: 20)
        for direction in [SIMD3<Float>(1, 0, 0), SIMD3(0, -1, 0), SIMD3(-0.4, 0.8, 0.3)] {
            #expect(point.angularAttenuation(at: direction * 5) == 1)
        }
    }

    @Test("Full brightness on the axis, nothing outside the outer angle")
    func coneEdges() {
        let light = spot(pointing: SIMD3(0, -1, 0), inner: 15, outer: 30)
        #expect(light.angularAttenuation(at: SIMD3(0, -5, 0)) == 1, "the axis is not fully lit")

        // 10° off axis: inside the inner cone, so still full.
        let inner = SIMD3<Float>(sin(Float.radians(fromDegrees: 10)), -cos(Float.radians(fromDegrees: 10)), 0) * 5
        #expect(light.angularAttenuation(at: inner) == 1)

        // 40° off axis: beyond the outer cone.
        let outside = SIMD3<Float>(sin(Float.radians(fromDegrees: 40)), -cos(Float.radians(fromDegrees: 40)), 0) * 5
        #expect(light.angularAttenuation(at: outside) == 0)
        // And behind it entirely.
        #expect(light.angularAttenuation(at: SIMD3(0, 5, 0)) == 0)
    }

    /// A single cutoff gives a hard-edged circle that reads as a stencil rather than as a lamp.
    @Test("The edge falls off rather than cutting")
    func edgeIsSoft() {
        let light = spot(pointing: SIMD3(0, -1, 0), inner: 10, outer: 40)
        func atAngle(_ degrees: Float) -> Float {
            let a = Float.radians(fromDegrees: degrees)
            return light.angularAttenuation(at: SIMD3(sin(a), -cos(a), 0) * 5)
        }
        let values = [atAngle(15), atAngle(25), atAngle(35)]
        #expect(values[0] > values[1] && values[1] > values[2])
        #expect(values.allSatisfy { $0 > 0 && $0 < 1 })
    }

    /// Reversed angles make the scale negative, which lights everything *except* where the lamp
    /// points — a spot that is a shadow.
    @Test("An inner angle wider than the outer is clamped, not inverted")
    func reversedAnglesAreClamped() {
        let light = spot(pointing: SIMD3(0, -1, 0), inner: 60, outer: 20)
        #expect(light.angularAttenuation(at: SIMD3(0, -5, 0)) == 1)
        let outside = SIMD3<Float>(sin(Float.radians(fromDegrees: 50)), -cos(Float.radians(fromDegrees: 50)), 0) * 5
        #expect(light.angularAttenuation(at: outside) == 0, "the cone lit its own outside")
    }

    @Test("A degenerate direction does not produce NaN")
    func degenerateDirection() {
        let light = PunctualLight(position: .zero, color: SIMD3(repeating: 10), range: 10,
                                  cone: PunctualLight.Cone(direction: .zero, innerAngle: 0.2,
                                                           outerAngle: 0.5))
        let value = light.attenuation(at: SIMD3(0, -3, 0))
        #expect(value.isFinite && !value.isNaN)
    }

    // MARK: - Selection, where the error has a direction

    /// **The trap a spot introduces.** The nearest corner of a wall can be outside the cone while the
    /// far end of the same wall is lit. Testing that one point drops the light and the lit end goes
    /// dark — so the test is against the box's bounding sphere, which can say yes wrongly and never
    /// no wrongly.
    @Test("A wall lit at its far end is not dropped because its near corner is dark")
    func farEndOfAWallIsNotDropped() {
        let wall = BoundingBox(minimum: SIMD3(-1, 0, -20), maximum: SIMD3(1, 4, 20))
        // A lamp above the far end, pointing straight down with a narrow cone.
        let light = spot(pointing: SIMD3(0, -1, 0), inner: 8, outer: 16,
                         at: SIMD3(0, 6, 18), range: 12)

        let nearest = wall.closestPoint(to: light.position)
        #expect(light.angularAttenuation(at: nearest) > 0 || light.reaches(wall))
        #expect(light.reaches(wall), "the lit end of the wall was dropped")
    }

    @Test("A spot pointing away from a box does not reach it")
    func pointingAwayDoesNotReach() {
        let box = BoundingBox(minimum: SIMD3(-1, -1, 9), maximum: SIMD3(1, 1, 11))
        let away = spot(pointing: SIMD3(0, 0, -1), inner: 10, outer: 20, range: 30)
        let toward = spot(pointing: SIMD3(0, 0, 1), inner: 10, outer: 20, range: 30)
        #expect(!away.reaches(box))
        #expect(toward.reaches(box))
    }

    @Test("A spot out of range does not reach, whichever way it points")
    func rangeStillApplies() {
        let box = BoundingBox(minimum: SIMD3(-1, -1, 99), maximum: SIMD3(1, 1, 101))
        #expect(!spot(pointing: SIMD3(0, 0, 1), range: 20).reaches(box))
    }

    /// Ranking a spot by its angular term at the box's nearest point would sort a light that matters
    /// to the bottom of the list and out of the budget.
    @Test("A spot that reaches is kept even when the nearest point of the box is unlit")
    func spotSurvivesSelection() {
        let wall = BoundingBox(minimum: SIMD3(-1, 0, -20), maximum: SIMD3(1, 4, 20))
        let light = spot(pointing: SIMD3(0, -1, 0), inner: 8, outer: 16,
                         at: SIMD3(0, 6, 18), range: 12)
        let set = LightSet(lights: [light], budget: 4)
        #expect(set.affecting(wall).count == 1)
    }

    // MARK: - The level format

    @Test("A cone survives a round trip, in degrees")
    func coneRoundTrips() throws {
        let light = spot(pointing: SIMD3(0, -1, 0), inner: 12, outer: 28, at: SIMD3(1, 3, -2))
        let data = try JSONEncoder().encode(light)
        let decoded = try JSONDecoder().decode(PunctualLight.self, from: data)
        let cone = try #require(decoded.cone)
        #expect(abs(Float.degrees(fromRadians: cone.innerAngle) - 12) < 1e-3)
        #expect(abs(Float.degrees(fromRadians: cone.outerAngle) - 28) < 1e-3)
        #expect(simd_distance(cone.direction, SIMD3(0, -1, 0)) < 1e-5)
        #expect(simd_distance(decoded.position, light.position) < 1e-5)
    }

    /// **No direction means no cone**, so an existing level's lamps keep radiating everywhere.
    @Test("A light with no direction stays a point light")
    func noDirectionMeansPoint() throws {
        let json = #"{"position": [0, 2, 0], "color": [1, 1, 1], "intensity": 10, "range": 6}"#
        let light = try JSONDecoder().decode(PunctualLight.self, from: Data(json.utf8))
        #expect(light.cone == nil)
        #expect(light.angularAttenuation(at: SIMD3(0, 5, 0)) == 1)
    }

    /// A light's color is written under `color`.
    @Test("A light is written with its color under color")
    func colorIsWrittenAsColor() throws {
        let light = PunctualLight(position: .zero, color: SIMD3(8, 4, 2), range: 6)
        let written = String(decoding: try JSONEncoder().encode(light), as: UTF8.self)
        #expect(written.contains("\"color\""), "\(written)")
        let read = try JSONDecoder().decode(PunctualLight.self, from: Data(written.utf8))
        #expect(simd_distance(read.color, light.color) < 1e-5)
    }
}

/// **A cone's limits hold however it is set**, not only in `init`. Set past them, an inner angle wider
/// than the outer turned the angular scale negative and lit everything *except* where the lamp pointed.
struct ConeLimitTests {

    private func cone() -> PunctualLight.Cone {
        PunctualLight.Cone(direction: SIMD3(0, -1, 0), innerAngle: 0.3, outerAngle: 0.5)
    }

    @Test("An inner angle set wider than the outer is held to the outer")
    func innerHeldToOuter() {
        var cone = cone()
        cone.innerAngle = 2
        #expect(cone.innerAngle == cone.outerAngle)
        #expect(cone.angleScale > 0)
    }

    @Test("Narrowing the outer angle past the inner narrows the inner with it")
    func outerNarrowsInner() {
        var cone = cone()
        cone.outerAngle = 0.1
        #expect(cone.outerAngle == 0.1)
        #expect(cone.innerAngle == 0.1)
    }

    @Test("Angles set out of range are clamped as init clamps them")
    func anglesClampedOnSet() {
        var cone = cone()
        cone.outerAngle = 10
        #expect(cone.outerAngle == .pi)
        cone.outerAngle = -1
        #expect(cone.outerAngle == 1e-4)
        cone.innerAngle = -1
        #expect(cone.innerAngle == 0)
    }

    @Test("A direction set at any length is normalized, and a zero one points down")
    func directionNormalizedOnSet() {
        var cone = cone()
        cone.direction = SIMD3(0, 0, 5)
        #expect(cone.direction == SIMD3(0, 0, 1))
        cone.direction = .zero
        #expect(cone.direction == SIMD3(0, -1, 0))
    }

    @Test("Set within its limits, a cone is the one init would make")
    func setMatchesInit() {
        var cone = cone()
        cone.outerAngle = 0.7
        cone.innerAngle = 0.4
        cone.direction = SIMD3(1, -1, 0)
        #expect(cone == PunctualLight.Cone(direction: SIMD3(1, -1, 0), innerAngle: 0.4, outerAngle: 0.7))
    }

    @Test("A light set set the same way is equal")
    func lightSetsCompare() {
        let lamp = PunctualLight(position: .zero, color: SIMD3(repeating: 4), range: 6)
        #expect(LightSet(lights: [lamp], budget: 2) == LightSet(lights: [lamp], budget: 2))
        #expect(LightSet(lights: [lamp], budget: 2) != LightSet(lights: [lamp], budget: 3))
        #expect(LightSet(lights: [lamp]).negligibleInfluence == 0.02)
    }
}
