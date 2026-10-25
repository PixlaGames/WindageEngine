import Foundation

/// **How large the scene is drawn, against the drawable it is shown in.**
///
/// A base M2 filling a 4K display draws 8.3 million pixels a frame, and alpha-tested foliage makes every one of them
/// expensive; past a width where a frame can no longer be afforded, the scene is drawn smaller and the tone-map pass
/// scales it up with linear filtering. At 4K and a cap of 1920 that is an exact 2×, which looks the same.
///
/// **Only a drawable well past the cap is scaled**, never one just over it: a window 1,960 pixels wide drawn at 1,920
/// and stretched is softer than either, for nothing. Hence two numbers, the width drawn and the width it starts at.
public nonisolated enum SceneScaling: Sendable, Equatable {
    /// The scene is drawn at the drawable's size.
    case native
    /// Drawn `width` pixels across, keeping the drawable's shape, once the drawable is wider than `beyond`.
    case capped(width: Int, beyond: Int)

    /// The scene's size for a drawable of this size, in pixels.
    public func sceneSize(drawableWidth: Int, drawableHeight: Int) -> (width: Int, height: Int) {
        guard case .capped(let width, let beyond) = self, drawableWidth > beyond, drawableWidth > width, width > 0 else {
            return (drawableWidth, drawableHeight)
        }
        let height = (Double(drawableHeight) * Double(width) / Double(drawableWidth)).rounded()
        return (width, max(Int(height), 1))
    }
}
