//
//  CrouchLatchTests.swift
//  WindageEngineTests
//

import Testing
@testable import WindageEngine

@MainActor
struct CrouchLatchTests {

    private let c = KeyCode.c

    /// **Latched, not held.** You crouch and then walk, aim, steady and dial turrets — holding the
    /// key would mean clamping it against W/A/S/D, right mouse, Shift and the arrows at once.
    @Test("Crouch stays on after the key is released")
    func itLatches() {
        let input = InputState()
        #expect(!input.isCrouching)

        input.keyDown(c)
        #expect(input.isCrouching)
        input.keyUp(c)
        #expect(input.isCrouching, "it stood up as soon as the key came off")

        input.keyDown(c)
        #expect(!input.isCrouching, "a second press did not stand it up")
    }

    /// **macOS repeats a held key.** Without an edge check, resting a finger on `C` strobes the
    /// posture at the repeat rate.
    @Test("Key repeat does not strobe the posture")
    func repeatsAreIgnored() {
        let input = InputState()
        input.keyDown(c)
        #expect(input.isCrouching)
        for _ in 0..<20 { input.keyDown(c) }      // as the OS would repeat it
        #expect(input.isCrouching, "the repeat toggled it back and forth")
    }

    /// **Asking to sprint stands you up.** Ignoring the key would leave the player pressing
    /// something that does nothing and concluding the game is stuck; "go fast" is not ambiguous.
    @Test("Pressing sprint stands you up rather than doing nothing")
    func sprintingStands() {
        let input = InputState()
        input.keyDown(c)
        #expect(input.isCrouching)

        input.setSprinting(true)
        input.pollFrame()
        #expect(!input.isCrouching, "it stayed crouched when sprint was pressed")
        #expect(input.movement.isSprinting, "and then would not sprint either")
    }

    /// **The bug that made the slide unreachable, and that only the running game showed.**
    ///
    /// Standing up was checked against the *held* state, every frame — so pressing `C` with Shift
    /// down crouched for one step and stood back up on the next, and since a slide starts on the
    /// edge of crouching at sprint speed, no slide could ever begin. It reads as the key doing
    /// nothing. **`pollFrame` is what these tests were missing**: driving the type directly skips
    /// the per-frame path where it happened.
    @Test("Crouching while sprint is held stays crouched")
    func crouchSurvivesHeldSprint() {
        let input = InputState()
        input.setSprinting(true)
        for _ in 0..<10 { input.pollFrame() }
        #expect(!input.isCrouching)

        input.keyDown(c)                 // C, with Shift still down
        #expect(input.isCrouching)
        for _ in 0..<60 { input.pollFrame() }
        #expect(input.isCrouching, "it stood back up on its own while sprint was merely held")
        #expect(!input.movement.isSprinting, "and it is crouch-walking, not sprinting")
    }

    /// Releasing and pressing sprint again is a fresh press, so it stands you up.
    @Test("Re-pressing sprint after a crouch stands you up")
    func aFreshPressStands() {
        let input = InputState()
        input.setSprinting(true)
        input.pollFrame()
        input.keyDown(c)
        for _ in 0..<10 { input.pollFrame() }
        #expect(input.isCrouching)

        input.setSprinting(false)
        input.pollFrame()
        input.setSprinting(true)
        input.pollFrame()
        #expect(!input.isCrouching, "a fresh sprint press did not stand you up")
    }

    /// And while crouched, the movement never reports a sprint — that is what the posture costs.
    @Test("Movement never reports a sprint while crouched")
    func noSprintWhileCrouched() {
        let input = InputState()
        input.keyDown(c)
        // Set the flag directly rather than through `setSprinting`, which stands you up: this pins
        // the *second* guard, so a replay or a pad path cannot sneak a crouched sprint through.
        #expect(input.isCrouching)
        #expect(!input.movement.isSprinting)
    }
}
