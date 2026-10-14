//
//  SprintLatch.swift
//  WindageEngine
//

/// Sprint engaged by a stick click, which **latches** rather than being held.
///
/// L3 sits under the same thumb that steers. Holding it clamped while pushing the stick around is
/// awkward and tiring, which is why console shooters almost universally toggle it — whereas Shift
/// on a keyboard stays hold, since a little finger resting there costs nothing.
///
/// Extracted from `InputState` so the rule is testable without a controller plugged in.
nonisolated struct SprintLatch: Sendable {

    private(set) var isEngaged = false
    private var wasPressed = false

    /// Below this, the player is not meaningfully pushing forward and the latch expires.
    static let forwardThreshold: Float = 0.1

    /// Call once per frame.
    ///
    /// - Parameters:
    ///   - buttonPressed: current state of the sprint button, not an edge.
    ///   - forwardInput: forward movement axis, used to expire the latch.
    mutating func update(buttonPressed: Bool, forwardInput: Float) {
        // Edge, not level: a button held down across sixty frames must toggle once, not sixty
        // times — which would leave the state effectively random.
        if buttonPressed && !wasPressed {
            isEngaged.toggle()
        }
        wasPressed = buttonPressed

        // Expire on stopping. Otherwise the latch silently survives a halt, and the next time the
        // player nudges forward they sprint when they meant to walk.
        if isEngaged && forwardInput <= SprintLatch.forwardThreshold {
            isEngaged = false
        }
    }

    mutating func disengage() {
        isEngaged = false
        wasPressed = false
    }
}
