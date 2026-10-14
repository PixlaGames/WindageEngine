//
//  PadBindingsTests.swift
//  WindageEngineTests
//

import Foundation
import GameController
import Testing
@testable import WindageEngine

@Suite("Pad bindings")
struct PadBindingsTests {

    @Test("The standard layout is the console convention")
    func standard() {
        let b = PadBindings.standard
        #expect(b[.jump] == .south && b[.crouch] == .east && b[.sprint] == .leftStick)
        #expect(b.actions == [.jump, .crouch, .sprint])
        #expect(b[.forward] == nil, "walking is the stick, not a button")
    }

    @Test("A button in use is swapped, not stolen")
    func swaps() {
        var b = PadBindings.standard
        #expect(b.bind(.crouch, to: .south) == .swapped(with: .jump))
        #expect(b[.crouch] == .south && b[.jump] == .east)
    }

    /// Walking has no button; a game keeps its own buttons free with `reserving:`.
    @Test("A reserved button and a movement action are refused")
    func refusals() {
        var b = PadBindings.standard
        #expect(b.bind(.jump, to: .west, reserving: [.west]) == .refused)
        #expect(b.bind(.forward, to: .north) == .refused)
        #expect(b == .standard)
    }

    /// **Only unbound by default** — a title without a reload leaves Square to the player.
    @Test("A reserved-by-convention face button can be bound when the game does not reserve it")
    func conventionIsNotARule() {
        var b = PadBindings.standard
        #expect(b.bind(.crouch, to: .west) == .bound)
        #expect(b.bind(.jump, to: .rightStick) == .bound, "the engine keeps no button for itself")
    }

    @Test("A game's action is added on its button, and its saved button is found")
    func gameAction() throws {
        let lean = InputAction("lean")
        var b = PadBindings.standard.adding(lean, defaultButton: .leftShoulder)
        #expect(b[lean] == .leftShoulder && b.actions.last == lean)
        b.bind(lean, to: .rightShoulder)
        let read = try JSONDecoder().decode(PadBindings.self, from: try JSONEncoder().encode(b))
        #expect(read[lean] == nil)
        #expect(read.adding(lean, defaultButton: .leftShoulder) == b)
    }

    @Test("Stored by position, and read back")
    func roundTrip() throws {
        var b = PadBindings.standard
        b.bind(.jump, to: .rightShoulder)
        let data = try JSONEncoder().encode(b)
        #expect(String(decoding: data, as: UTF8.self).contains("rightShoulder"))
        #expect(try JSONDecoder().decode(PadBindings.self, from: data) == b)
    }

    @Test("A file with an unknown button or a missing action keeps the rest")
    func tolerant() throws {
        let b = try JSONDecoder().decode(PadBindings.self,
                                         from: Data(#"{ "jump": "paddle4", "crouch": "north" }"#.utf8))
        #expect(b[.jump] == .south)
        #expect(b[.crouch] == .north)
        #expect(b[.sprint] == .leftStick)
    }

    /// A settings file from before pads could be rebound has no `padBindings` at all.
    @Test("Settings from before pad bindings existed still load")
    func olderSettings() throws {
        let s = try JSONDecoder().decode(PlayerSettings.self,
                                         from: Data(#"{ "bindings": { "forward": "I" } }"#.utf8))
        #expect(s.padBindings == .standard)
        #expect(s.bindings[.forward] == KeyCode(named: "I"))
    }
}

/// **The real pad path, with a pad nobody is holding.** `GCController.withExtendedGamepad()` makes one
/// whose buttons are set from code; `useGamepad` points `InputState` at it.
@MainActor
@Suite("Input state with a pad")
struct InputStatePadTests {

    private func rig() -> (InputState, GCExtendedGamepad) {
        let input = InputState()
        let pad = GCController.withExtendedGamepad().extendedGamepad!
        input.useGamepad(pad)
        return (input, pad)
    }

    @Test("A supplied pad counts as connected, and its names come through")
    func connected() {
        let (input, pad) = rig()
        #expect(input.isGamepadConnected)
        #expect(PadButton.south.name(on: pad) == "A", "\(PadButton.south.name(on: pad))")
        #expect(PadButton.south.name(on: nil) == "Cross / A")
    }

    /// **The generic layer**: a game's action on a button, read as held and as a press edge, once.
    @Test("A game's action on a button is held and pressed, once, and not while a menu has the pad")
    func gameAction() {
        let (input, pad) = rig()
        let lean = InputAction("lean")
        input.padBindings = PadBindings.standard.adding(lean, defaultButton: .leftShoulder)
        pad.leftShoulder.setValue(1)
        input.pollFrame()
        input.pollFrame()
        #expect(input.isHeld(lean) && input.isPadHeld(lean) && !input.isKeyHeld(lean))
        #expect(input.consumePresses(of: lean) == 1, "a held button was a press every frame")
        pad.leftShoulder.setValue(0)
        input.pollFrame()
        input.acceptsPadActions = false
        pad.leftShoulder.setValue(1)
        input.pollFrame()
        #expect(!input.isHeld(lean) && input.consumePresses(of: lean) == 0)
    }

    @Test("The triggers are read as axes")
    func triggers() {
        let (input, pad) = rig()
        #expect(input.leftTrigger == 0 && input.rightTrigger == 0)
        pad.leftTrigger.setValue(0.25)
        pad.rightTrigger.setValue(1)
        #expect(input.leftTrigger == 0.25 && input.rightTrigger == 1)
    }

    @Test("The default buttons do what the convention says")
    func defaults() {
        let (input, pad) = rig()
        pad.buttonA.setValue(1)
        #expect(input.isJumpHeld)
        pad.buttonA.setValue(0)
        pad.buttonB.setValue(1)
        input.pollFrame()
        #expect(input.isCrouching)
    }

    @Test("A rebound jump moves to its new button and leaves the old one")
    func reboundJump() {
        let (input, pad) = rig()
        input.padBindings.bind(.jump, to: .rightShoulder)
        pad.buttonA.setValue(1)
        #expect(!input.isJumpHeld, "Cross still jumped")
        pad.buttonA.setValue(0)
        pad.rightShoulder.setValue(1)
        #expect(input.isJumpHeld)
    }

    /// The press edge moves with the binding — a held button does not strobe the crouch.
    @Test("A rebound crouch toggles on its press, once")
    func reboundCrouch() {
        let (input, pad) = rig()
        input.padBindings.bind(.crouch, to: .north)
        pad.buttonB.setValue(1)
        input.pollFrame()
        #expect(!input.isCrouching, "Circle still crouched")
        pad.buttonB.setValue(0)
        pad.buttonY.setValue(1)
        input.pollFrame()
        input.pollFrame()
        #expect(input.isCrouching)
        pad.buttonY.setValue(0)
        input.pollFrame()
        pad.buttonY.setValue(1)
        input.pollFrame()
        #expect(!input.isCrouching)
    }

    @Test("Presses are reported, once, whatever they are bound to")
    func pressesReported() {
        let (input, pad) = rig()
        pad.buttonX.setValue(1)
        input.pollFrame()
        #expect(input.padButtonsPressed == [.west])
        input.pollFrame()
        #expect(input.padButtonsPressed.isEmpty, "a held button was reported as pressed again")
        pad.buttonMenu.setValue(1)
        input.pollFrame()
        #expect(input.wasPadMenuPressed)
    }

    /// **A menu that has the pad must not crouch the player behind it.**
    @Test("With pad actions off, presses are reported and nothing acts")
    func menuHasThePad() {
        let (input, pad) = rig()
        input.acceptsPadActions = false
        pad.buttonB.setValue(1)
        pad.buttonA.setValue(1)
        input.pollFrame()
        #expect(input.padButtonsPressed.contains(.east))
        #expect(!input.isCrouching)
        #expect(!input.isJumpHeld)
    }

    @Test("Sprint follows its binding, and latches")
    func sprintFollows() {
        let (input, pad) = rig()
        input.padBindings.bind(.sprint, to: .leftShoulder)
        pad.leftThumbstick.setValueForXAxis(0, yAxis: 1)
        pad.leftThumbstickButton?.setValue(1)                 // L3 is nothing now
        input.pollFrame()
        #expect(!input.movement.isSprinting)
        pad.leftThumbstickButton?.setValue(0)
        pad.leftShoulder.setValue(1)
        input.pollFrame()
        pad.leftShoulder.setValue(0)
        input.pollFrame()
        #expect(input.movement.isSprinting, "a press latched nothing")
    }

    /// **A second job for the stick click** — through a scope it steadies — must neither keep a sprint
    /// latched nor latch one for later.
    @Test("With the latch off, a latched sprint drops and a press latches nothing")
    func latchOff() {
        let (input, pad) = rig()
        pad.leftThumbstick.setValueForXAxis(0, yAxis: 1)
        pad.leftThumbstickButton?.setValue(1)
        input.pollFrame()
        #expect(input.movement.isSprinting)
        input.padSprintLatches = false
        input.pollFrame()
        #expect(!input.movement.isSprinting)
        pad.leftThumbstickButton?.setValue(0)
        input.pollFrame()
        pad.leftThumbstickButton?.setValue(1)
        input.pollFrame()
        #expect(input.isHeld(.sprint) && !input.movement.isSprinting)
    }

    /// **A worn stick resting at 20%** — past the engine's dead zones, so it walks and turns with
    /// nobody touching it — and the player's own dead zone is what stops it.
    @Test("The player's dead zones decide what a drifting stick does")
    func deadZonesFromSettings() {
        let (input, pad) = rig()
        pad.leftThumbstick.setValueForXAxis(0, yAxis: 0.2)
        pad.rightThumbstick.setValueForXAxis(0.2, yAxis: 0)
        #expect(input.movement.forward > 0, "at the default the drift walks")
        #expect(input.lookRate.x > 0, "at the default the drift turns")

        var settings = PlayerSettings()
        settings.moveDeadzone = 0.25
        settings.lookDeadzone = 0.25
        input.apply(settings)
        #expect(input.movement.forward == 0 && input.lookRate == .zero, "the setting did not stop the drift")

        // **Still a full throw above it**: the response starts at zero at the new edge and reaches full
        // at full deflection, so a larger dead zone costs travel, not top speed.
        pad.rightThumbstick.setValueForXAxis(1, yAxis: 0)
        #expect(abs(input.lookRate.x - 1) < 1e-5)
        pad.rightThumbstick.setValueForXAxis(0.26, yAxis: 0)
        #expect(input.lookRate.x > 0 && input.lookRate.x < 0.001, "just past the edge should barely move: \(input.lookRate.x)")
    }

    @Test("Handing the pad back to the system forgets the supplied one")
    func handBack() {
        let (input, _) = rig()
        input.useGamepad(nil)
        #expect(input.gamepad == GCController.current?.extendedGamepad)
    }
}
