//
//  PadBindings.swift
//  WindageEngine
//

import GameController

/// A button on a controller, **by where it is rather than what it is called.**
///
/// The bottom face button is *A* on an Xbox pad, *Cross* on a DualSense and *B* on a Nintendo one —
/// three names for the same thumb position, and the position is what a player's hand learned. Stored
/// that way, a binding made on one pad means the same thing on the next. Shown that way it would be
/// meaningless, so ``name(on:)`` asks the connected pad what it prints on the button.
public nonisolated enum PadButton: String, CaseIterable, Sendable, Codable {
    case south, east, west, north
    case leftShoulder, rightShoulder
    case leftStick, rightStick

    /// What a settings screen shows when no pad is connected to ask: the position's name on the two
    /// pads a Mac player is likeliest to own.
    public var name: String {
        switch self {
        case .south: "Cross / A"
        case .east: "Circle / B"
        case .west: "Square / X"
        case .north: "Triangle / Y"
        case .leftShoulder: "L1 / LB"
        case .rightShoulder: "R1 / RB"
        case .leftStick: "L3"
        case .rightStick: "R3"
        }
    }

    /// What this pad calls the button — "Cross" on a DualSense, "A" on an Xbox pad — or ``name``.
    ///
    /// The framework's names end in " Button", which a settings row does not need.
    public func name(on pad: GCExtendedGamepad?) -> String {
        guard let pad, let local = element(on: pad)?.localizedName else { return name }
        return local.hasSuffix(" Button") ? String(local.dropLast(" Button".count)) : local
    }

    /// The element on a pad. **The framework names them in the Xbox layout** — `buttonA` is the bottom
    /// one on every pad — which is the one place here the letters and the positions line up.
    func element(on pad: GCExtendedGamepad) -> GCControllerButtonInput? {
        switch self {
        case .south: pad.buttonA
        case .east: pad.buttonB
        case .west: pad.buttonX
        case .north: pad.buttonY
        case .leftShoulder: pad.leftShoulder
        case .rightShoulder: pad.rightShoulder
        case .leftStick: pad.leftThumbstickButton
        case .rightStick: pad.rightThumbstickButton
        }
    }
}

/// Which controller button does what.
///
/// ### Only the buttons that are actions
///
/// **The sticks move and look, the triggers are analogue axes, the d-pad steps and the menu button
/// opens a menu.** Those are the console convention and stay where they are — reading the triggers
/// is ``InputState/leftTrigger`` and ``InputState/rightTrigger``. What a player can move are the
/// actions that are buttons: the engine's jump, crouch and sprint in ``standard``, and whatever a
/// game adds with ``adding(_:defaultButton:)``. Walking directions have no button to bind; they are
/// the stick.
///
/// ### Nothing is refused by the engine
///
/// Every face button, shoulder and stick click can take an action. **What a game keeps free is the
/// game's to say**, in `reserving:` — a title that has a reload on Square passes Square — and the
/// convention a title should keep to is written on ``InputState``.
public nonisolated struct PadBindings: Sendable, Equatable, Codable {

    /// The engine's actions on the convention: Cross jumps, Circle crouches, L3 sprints.
    public static let standard = PadBindings(defaults: [.jump: .south, .crouch: .east, .sprint: .leftStick])

    private var table: BindingTable<PadButton>

    /// Bindings for exactly these actions, each starting on its button, in the order a settings screen
    /// should show them. **No two may share a button** — a mistake in the game, which stops it.
    public init(defaults: KeyValuePairs<InputAction, PadButton>) {
        table = BindingTable(defaults: defaults) { _ in false }
    }

    /// These bindings with one more action, on `defaultButton` — or on the button a settings file
    /// already chose for it. **An action they already have is left as it is.** The rules are
    /// ``InputBindings/adding(_:defaultKey:)``'s.
    public func adding(_ action: InputAction, defaultButton: PadButton) -> PadBindings {
        var bindings = self
        bindings.table = table.adding(action, default: defaultButton) { _ in false }
        return bindings
    }

    /// Every action a pad button can be bound to, in the order a settings screen lists them.
    public var actions: [InputAction] { table.actions }

    /// The button for an action, or nil for one that is not a button on a pad.
    public subscript(action: InputAction) -> PadButton? { table[action] }

    public func action(on button: PadButton) -> InputAction? { table.action(on: button) }

    /// Puts an action on a button. **Swapped, not stolen**, for the reason ``InputBindings`` gives.
    /// Refused for an action that is not a button here, or a button in `reserving`.
    @discardableResult
    public mutating func bind(_ action: InputAction, to button: PadButton,
                              reserving: Set<PadButton> = []) -> BindingOutcome {
        table.bind(action, to: button, refusing: reserving.contains)
    }

    // MARK: - Codable

    /// **Tolerant, field by field**, exactly as ``InputBindings`` is and for the same reason: a file
    /// that fails to decode is every binding reset. Read onto ``standard``, with a game's own actions
    /// kept aside until it adds them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stored = ((try? container.decode([String: String].self)) ?? [:]).compactMapValues(PadButton.init(rawValue:))
        table = PadBindings.standard.table.restoring(stored) { _ in false }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(table.stored.mapValues(\.rawValue))
    }
}
