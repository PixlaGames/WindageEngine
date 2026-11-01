//
//  HoldPress.swift
//  WindageEngine
//

/// **A button held down for a moment, acting once**: holster a weapon, open a door, revive a friend.
///
/// Console shooters put a second action on a face button by holding it, so a tap keeps its own — a
/// tap of Triangle swaps weapons, holding it puts the weapon away. The hold acts **once**, as soon as
/// it has lasted ``duration``, while the button is still down; letting go sooner acts not at all, and
/// the button must come up before it can act again. Stepped with the simulation, so the moment is the
/// same at any frame rate; ``progress`` is there for a ring that fills while the player holds.
public nonisolated struct HoldPress: Sendable, Equatable {

    /// Seconds the button must stay down. A third of a second reads as deliberate without feeling slow.
    public var duration: Float
    /// Seconds it has been down, or nil while it is up.
    public private(set) var heldFor: Float?
    /// Whether this hold has acted already — the button has to come up first.
    public private(set) var hasActed = false

    public init(duration: Float = 0.3) {
        self.duration = duration
    }

    /// 0…1 toward acting while held and not yet acted; 0 otherwise.
    public var progress: Float {
        guard let heldFor, !hasActed, duration > 0 else { return 0 }
        return min(heldFor / duration, 1)
    }

    /// One step. Returns true on the step the hold reaches ``duration``, and on no other.
    ///
    /// - Parameter isHeld: whether the button is down now — its level, not an edge.
    public mutating func step(isHeld: Bool, deltaTime: Float) -> Bool {
        guard isHeld else {
            heldFor = nil
            hasActed = false
            return false
        }
        let now = (heldFor ?? 0) + deltaTime
        heldFor = now
        guard !hasActed, now >= duration else { return false }
        hasActed = true
        return true
    }

    /// Forgets a hold under way — the player died, a menu opened — so it must start again from up: a
    /// button still under the thumb does not act the moment play resumes.
    public mutating func cancel() {
        if heldFor != nil { hasActed = true }
    }
}
