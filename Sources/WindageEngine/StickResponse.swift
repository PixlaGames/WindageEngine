//
//  StickResponse.swift
//  WindageEngine
//

import simd

/// Turns a raw thumbstick reading into something usable.
///
/// Two problems sit between the hardware and the game, and both are felt immediately if skipped.
public nonisolated enum StickResponse {

    /// Movement tolerates a larger dead area than aiming: drifting forward slowly is harmless,
    /// while an aim that creeps is unusable. **The defaults** — a player sets their own in
    /// ``PlayerSettings/moveDeadzone`` and ``PlayerSettings/lookDeadzone``, which ``InputState`` reads.
    public static let moveDeadzone: Float = 0.16
    public static let lookDeadzone: Float = 0.10

    /// 1 is linear. Above 1 gives fine control near the center and full speed at the edge, which is
    /// what aiming wants; movement stays nearly linear because walking speed should feel direct.
    /// **The defaults** — a game sets its own curve in ``InputState/moveExponent`` and
    /// ``InputState/lookExponent``.
    public static let moveExponent: Float = 1.3
    public static let lookExponent: Float = 2.0

    /// Applies a **radial** deadzone and a response curve, preserving direction.
    ///
    /// **The deadzone is radial, not per-axis, and that distinction is the whole point.** Sticks
    /// never rest at exactly zero — they wander by a few percent — so something must ignore small
    /// readings or the view drifts while untouched. The obvious implementation clamps each axis
    /// separately, which carves a *square* hole out of the center: push diagonally at 45° and both
    /// axes must individually clear the threshold, so the stick feels dead in the corners and
    /// snappy along the axes. Measuring the magnitude instead carves a circle, which is the shape
    /// the stick actually moves in.
    ///
    /// The curve is applied to the magnitude after the deadzone is subtracted and the remainder
    /// rescaled, so the response starts at zero the instant the stick leaves the dead area rather
    /// than jumping to a step.
    ///
    /// **Any dead zone and exponent give a finite answer.** A dead zone is held to `0…0.99` — a
    /// negative one divided a resting stick's zero by zero, and one of 1 divided by nothing at all —
    /// and an exponent that is not a positive number is taken as linear.
    public static func shaped(_ raw: SIMD2<Float>, deadzone: Float, exponent: Float) -> SIMD2<Float> {
        shaped(raw, calibration: StickCalibration(deadzone: deadzone), exponent: exponent)
    }

    /// The same, for a stick that has been measured (``StickCalibration``): its resting point taken off first, then
    /// its own dead zone.
    ///
    /// **Moving the center costs travel on one side, and that has to be given back.** A stick resting 0.1 forward reaches
    /// only 0.9 when pushed forward once the offset is subtracted — so full forward would no longer be full speed, on the
    /// very pad this exists to rescue. Dividing by how far this direction can actually reach makes the edge mean 1 again,
    /// whichever way it leans. Floored well above the dead zone, so a wild measurement cannot divide by nothing.
    public static func shaped(_ raw: SIMD2<Float>, calibration: StickCalibration, exponent: Float) -> SIMD2<Float> {
        let deadzone = calibration.deadzone.isFinite ? min(max(calibration.deadzone, 0), 0.99) : 0
        let exponent = exponent.isFinite && exponent > 0 ? exponent : 1
        let center = SIMD2(calibration.center.x.isFinite ? calibration.center.x : 0,
                           calibration.center.y.isFinite ? calibration.center.y : 0)
        let centred = raw - center
        let magnitude = simd_length(centred)
        guard magnitude > deadzone else { return .zero }
        let direction = centred / magnitude
        let reach = max(1 - simd_dot(center, direction), 0.5)

        // Sticks can read slightly past 1 on the diagonals; clamp so full deflection is full speed
        // and not a little more.
        let rescaled = min((magnitude - deadzone) / max(reach - deadzone, 0.01), 1)
        let curved = pow(rescaled, exponent)
        return direction * curved
    }
}
