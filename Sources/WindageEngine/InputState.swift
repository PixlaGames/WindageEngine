//
//  InputState.swift
//  WindageEngine
//

import AppKit
import GameController
import simd

/// Collects keyboard, mouse and gamepad into something the simulation can read.
///
/// Everything downstream reads **axes, actions and intents** — ``movement``, ``consumeLook()``,
/// ``lookRate``, ``isHeld(_:)`` — never key codes or button names. That is what lets a keyboard, a
/// DualSense, a rebinding and a recorded replay all drive the same game without any of them knowing
/// about the others.
///
/// ### What the engine reads, and what a game does
///
/// **The engine acts on its own actions only**: the four walking directions, jump, crouch (a latch,
/// ``isCrouching``) and sprint (held on a key, latched on a pad's stick click). **Everything else is a
/// game's action** — fire, aim, reload, a bipod — read through the generic layer: ``isHeld(_:)`` and
/// ``consumePresses(of:)`` for anything bound, ``isLeftMouseHeld``, ``isRightMouseHeld``,
/// ``leftTrigger`` and ``rightTrigger`` for the inputs that are not buttons to bind, ``consumeScroll()``,
/// ``consumeSteps()`` and ``consumeNext()`` for the wheel, the arrows and Tab.
public final class InputState {

    /// ### The control map, and why most of it is not free to reassign
    ///
    /// Console shooters share a layout players arrive already knowing, and a game that ignores it is
    /// not being original — it is being wrong in a way every player notices and nobody reports. The
    /// engine binds its own three actions by it; **a game binding its own should keep to the rest.**
    ///
    /// | control | convention | engine |
    /// |---|---|---|
    /// | Cross (`buttonA`) | jump | jump |
    /// | Circle (`buttonB`) | crouch / prone | crouch latch |
    /// | Square (`buttonX`) | reload | — |
    /// | Triangle (`buttonY`) | weapon swap | — |
    /// | L1 / R1 | equipment, lean / grenade, melee | — |
    /// | L2 / R2 | aim / fire | ``leftTrigger`` / ``rightTrigger`` |
    /// | L3 | sprint | sprint latch |
    /// | d-pad | — | discrete steps, ``consumeSteps()`` |
    /// | menu | pause / settings | ``wasPadMenuPressed`` |
    ///
    /// **Jump, crouch and sprint are defaults**, and a player can move them — see ``padBindings`` and
    /// ``PadBindings``. The sticks, triggers, d-pad and the menu button are the convention and stay put.
    ///
    /// **A game should leave Square and Triangle free even while it has neither a reload nor a second
    /// weapon**, because a player will press them looking for both, and because a title that later
    /// grows either would otherwise have to move something a player had already learned.
    ///
    /// > The framework names the face buttons in the **Xbox** layout, so on a DualSense `buttonY` is
    /// > Triangle and `buttonX` is Square — the opposite of what the letters suggest when you are
    /// > looking at the pad.

    private var pressedKeys: Set<KeyCode> = []
    /// Shift as reported by a window that forwards modifier flags itself — see ``setSprinting(_:)``.
    private var sprintingFromKeyboard = false

    /// Which key does what. **Everything the keyboard drives reads through this**, so a rebinding
    /// takes effect on the next key event with nothing else to update. See ``InputBindings``.
    public var bindings = InputBindings.standard

    /// Stick-click sprint latches on and stays on. See ``SprintLatch``.
    private var sprintLatch = SprintLatch()

    /// Mouse movement seen since the simulation last took it.
    private var pendingLook: SIMD2<Float> = .zero

    /// While captured the cursor is hidden and detached, and the mouse turns the camera.
    public private(set) var isMouseCaptured = false

    /// The mouse buttons, as the window reported them — ``setLeftMouse(_:)``, ``setRightMouse(_:)``.
    /// **Whatever the pointer is doing**: a game that only fires while captured asks
    /// ``isMouseCaptured`` too.
    public private(set) var isLeftMouseHeld = false
    public private(set) var isRightMouseHeld = false

    /// Notches of scroll since the simulation last took them — mouse wheel or trackpad.
    ///
    /// **A notch, not a distance.** A wheel reports a continuous delta and a trackpad reports a
    /// stream of tiny ones; a game that consumes raw deltas gets a magnification that races on a
    /// trackpad and crawls on a wheel. Accumulating to a threshold makes both devices produce the
    /// same discrete clicks.
    private var scrollAccumulator: Float = 0
    private var pendingScroll = 0

    /// How much raw scroll makes one notch. Positive; anything else is the default, 1.
    public var scrollNotch: Float = 1 {
        didSet { if !(scrollNotch.isFinite && scrollNotch > 0) { scrollNotch = 1 } }
    }

    /// Feed raw scroll from the window. Positive is up / away from the user.
    public func addScroll(_ delta: Float) {
        scrollAccumulator += delta
        while scrollAccumulator >= scrollNotch {
            scrollAccumulator -= scrollNotch
            pendingScroll += 1
        }
        while scrollAccumulator <= -scrollNotch {
            scrollAccumulator += scrollNotch
            pendingScroll -= 1
        }
    }

    /// Notches since the last call. **Consumed once per simulation step**, like the presses.
    public func consumeScroll() -> Int {
        defer { pendingScroll = 0 }
        return pendingScroll
    }

    /// Discrete steps requested since the simulation last took them — arrow keys and the d-pad.
    ///
    /// Deliberately generic. A scope turret is the first thing needing "one notch at a time", but so
    /// does a menu, and the engine has no business knowing which.
    private var pendingSteps = SIMD2<Int>(0, 0)
    private var dpadHorizontalWasPressed = false
    private var dpadVerticalWasPressed = false

    /// Presses of each action since the game last took them. See ``consumePresses(of:)``.
    private var pendingPresses: [InputAction: Int] = [:]

    private var connectionObservers: [NSObjectProtocol] = []

    /// Reads nothing from the system until ``start()``: a second one made for a test or a replay
    /// leaves the first's controller discovery alone.
    public init() {}

    /// Starts listening for controllers: logs pads connecting and going away, and looks for wireless
    /// pads woken after launch — pads paired before it are already there. **Once, by the game**,
    /// when it opens its window. Starting again does nothing.
    public func start() {
        guard connectionObservers.isEmpty else { return }
        observeControllers()
    }

    /// Stops what ``start()`` began.
    ///
    /// Not `deinit`: that is nonisolated and may run on any thread, while this state belongs to the
    /// main actor — which Swift 6 refuses to compile, and is right to. **Wireless discovery is the
    /// system's, not this instance's**: stopping it here stops it for the process.
    public func stop() {
        guard !connectionObservers.isEmpty else { return }
        connectionObservers.forEach(NotificationCenter.default.removeObserver)
        connectionObservers.removeAll()
        GCController.stopWirelessControllerDiscovery()
    }

    // MARK: - Gamepad

    /// The active pad, if any. `GCController.current` follows whichever pad was last used, which is
    /// the right behavior when someone puts a controller down and picks up the mouse.
    public var gamepad: GCExtendedGamepad? {
        suppliedGamepad ?? GCController.current?.extendedGamepad
    }

    public var isGamepadConnected: Bool { gamepad != nil }

    /// One the game handed over, which wins over the system's.
    private var suppliedGamepad: GCExtendedGamepad?

    /// Reads this pad instead of whichever one the system says is current — or, given nil, goes back.
    ///
    /// **For a pad nobody is holding**: `GCController.withExtendedGamepad()` makes one whose buttons are
    /// set from code, which is what a replay, a scripted check or a test drives. The system never
    /// makes it `current`, because it is not connected to anything — so without this there would be
    /// no way to put a finger on the real input path without a real finger.
    public func useGamepad(_ pad: GCExtendedGamepad?) {
        suppliedGamepad = pad
        padButtonsDown = []
    }

    /// Which button does what on a pad. **Everything the pad's buttons drive reads through this.**
    public var padBindings = PadBindings.standard

    /// How far each stick must move before it counts. The engine's tuning until a game hands over the
    /// player's — ``apply(_:)``. **Held to ``PlayerSettings/deadzoneRange``**; a value that is not a
    /// number is the default.
    public var moveDeadzone = StickResponse.moveDeadzone {
        didSet { moveDeadzone = InputState.deadzone(moveDeadzone, else: StickResponse.moveDeadzone) }
    }
    public var lookDeadzone = StickResponse.lookDeadzone {
        didSet { lookDeadzone = InputState.deadzone(lookDeadzone, else: StickResponse.lookDeadzone) }
    }

    /// Each stick's response curve — see ``StickResponse/shaped(_:deadzone:exponent:)``. **A game's
    /// tuning**, starting at the engine's. Positive; anything else is the default.
    public var moveExponent = StickResponse.moveExponent {
        didSet { if !(moveExponent.isFinite && moveExponent > 0) { moveExponent = StickResponse.moveExponent } }
    }
    public var lookExponent = StickResponse.lookExponent {
        didSet { if !(lookExponent.isFinite && lookExponent > 0) { lookExponent = StickResponse.lookExponent } }
    }

    /// What ``consumeLook()`` and ``lookRate`` multiply by — the player's sensitivity and invert for
    /// each device, from ``apply(_:)``. `(1, 1)` until then.
    public var mouseLookScale = SIMD2<Float>(1, 1)
    public var stickLookScale = SIMD2<Float>(1, 1)

    /// Hands over everything of the player's settings that input reads: both sets of bindings, the
    /// dead zones, and each device's sensitivity and invert. **The one call**, so a settings screen
    /// cannot set three of them and forget the fourth. Volume, brightness and head bob are not
    /// input's, and stay with the game.
    public func apply(_ settings: PlayerSettings) {
        bindings = settings.bindings
        padBindings = settings.padBindings
        moveDeadzone = settings.moveDeadzone
        lookDeadzone = settings.lookDeadzone
        mouseLookScale = settings.mouseLookScale
        stickLookScale = settings.stickLookScale
    }

    private static func deadzone(_ value: Float, else fallback: Float) -> Float {
        guard value.isFinite else { return fallback }
        return min(max(value, PlayerSettings.deadzoneRange.lowerBound), PlayerSettings.deadzoneRange.upperBound)
    }

    /// Whether the pad's buttons act — the engine's crouch, sprint and jump, and every press a game
    /// reads through ``isHeld(_:)`` or ``consumePresses(of:)``.
    ///
    /// **Off while a game's menu has the pad.** A keyboard key the menu takes never reaches this type;
    /// a pad is polled here, so without a switch a Circle pressed to leave a settings screen would
    /// also crouch the player behind it. The presses are still reported in ``padButtonsPressed``, which
    /// is what the menu reads instead.
    public var acceptsPadActions = true

    /// Whether the pad's sprint button latches a sprint — see ``SprintLatch``.
    ///
    /// **Off while that button means something else.** A game that puts a second job on the stick
    /// click — through a scope it steadies the shot — turns this off for as long as the second job
    /// applies: a latched sprint drops, and pressing the button does not latch one, so the player does
    /// not find a sprint waiting for them when the second job ends. The keyboard's sprint key is held,
    /// not latched, and is not affected.
    public var padSprintLatches = true

    /// Buttons that went down this frame, whatever they are bound to. For a menu, or for a settings
    /// screen waiting for the button a player wants.
    public private(set) var padButtonsPressed: Set<PadButton> = []

    /// Whether the pad's menu button went down this frame.
    public private(set) var wasPadMenuPressed = false

    private var padButtonsDown: Set<PadButton> = []
    private var padMenuWasDown = false

    private func observeControllers() {
        let center = NotificationCenter.default
        connectionObservers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
                let name = (note.object as? GCController)?.vendorName ?? "Controller"
                NSLog("\(Engine.name): \(name) connected")
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { note in
                let name = (note.object as? GCController)?.vendorName ?? "Controller"
                NSLog("\(Engine.name): \(name) disconnected")
            }
        ]
        // Pads paired before launch are already present; this picks up ones woken afterwards.
        GCController.startWirelessControllerDiscovery()
    }

    // MARK: - Actions

    /// Whether an action's key or its pad button is held.
    public func isHeld(_ action: InputAction) -> Bool {
        isKeyHeld(action) || isPadHeld(action)
    }

    /// Whether an action's key is held. **Sprint counts ``setSprinting(_:)``**, the window's own Shift.
    public func isKeyHeld(_ action: InputAction) -> Bool {
        if action == .sprint && sprintingFromKeyboard { return true }
        guard let key = bindings[action] else { return false }
        return pressedKeys.contains(key)
    }

    /// Whether an action's pad button is held — never while ``acceptsPadActions`` is off.
    public func isPadHeld(_ action: InputAction) -> Bool {
        guard acceptsPadActions, let pad = gamepad, let button = padBindings[action] else { return false }
        return button.element(on: pad)?.isPressed ?? false
    }

    /// Presses of an action since the last call — its key going down, or its pad button on the frame
    /// it went down — and clears them.
    ///
    /// **A count, consumed once per simulation step**, like the scroll notches: a press between two
    /// frames is not lost to a frame that ran no steps, and two presses in one frame are two. A toggle
    /// flips on an odd count. A held key's repeats are not presses.
    public func consumePresses(of action: InputAction) -> Int {
        pendingPresses.removeValue(forKey: action) ?? 0
    }

    // MARK: - Events in

    public func keyDown(_ key: KeyCode) {
        // **Only a fresh press counts.** macOS repeats a held key, so without the already-down check,
        // resting a finger on `C` would strobe the crouch at the repeat rate.
        let wasDown = pressedKeys.contains(key)
        pressedKeys.insert(key)
        if !wasDown, let action = bindings.action(on: key) {
            pendingPresses[action, default: 0] += 1
            if action == .crouch { toggleCrouch() }
        }
        if key == .tab && !wasDown { pendingNext += 1 }

        // Arrows step once per press — and again on key repeat, which is what makes holding one
        // down run a turret up rather than requiring forty presses.
        switch key {
        case .up: pendingSteps.y += 1
        case .down: pendingSteps.y -= 1
        case .right: pendingSteps.x += 1
        case .left: pendingSteps.x -= 1
        default: break
        }
    }
    public func keyUp(_ key: KeyCode) { pressedKeys.remove(key) }

    /// A modifier key changed: forward every `flagsChanged` event here with its key and flags.
    ///
    /// **macOS never sends Shift, Control, Option or Command as key presses** — only as a change of
    /// flags — so a window that forwards `keyDown` and `keyUp` alone silently has no Shift at all. The
    /// sample shipped a release like that, with "shift sprint" printed on screen. Routed through
    /// here, a modifier is a key like any other, and can be bound to anything.
    public func flagsChanged(key: KeyCode, modifierFlags: NSEvent.ModifierFlags) {
        guard key.isModifier else { return }
        if key.isDown(inModifierFlags: modifierFlags) { keyDown(key) } else { keyUp(key) }
    }

    /// Presses of **Tab** since the game last took them.
    ///
    /// **A generic "next" edge, not a game verb.** The engine has no idea what a title advances —
    /// a job, a level, a page of a menu — and should not learn. It counts presses; the game decides.
    private var pendingNext = 0

    /// Takes the accumulated presses of Tab and clears them.
    public func consumeNext() -> Int {
        defer { pendingNext = 0 }
        return pendingNext
    }

    /// Toggles the crouch. Called on the key *down* edge, so holding `C` does not strobe it.
    public func toggleCrouch() {
        isCrouching.toggle()
    }

    /// Stands the player up. A game calls this when its own rules end a crouch — a cutscene, a
    /// ladder, a respawn — rather than toggling and hoping it was down.
    public func standUp() {
        isCrouching = false
    }

    /// Sprint held, for a window that reads Shift from its own modifier flags.
    ///
    /// **Prefer ``flagsChanged(key:modifierFlags:)``**, which makes Shift a key like any other
    /// and so rebindable. This remains for a window that already does it this way, and the two
    /// combine: either one held is sprinting.
    public func setSprinting(_ sprinting: Bool) {
        sprintingFromKeyboard = sprinting
    }
    public func setRightMouse(_ held: Bool) { isRightMouseHeld = held }
    public func setLeftMouse(_ held: Bool) { isLeftMouseHeld = held }

    /// How far the left and right triggers are pulled, 0…1 — 0 with no pad. **Axes, not bindings**:
    /// what a pull means, and how far is far enough, is the game's.
    public var leftTrigger: Float { gamepad?.leftTrigger.value ?? 0 }
    public var rightTrigger: Float { gamepad?.rightTrigger.value ?? 0 }

    /// Jump: **Space**, or Cross on a pad. **Held state, not a press** — a controller that jumps
    /// finds the press itself, because it also has to remember one that arrived a moment before
    /// landing, and only it knows when that was.
    ///
    /// Read separately from `MovementInput.vertical`, which the same keys also drive for a title that
    /// flies: `C` pulls that axis down, so holding Space and C together reads as zero there and would
    /// swallow a jump taken from a crouch.
    public var isJumpHeld: Bool { isHeld(.jump) }

    /// Crouch: **C** on the keyboard, Circle on a pad. **Latched — press to crouch, press to stand.**
    ///
    /// **Held was wrong, and this codebase already said so.** The rule it follows is the one written
    /// for sprint: latch what stays on *while your hands are busy with something else*, hold what is
    /// a moment. Crouching is not a moment — you crouch and then walk, aim and look around, so
    /// holding `C` means clamping it against W/A/S/D, the mouse buttons and Shift at once.
    ///
    /// **The worry that made it held does not survive contact with the cost.** A latched posture
    /// that is only steadier would indeed get switched on once and never off — but crouching costs
    /// 55% of your speed and the whole sprint, so what stops it being the default is the trade, not
    /// the button. See `CharacterController.Tuning.crouchedEyeHeight`.
    ///
    /// The same keys previously drove `MovementInput.vertical` for the free-flying camera. That axis
    /// is still there for a title that flies; a game with feet reads ``isJumpHeld`` instead.
    public private(set) var isCrouching = false

    /// **Asking to sprint stands you up — on the press, not while it is held.**
    ///
    /// You cannot sprint crouched, so a sprint *press* while crouched is either ignored or obeyed.
    /// Ignoring it leaves the player pressing a key that does nothing and concluding the game is
    /// stuck; standing up is what they meant, because "go fast" is not an ambiguous intent.
    ///
    /// > **It checked the held state and ran every frame, which made crouching while sprinting
    /// > impossible.** `pollFrame` called this on every tick, so pressing `C` with Shift down
    /// > crouched for exactly one step and stood back up on the next — and since a slide starts on
    /// > the edge of crouching at sprint speed, the slide could never happen either. It reads as the
    /// > key doing nothing. Tests missed it because they drove this type directly and never ran
    /// > `pollFrame`; only stepping the real input path in the running game showed it.
    private func standIfSprinting() {
        let requested = isKeyHeld(.sprint) || sprintLatch.isEngaged
        defer { sprintWasRequested = requested }
        guard requested, !sprintWasRequested else { return }
        isCrouching = false
    }

    private var sprintWasRequested = false

    /// Takes the accumulated discrete steps and clears them.
    public func consumeSteps() -> SIMD2<Int> {
        defer { pendingSteps = SIMD2(0, 0) }
        return pendingSteps
    }

    public func addMouseDelta(x: Float, y: Float) {
        guard isMouseCaptured else { return }
        pendingLook += SIMD2(x, y)
    }

    // MARK: - Capture

    public func setMouseCaptured(_ captured: Bool) {
        guard captured != isMouseCaptured else { return }
        isMouseCaptured = captured

        if captured {
            NSCursor.hide()
            // Detach the pointer from the cursor so it can keep generating deltas at the edge of
            // the screen instead of stopping dead against it.
            CGAssociateMouseAndMouseCursorPosition(0)
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
            pendingLook = .zero
        }
    }

    /// Edge-detects gamepad buttons and expires the sprint latch. Call once per frame, before the
    /// simulation steps.
    ///
    /// **Sprint from the stick click is a toggle, not a hold, and that is deliberate.** L3 is under
    /// the same thumb that steers: holding it clamped while pushing the stick around is awkward and
    /// tiring, which is why console shooters almost universally latch it. Shift on the keyboard
    /// stays hold, because a little finger resting on it costs nothing.
    ///
    /// The latch expires when the player stops moving forward — otherwise it silently persists
    /// through a stop, and the next tap of the stick reads as sprinting when the player meant to
    /// walk.
    public func pollFrame() {
        // **Every button's press edge, once, from one set** — rather than a remembered flag per
        // button, which is what this was while each button meant one fixed thing. Bound buttons move,
        // so the edge has to be found for all of them and then looked up.
        let down = Set(PadButton.allCases.filter { button in
            gamepad.flatMap { button.element(on: $0)?.isPressed } ?? false
        })
        padButtonsPressed = down.subtracting(padButtonsDown)
        padButtonsDown = down
        let menuDown = gamepad?.buttonMenu.isPressed ?? false
        wasPadMenuPressed = menuDown && !padMenuWasDown
        padMenuWasDown = menuDown

        if acceptsPadActions {
            for action in padBindings.actions {
                if let button = padBindings[action], padButtonsPressed.contains(button) {
                    pendingPresses[action, default: 0] += 1
                }
            }
            // Crouch toggles on its press edge, like `C` does. Level-triggering it would strobe the
            // posture for as long as the button is down.
            if let crouch = padBindings[.crouch], padButtonsPressed.contains(crouch) { toggleCrouch() }
        }

        // Sprint stands a crouched player up on the press edge. Evaluated once a frame, here, after
        // the latch below has settled — checking the *held* state instead is what made crouching
        // while sprinting impossible.
        defer { standIfSprinting() }

        // The d-pad steps on the press edge, like the arrow keys — level-triggering it would run a
        // turret to its stop in a third of a second.
        if let pad = gamepad?.dpad {
            let horizontal = pad.right.isPressed || pad.left.isPressed
            let vertical = pad.up.isPressed || pad.down.isPressed
            if horizontal && !dpadHorizontalWasPressed { pendingSteps.x += pad.right.isPressed ? 1 : -1 }
            if vertical && !dpadVerticalWasPressed { pendingSteps.y += pad.up.isPressed ? 1 : -1 }
            dpadHorizontalWasPressed = horizontal
            dpadVerticalWasPressed = vertical
        } else {
            dpadHorizontalWasPressed = false
            dpadVerticalWasPressed = false
        }

        // While the stick click has a second job, feeding the latch would toggle a sprint the player
        // cannot use and would find waiting for them when the job ended. See `padSprintLatches`.
        if padSprintLatches {
            sprintLatch.update(buttonPressed: isPadHeld(.sprint), forwardInput: movement.forward)
        } else {
            sprintLatch.disengage()
        }
    }

    /// Drops every held key and releases the pointer.
    ///
    /// Call this the moment the game window stops being focused. Without it, a key held as focus
    /// leaves stays held forever — no `keyUp` is ever delivered — and the camera slides away on its
    /// own while the player is in another app.
    public func releaseAll() {
        setMouseCaptured(false)
        pressedKeys.removeAll()
        sprintingFromKeyboard = false
        isRightMouseHeld = false
        isLeftMouseHeld = false
        pendingSteps = SIMD2(0, 0)
        dpadHorizontalWasPressed = false
        dpadVerticalWasPressed = false
        sprintLatch.disengage()
        pendingLook = .zero
        padButtonsDown = []
        padButtonsPressed = []
    }

    // MARK: - Simulation reads

    /// Movement intent, from keyboard and left stick together.
    public var movement: MovementInput {
        var input = MovementInput()

        if isKeyHeld(.forward) { input.forward += 1 }
        if isKeyHeld(.back) { input.forward -= 1 }
        if isKeyHeld(.right) { input.strafe += 1 }
        if isKeyHeld(.left) { input.strafe -= 1 }
        if isKeyHeld(.jump) { input.vertical += 1 }
        if isKeyHeld(.crouch) { input.vertical -= 1 }
        input.isSprinting = isKeyHeld(.sprint)

        if let gamepad {
            let stick = StickResponse.shaped(
                SIMD2(gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value),
                deadzone: moveDeadzone, exponent: moveExponent)
            input.strafe += stick.x
            input.forward += stick.y

            // Cross rises. Circle used to drop, matching C — it toggles the crouch now, and a
            // button cannot mean both "go down one metre per second" and "change posture".
            if isPadHeld(.jump) { input.vertical += 1 }
        }

        if sprintLatch.isEngaged && padSprintLatches {
            input.isSprinting = true
        }
        // And never while crouched: that is what the posture costs. See `isCrouching`.
        if isCrouching { input.isSprinting = false }

        // Keyboard and stick can both contribute; clamp so holding both is not faster than either.
        input.forward = min(max(input.forward, -1), 1)
        input.strafe = min(max(input.strafe, -1), 1)
        input.vertical = min(max(input.vertical, -1), 1)
        return input
    }

    /// Takes the accumulated mouse movement, times ``mouseLookScale``, and clears it.
    ///
    /// Consumed exactly once per *frame*, not once per simulation step: the delta is a displacement
    /// that already happened, so applying it to every step of a frame that ran three of them would
    /// turn three times as far.
    public func consumeLook() -> SIMD2<Float> {
        defer { pendingLook = .zero }
        return pendingLook * mouseLookScale
    }

    /// Look **rate** from the right stick, in the range -1...1 per axis, times ``stickLookScale``.
    ///
    /// Unlike the mouse delta this is a held position rather than a displacement, so the camera
    /// scales it by step duration. See `Camera.turn(rate:deltaTime:)`.
    public var lookRate: SIMD2<Float> {
        guard let gamepad else { return .zero }
        return StickResponse.shaped(
            SIMD2(gamepad.rightThumbstick.xAxis.value, gamepad.rightThumbstick.yAxis.value),
            deadzone: lookDeadzone, exponent: lookExponent) * stickLookScale
    }
}
