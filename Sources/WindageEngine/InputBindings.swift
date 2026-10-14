//
//  InputBindings.swift
//  WindageEngine
//

import AppKit
import IOKit.hidsystem

/// A physical key, by its macOS virtual key code.
///
/// **A position on the keyboard, not a letter.** ``w`` is the key where W sits on a US layout and Z
/// sits on an AZERTY one, which is what a game wants for movement: the cluster under the left hand
/// stays under the left hand. The *name* is the US legend, which is what a settings screen shows and
/// what a settings file stores.
///
/// **Named by its statics** — `KeyCode.w`, `.space`, `.leftShift` — or by ``init(named:)`` for a name
/// read from a file or a script. ``init(rawValue:)`` is for a code that arrived in an event.
public nonisolated struct KeyCode: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// The key's legend, or its code if it has none this table knows.
    public var name: String { KeyCode.names[rawValue] ?? "Key \(rawValue)" }
    public var description: String { name }

    /// A key by the name a person would type — `"W"`, `"space"`, `"left shift"`. Case-insensitive.
    public init?(named name: String) {
        let wanted = name.lowercased()
        guard let code = KeyCode.names.first(where: { $0.value.lowercased() == wanted })?.key
                ?? KeyCode.aliases[wanted] else { return nil }
        self.rawValue = code
    }

    /// **Stored by name**, so a settings file says `"forward" : "W"` — something a person can read,
    /// and edit, and not get wrong by one digit.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(UInt16.self) {
            self.rawValue = number
            return
        }
        let name = try container.decode(String.self)
        guard let key = KeyCode(named: name) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "no key named '\(name)'")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if KeyCode.names[rawValue] != nil { try container.encode(name) } else { try container.encode(rawValue) }
    }

    // MARK: - Modifiers

    /// **Shift, Control, Option and Command are keys here, like any other.** macOS does not send them
    /// as key presses at all — they arrive as a change of *modifier flags* — which is how a sample
    /// could print "shift sprint" on screen for a release and have Shift do nothing: its window never
    /// listened for the event that carries it. Treating them as keys is what lets Control be bound to
    /// crouch, which a lot of players expect.
    public var isModifier: Bool { KeyCode.modifierMasks[self] != nil }

    /// The device-specific flag this modifier sets while held, or nil for an ordinary key. What a
    /// replayed key press needs in order to look like the real event.
    public var modifierFlag: NSEvent.ModifierFlags? { KeyCode.modifierMasks[self] }

    /// Whether this modifier is down, given an event's modifier flags.
    ///
    /// **By the device-specific bit, not the generic one.** The generic `.shift` flag is set while
    /// *either* Shift is down, so releasing the left one with the right still held would read as the
    /// left still pressed. The low bits of the flags say which physical key it is — `NSEvent` carries
    /// them in its `modifierFlags` without naming them.
    public func isDown(inModifierFlags flags: NSEvent.ModifierFlags) -> Bool {
        guard let mask = KeyCode.modifierMasks[self] else { return false }
        return !flags.intersection(mask).isEmpty
    }

    /// The device bits, by the names IOKit gives them.
    private static let modifierMasks: [KeyCode: NSEvent.ModifierFlags] = [
        .leftShift: device(NX_DEVICELSHIFTKEYMASK), .rightShift: device(NX_DEVICERSHIFTKEYMASK),
        .leftControl: device(NX_DEVICELCTLKEYMASK), .rightControl: device(NX_DEVICERCTLKEYMASK),
        .leftOption: device(NX_DEVICELALTKEYMASK), .rightOption: device(NX_DEVICERALTKEYMASK),
        .leftCommand: device(NX_DEVICELCMDKEYMASK), .rightCommand: device(NX_DEVICERCMDKEYMASK),
    ]
    private static func device(_ mask: Int32) -> NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: UInt(mask)) }

    // MARK: - The keys, by name

    public static let a = KeyCode(rawValue: 0), b = KeyCode(rawValue: 11), c = KeyCode(rawValue: 8)
    public static let d = KeyCode(rawValue: 2), e = KeyCode(rawValue: 14), f = KeyCode(rawValue: 3)
    public static let g = KeyCode(rawValue: 5), h = KeyCode(rawValue: 4), i = KeyCode(rawValue: 34)
    public static let j = KeyCode(rawValue: 38), k = KeyCode(rawValue: 40), l = KeyCode(rawValue: 37)
    public static let m = KeyCode(rawValue: 46), n = KeyCode(rawValue: 45), o = KeyCode(rawValue: 31)
    public static let p = KeyCode(rawValue: 35), q = KeyCode(rawValue: 12), r = KeyCode(rawValue: 15)
    public static let s = KeyCode(rawValue: 1), t = KeyCode(rawValue: 17), u = KeyCode(rawValue: 32)
    public static let v = KeyCode(rawValue: 9), w = KeyCode(rawValue: 13), x = KeyCode(rawValue: 7)
    public static let y = KeyCode(rawValue: 16), z = KeyCode(rawValue: 6)

    public static let digit0 = KeyCode(rawValue: 29), digit1 = KeyCode(rawValue: 18), digit2 = KeyCode(rawValue: 19)
    public static let digit3 = KeyCode(rawValue: 20), digit4 = KeyCode(rawValue: 21), digit5 = KeyCode(rawValue: 23)
    public static let digit6 = KeyCode(rawValue: 22), digit7 = KeyCode(rawValue: 26), digit8 = KeyCode(rawValue: 28)
    public static let digit9 = KeyCode(rawValue: 25)

    public static let space = KeyCode(rawValue: 49), `return` = KeyCode(rawValue: 36), tab = KeyCode(rawValue: 48)
    public static let escape = KeyCode(rawValue: 53), delete = KeyCode(rawValue: 51), capsLock = KeyCode(rawValue: 57)
    /// The delete that removes forward — fn-Delete on a laptop's keyboard.
    public static let forwardDelete = KeyCode(rawValue: 117)
    public static let grave = KeyCode(rawValue: 50), minus = KeyCode(rawValue: 27), equal = KeyCode(rawValue: 24)
    public static let leftBracket = KeyCode(rawValue: 33), rightBracket = KeyCode(rawValue: 30)
    public static let backslash = KeyCode(rawValue: 42), semicolon = KeyCode(rawValue: 41), quote = KeyCode(rawValue: 39)
    public static let comma = KeyCode(rawValue: 43), period = KeyCode(rawValue: 47), slash = KeyCode(rawValue: 44)

    public static let up = KeyCode(rawValue: 126), down = KeyCode(rawValue: 125)
    public static let left = KeyCode(rawValue: 123), right = KeyCode(rawValue: 124)

    public static let leftShift = KeyCode(rawValue: 56), rightShift = KeyCode(rawValue: 60)
    public static let leftControl = KeyCode(rawValue: 59), rightControl = KeyCode(rawValue: 62)
    public static let leftOption = KeyCode(rawValue: 58), rightOption = KeyCode(rawValue: 61)
    public static let leftCommand = KeyCode(rawValue: 55), rightCommand = KeyCode(rawValue: 54)

    static let names: [UInt16: String] = {
        let legends: [(KeyCode, String)] = [
            (.a, "A"), (.b, "B"), (.c, "C"), (.d, "D"), (.e, "E"), (.f, "F"), (.g, "G"), (.h, "H"),
            (.i, "I"), (.j, "J"), (.k, "K"), (.l, "L"), (.m, "M"), (.n, "N"), (.o, "O"), (.p, "P"),
            (.q, "Q"), (.r, "R"), (.s, "S"), (.t, "T"), (.u, "U"), (.v, "V"), (.w, "W"), (.x, "X"),
            (.y, "Y"), (.z, "Z"),
            (.digit0, "0"), (.digit1, "1"), (.digit2, "2"), (.digit3, "3"), (.digit4, "4"),
            (.digit5, "5"), (.digit6, "6"), (.digit7, "7"), (.digit8, "8"), (.digit9, "9"),
            (.space, "Space"), (.return, "Return"), (.tab, "Tab"), (.escape, "Escape"), (.delete, "Delete"),
            (.forwardDelete, "Forward Delete"), (.capsLock, "Caps Lock"),
            (.grave, "`"), (.minus, "-"), (.equal, "="), (.leftBracket, "["), (.rightBracket, "]"),
            (.backslash, "\\"), (.semicolon, ";"), (.quote, "'"), (.comma, ","), (.period, "."), (.slash, "/"),
            (.up, "Up"), (.down, "Down"), (.left, "Left"), (.right, "Right"),
            (.leftShift, "Left Shift"), (.rightShift, "Right Shift"),
            (.leftControl, "Left Control"), (.rightControl, "Right Control"),
            (.leftOption, "Left Option"), (.rightOption, "Right Option"),
            (.leftCommand, "Left Command"), (.rightCommand, "Right Command"),
        ]
        return Dictionary(uniqueKeysWithValues: legends.map { ($0.0.rawValue, $0.1) })
    }()

    /// Short names a script or a hand-edited file might use.
    private static let aliases: [String: UInt16] = [
        "shift": KeyCode.leftShift.rawValue, "control": KeyCode.leftControl.rawValue,
        "ctrl": KeyCode.leftControl.rawValue, "option": KeyCode.leftOption.rawValue,
        "alt": KeyCode.leftOption.rawValue, "command": KeyCode.leftCommand.rawValue,
        "cmd": KeyCode.leftCommand.rawValue, "enter": KeyCode.return.rawValue,
        "esc": KeyCode.escape.rawValue, "backspace": KeyCode.delete.rawValue,
    ]
}

/// Something a player does, which a key or a pad button can be bound to.
///
/// **Open, not a closed list.** The engine names the actions its own types act on — the four walking
/// directions, jump, crouch and sprint, which ``InputState`` turns into ``MovementInput`` and the
/// crouch latch — and a game names the rest itself:
///
/// ```swift
/// extension InputAction {
///     nonisolated static let reload = InputAction("reload")
/// }
/// ```
///
/// (`nonisolated` because a module built with main-actor isolation by default would otherwise make
/// the constant the main actor's, and bindings are values used anywhere.)
///
/// then gives it a key with ``InputBindings/adding(_:defaultKey:)`` or a button with
/// ``PadBindings/adding(_:defaultButton:)``, and reads it with ``InputState/isHeld(_:)`` or
/// ``InputState/consumePresses(of:)``. **The name is what a settings file stores**, so it is a stable
/// identifier, not something a player reads: what a settings screen calls an action is the game's to
/// say, in the player's language.
public nonisolated struct InputAction: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The identifier a settings file stores the action's binding under.
    public let name: String

    public init(_ name: String) { self.name = name }

    public var description: String { name }

    public init(from decoder: Decoder) throws {
        name = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }

    public static let forward = InputAction("forward")
    public static let back = InputAction("back")
    public static let left = InputAction("left")
    public static let right = InputAction("right")
    public static let jump = InputAction("jump")
    public static let crouch = InputAction("crouch")
    public static let sprint = InputAction("sprint")
}

/// What putting an action on a key or a button did — see ``InputBindings/bind(_:to:reserving:)`` and
/// ``PadBindings/bind(_:to:reserving:)``.
public nonisolated enum BindingOutcome: Equatable, Sendable {
    /// The key was free, or already this action's.
    case bound
    /// The key belonged to another action, which now has this action's old key.
    case swapped(with: InputAction)
    /// Not allowed — a key nothing may be bound to, one the game reserved, or an action these
    /// bindings do not have.
    case refused
}

/// The rules ``InputBindings`` and ``PadBindings`` share — one action per input, swapped not stolen,
/// tolerant of a file from another build — for keys and buttons alike.
nonisolated struct BindingTable<Input: Hashable & Sendable>: Sendable, Equatable {

    /// In the order they were given, which is the order a settings screen lists them in.
    private(set) var actions: [InputAction]
    private var defaults: [InputAction: Input]
    private var map: [InputAction: Input]
    /// Bindings a file held for actions this table did not have when it was read — kept, so a game
    /// that adds its own actions after loading gets the player's choices back, and written out again
    /// so a build without those actions does not erase them.
    private var unclaimed: [String: Input] = [:]

    init(defaults: KeyValuePairs<InputAction, Input>, isFixed: (Input) -> Bool) {
        actions = defaults.map(\.key)
        precondition(Set(actions).count == actions.count, "an action is listed twice")
        self.defaults = Dictionary(uniqueKeysWithValues: defaults.map { ($0.key, $0.value) })
        precondition(Set(self.defaults.values).count == self.defaults.count, "two actions share a default")
        precondition(!self.defaults.values.contains(where: isFixed), "a default is an input nothing may be bound to")
        map = self.defaults
    }

    subscript(action: InputAction) -> Input? { map[action] }

    func action(on input: Input) -> InputAction? {
        actions.first { map[$0] == input }
    }

    mutating func bind(_ action: InputAction, to input: Input, refusing: (Input) -> Bool) -> BindingOutcome {
        guard let previous = map[action], !refusing(input) else { return .refused }
        guard previous != input else { return .bound }
        if let other = self.action(on: input) {
            map[other] = previous
            map[action] = input
            return .swapped(with: other)
        }
        map[action] = input
        return .bound
    }

    func adding(_ action: InputAction, default input: Input, isFixed: (Input) -> Bool) -> BindingTable {
        guard map[action] == nil else { return self }
        precondition(!isFixed(input), "\(action)'s default is an input nothing may be bound to")
        precondition(!defaults.values.contains(input), "\(action)'s default is another action's default")
        var table = self
        table.actions.append(action)
        table.defaults[action] = input
        let taken = Set(map.values)
        if let saved = table.unclaimed.removeValue(forKey: action.name), !taken.contains(saved) {
            table.map[action] = saved
        } else if !taken.contains(input) {
            table.map[action] = input
        } else {
            // The player put another action on this one's default. Nothing is left that every action
            // can have without sharing — the same last resort as a file that cannot be honoured.
            table.map = table.defaults
        }
        return table
    }

    /// The table with a file's choices applied over its defaults. See ``InputBindings``' decoding.
    func restoring(_ stored: [String: Input], isFixed: (Input) -> Bool) -> BindingTable {
        var table = self
        var map = defaults
        var taken = Set<Input>()
        for action in actions {
            if let input = stored[action.name], !isFixed(input), !taken.contains(input) {
                map[action] = input
            }
            taken.insert(map[action]!)
        }
        // A fallback can still collide with a key an earlier action took from the file.
        if Set(map.values).count != map.count { map = defaults }
        table.map = map
        let known = Set(actions.map(\.name))
        table.unclaimed = stored.filter { !known.contains($0.key) && !isFixed($0.value) }
        return table
    }

    /// What a file stores: every binding by its action's name, the unclaimed ones included.
    var stored: [String: Input] {
        unclaimed.merging(map.map { ($0.key.name, $0.value) }) { _, bound in bound }
    }
}

/// Which key does what, and the rules for changing it.
///
/// ### The engine's actions, and a game's
///
/// ``standard`` binds the actions the engine itself acts on — the four directions, jump, crouch and
/// sprint — to the layout every player arrives knowing. **A game adds its own** with
/// ``adding(_:defaultKey:)``, and from then on they rebind, swap and save exactly as the engine's do.
///
/// ### What can be rebound, and what cannot
///
/// **Every action can be. Escape, Tab and the arrows cannot be bound to**, and are refused rather
/// than accepted and broken:
///
/// - **Escape is the way out.** It releases the pointer. A player who binds it to jump has no way to
///   get their mouse back, and cannot open the screen that would undo it.
/// - **Tab and the arrows are the engine's generic "next" and "step"**, which a game uses for menus
///   and turrets. Binding forward to Up would move the player *and* step whatever the game has on
///   the arrows.
///
/// A game adds its own keys to the refused set when it binds — see ``bind(_:to:reserving:)`` — because
/// **a key the game consumes first is a key the binding never sees**: in the sample, P pauses, so a
/// jump bound to P would pause the game instead.
///
/// ### One key per action
///
/// A primary and a secondary per action is common on PC and doubles every question below. One key
/// per action is enough to answer the one that matters — *can I put this where my hand is* — and a
/// second slot can arrive when a title asks for it.
public nonisolated struct InputBindings: Sendable, Equatable, Codable {

    /// Keys nothing may be bound to. See the type's notes.
    public static let fixed: Set<KeyCode> = [.escape, .tab, .up, .down, .left, .right]

    /// The engine's actions, on the layout every player arrives knowing.
    public static let standard = InputBindings(defaults: [
        .forward: .w, .back: .s, .left: .a, .right: .d,
        .jump: .space, .crouch: .c, .sprint: .leftShift,
    ])

    private var table: BindingTable<KeyCode>

    /// Bindings for exactly these actions, each starting on its key, listed in the order a settings
    /// screen should show them. **No two may share a key, and none may be one of ``fixed``**: that is
    /// a mistake in the game, and stops it.
    public init(defaults: KeyValuePairs<InputAction, KeyCode>) {
        table = BindingTable(defaults: defaults, isFixed: InputBindings.fixed.contains)
    }

    /// These bindings with one more action, on `defaultKey` — or, when a settings file already chose a
    /// key for it, on that. **An action they already have is left as it is.**
    ///
    /// A game adds its own actions after loading the player's settings, and that order is the point:
    /// the file's choice for an action the engine has never heard of is kept until the game says what
    /// the action is. A player who put another action on this one's default leaves nothing every
    /// action can have, and the bindings go back to their defaults — the rule a file follows.
    public func adding(_ action: InputAction, defaultKey: KeyCode) -> InputBindings {
        var bindings = self
        bindings.table = table.adding(action, default: defaultKey, isFixed: InputBindings.fixed.contains)
        return bindings
    }

    /// Every action, in the order a settings screen lists them.
    public var actions: [InputAction] { table.actions }

    /// The key an action is on, or nil for an action these bindings do not have.
    public subscript(action: InputAction) -> KeyCode? { table[action] }

    /// The action on a key, if any.
    public func action(on key: KeyCode) -> InputAction? { table.action(on: key) }

    /// Puts an action on a key.
    ///
    /// **A key already in use is swapped, not stolen.** Taking W for jump and leaving forward with
    /// nothing is a player who cannot walk and does not know why; swapping gives forward jump's old
    /// key, so every action still has one. The outcome says which, so a settings screen can tell them.
    ///
    /// - Parameter reserving: keys the game consumes itself — its pause key, its menu key. Refused,
    ///   along with ``fixed``.
    @discardableResult
    public mutating func bind(_ action: InputAction, to key: KeyCode, reserving: Set<KeyCode> = []) -> BindingOutcome {
        table.bind(action, to: key) { InputBindings.fixed.contains($0) || reserving.contains($0) }
    }

    // MARK: - Codable

    /// **Tolerant, and it has to be.** `SaveStore` hands back nothing for a file it cannot decode, and
    /// for settings nothing means *everything reset*: a player who rebound eight keys loses all eight
    /// because a later build added a ninth. So a missing action takes its default, a key name this
    /// build does not know falls back — and a file where two actions share a key, which only a hand
    /// edit can produce, falls back for the second.
    ///
    /// **Read onto ``standard``.** An action the file names and the engine does not — a game's own — is
    /// kept aside, and becomes that action's key when the game adds it with ``adding(_:defaultKey:)``.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Each entry on its own: a single key name this build does not know must cost that one
        // binding, not the whole dictionary.
        let stored = ((try? container.decode([String: Lenient].self)) ?? [:]).compactMapValues(\.key)
        table = InputBindings.standard.table.restoring(stored, isFixed: InputBindings.fixed.contains)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(table.stored)
    }

    /// A key that decodes to nothing rather than failing.
    private struct Lenient: Decodable {
        let key: KeyCode?
        init(from decoder: Decoder) throws { key = try? KeyCode(from: decoder) }
    }
}

/// What a player sets once and expects to find set again.
///
/// **The engine's share of a settings screen**: the things every first-person game has and none
/// should reinvent. A game with more — a field of view, a difficulty, subtitles — keeps them beside
/// this rather than inside it.
public nonisolated struct PlayerSettings: Sendable, Equatable, Codable {

    /// Which key does what — the engine's actions and whichever the game added. See ``InputBindings``.
    public var bindings: InputBindings

    /// Which controller button does what. See ``PadBindings``.
    public var padBindings: PadBindings

    /// A multiplier on how far a mouse movement turns the view. 1 is the engine's tuning.
    ///
    /// ### Two sensitivities, because one number cannot suit both
    ///
    /// **A mouse is a displacement and a stick is a rate** (see ``Camera/look(mouseDelta:)`` and
    /// ``Camera/turn(rate:deltaTime:)``), and a player's comfortable setting for one says nothing
    /// about the other. With one multiplier a player who uses both — a pad on the sofa, a mouse at
    /// the desk — had to choose which device to leave wrong. Every shooter on a console and a PC
    /// separates them for that reason.
    public var mouseSensitivity: Float = 1 {
        didSet { mouseSensitivity = PlayerSettings.clamp(mouseSensitivity, PlayerSettings.sensitivityRange, 1) }
    }

    /// A multiplier on how fast a held stick turns the view. 1 is the engine's tuning.
    public var stickSensitivity: Float = 1 {
        didSet { stickSensitivity = PlayerSettings.clamp(stickSensitivity, PlayerSettings.sensitivityRange, 1) }
    }

    /// Pushing the mouse forward looks down. **A setting rather than a preference someone can argue
    /// out of the game**, because the players who want it cannot play without it.
    ///
    /// **Per device**, because the convention differs by device: flight-trained players often invert
    /// a stick and not a mouse, and a single switch made them pick one to get wrong.
    public var invertMouse = false

    /// Pushing the look stick up looks down.
    public var invertStick = false

    /// How far each stick must move before it counts, 0…0.5 of its travel.
    ///
    /// **A worn stick drifts**: it rests a few percent off center, and past the dead zone that is a
    /// view creeping round or a player walking off with nobody touching anything. The only fix a
    /// player has without this is a new controller. The defaults are the engine's tuning — movement
    /// tolerates more dead area than aiming, because drifting forward slowly is harmless and an aim
    /// that creeps is not. **The response still starts from zero at the edge** of whatever dead zone
    /// is set, and still reaches full at full deflection; see ``StickResponse/shaped(_:deadzone:exponent:)``.
    public var moveDeadzone: Float = StickResponse.moveDeadzone {
        didSet { moveDeadzone = PlayerSettings.clamp(moveDeadzone, PlayerSettings.deadzoneRange, StickResponse.moveDeadzone) }
    }
    public var lookDeadzone: Float = StickResponse.lookDeadzone {
        didSet { lookDeadzone = PlayerSettings.clamp(lookDeadzone, PlayerSettings.deadzoneRange, StickResponse.lookDeadzone) }
    }

    /// Half the stick is the most a dead zone may take: past that, what is left is too short a
    /// throw to control anything with.
    public static let deadzoneRange: ClosedRange<Float> = 0...0.5

    /// How much of the head bob to show, 0…1 — **0 is off**. Multiplies ``CharacterController/headBob``.
    ///
    /// **Stored under `headBob`**, the name it had before the API audit, so a settings file keeps it.
    ///
    /// **An amount rather than a switch, with off at the bottom of it.** Bob is a known cause of
    /// motion sickness, so off has to exist and be easy to find; but most players who find the full
    /// bob too much want less of it rather than none.
    public var headBobAmount: Float = 1 {
        didSet { headBobAmount = PlayerSettings.clamp(headBobAmount, 0...1, 1) }
    }

    /// Everything the game plays, 0…1.
    public var volume: Float = 0.8 {
        didSet { volume = PlayerSettings.clamp(volume, 0...1, 0.8) }
    }

    /// The sounds places make — ``AudioEngine/loopVolume`` — 0…1, under ``volume``. **Separate
    /// because a player who finds a fire too loud should not lose their footsteps turning it down.**
    public var ambienceVolume: Float = 1 {
        didSet { ambienceVolume = PlayerSettings.clamp(ambienceVolume, 0...1, 1) }
    }

    /// Stops added to the game's own exposure. **The player's dial on top of the game's**, so a level
    /// authored at −0.5 stays −0.5 relative to itself, and a player on a dim screen lifts all of them.
    public var brightness: Float = 0 {
        didSet { brightness = PlayerSettings.clamp(brightness, PlayerSettings.brightnessRange, 0) }
    }

    public static let sensitivityRange: ClosedRange<Float> = 0.1...5
    public static let brightnessRange: ClosedRange<Float> = -2...2

    /// The defaults, with these bindings. **A game with actions of its own passes its bindings here**,
    /// so its defaults — and "reset to defaults" — include them.
    public init(bindings: InputBindings = .standard, padBindings: PadBindings = .standard) {
        self.bindings = bindings
        self.padBindings = padBindings
    }

    /// What a mouse delta is multiplied by on its way to ``Camera/look(mouseDelta:)`` — by
    /// ``InputState/consumeLook()``, once ``InputState/apply(_:)`` has handed it over.
    public var mouseLookScale: SIMD2<Float> {
        SIMD2(mouseSensitivity, invertMouse ? -mouseSensitivity : mouseSensitivity)
    }

    /// What a stick's look rate is multiplied by on its way to ``Camera/turn(rate:deltaTime:)`` — by
    /// ``InputState/lookRate``, once ``InputState/apply(_:)`` has handed it over.
    public var stickLookScale: SIMD2<Float> {
        SIMD2(stickSensitivity, invertStick ? -stickSensitivity : stickSensitivity)
    }

    private static func clamp(_ value: Float, _ range: ClosedRange<Float>, _ fallback: Float) -> Float {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    private enum CodingKeys: String, CodingKey {
        case bindings, padBindings, mouseSensitivity, stickSensitivity, invertMouse, invertStick
        case moveDeadzone, lookDeadzone, volume, ambienceVolume, brightness
        case headBobAmount = "headBob"
        /// Read, never written: one sensitivity and one invert for both devices, before 2026-09-11.
        case lookSensitivity, invertLook
    }

    /// **Every field optional**, for the reason ``InputBindings`` gives: a settings file from an
    /// older build must load into a newer one with everything it did say intact.
    ///
    /// **A file from before the per-device settings has one sensitivity and one invert**, and both devices inherit
    /// them — that is what the player had, on both, the last time they played. A device's own key
    /// wins where a file has both.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bindings = (try? c.decodeIfPresent(InputBindings.self, forKey: .bindings)) ?? .standard
        padBindings = (try? c.decodeIfPresent(PadBindings.self, forKey: .padBindings)) ?? .standard
        let range = PlayerSettings.sensitivityRange
        let sharedSensitivity = (try? c.decodeIfPresent(Float.self, forKey: .lookSensitivity)) ?? 1
        let sharedInvert = (try? c.decodeIfPresent(Bool.self, forKey: .invertLook)) ?? false
        mouseSensitivity = PlayerSettings.clamp(
            (try? c.decodeIfPresent(Float.self, forKey: .mouseSensitivity)) ?? sharedSensitivity, range, 1)
        stickSensitivity = PlayerSettings.clamp(
            (try? c.decodeIfPresent(Float.self, forKey: .stickSensitivity)) ?? sharedSensitivity, range, 1)
        invertMouse = (try? c.decodeIfPresent(Bool.self, forKey: .invertMouse)) ?? sharedInvert
        invertStick = (try? c.decodeIfPresent(Bool.self, forKey: .invertStick)) ?? sharedInvert
        moveDeadzone = PlayerSettings.clamp((try? c.decodeIfPresent(Float.self, forKey: .moveDeadzone))
            ?? StickResponse.moveDeadzone, PlayerSettings.deadzoneRange, StickResponse.moveDeadzone)
        lookDeadzone = PlayerSettings.clamp((try? c.decodeIfPresent(Float.self, forKey: .lookDeadzone))
            ?? StickResponse.lookDeadzone, PlayerSettings.deadzoneRange, StickResponse.lookDeadzone)
        headBobAmount = PlayerSettings.clamp(
            (try? c.decodeIfPresent(Float.self, forKey: .headBobAmount)) ?? 1, 0...1, 1)
        volume = PlayerSettings.clamp((try? c.decodeIfPresent(Float.self, forKey: .volume)) ?? 0.8, 0...1, 0.8)
        ambienceVolume = PlayerSettings.clamp(
            (try? c.decodeIfPresent(Float.self, forKey: .ambienceVolume)) ?? 1, 0...1, 1)
        brightness = PlayerSettings.clamp(
            (try? c.decodeIfPresent(Float.self, forKey: .brightness)) ?? 0, PlayerSettings.brightnessRange, 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bindings, forKey: .bindings)
        try c.encode(padBindings, forKey: .padBindings)
        try c.encode(mouseSensitivity, forKey: .mouseSensitivity)
        try c.encode(stickSensitivity, forKey: .stickSensitivity)
        try c.encode(invertMouse, forKey: .invertMouse)
        try c.encode(invertStick, forKey: .invertStick)
        try c.encode(moveDeadzone, forKey: .moveDeadzone)
        try c.encode(lookDeadzone, forKey: .lookDeadzone)
        try c.encode(headBobAmount, forKey: .headBobAmount)
        try c.encode(volume, forKey: .volume)
        try c.encode(ambienceVolume, forKey: .ambienceVolume)
        try c.encode(brightness, forKey: .brightness)
    }
}
