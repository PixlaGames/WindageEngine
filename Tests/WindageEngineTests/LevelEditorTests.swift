import Testing
import Foundation
import simd
@testable import WindageEngine

/// **All of it runs with no window**, which is the reason the editing lives in the engine rather
/// than in the viewport that draws it: an editor testable only by clicking is an editor nobody tests.
struct LevelEditorTests {

    private func editor() -> LevelEditor {
        LevelEditor(level: Level(name: "test", placements: [
            Level.Placement(mesh: "a", position: SIMD3(0, 0, 0)),
            Level.Placement(mesh: "b", position: SIMD3(10, 0, 0), yaw: 1, scale: 2),
            Level.Placement(mesh: "c", position: SIMD3(20, 0, 0)),
        ]))
    }

    @Test("Nothing happens without a selection")
    func operationsNeedASelection() {
        var editor = self.editor()
        let before = editor.level
        editor.move(by: SIMD3(1, 0, 0))
        editor.rotate(by: 1)
        editor.scale(by: 2)
        editor.delete()
        #expect(editor.level == before)
        #expect(!editor.isDirty, "an operation that did nothing must not claim unsaved changes")
    }

    @Test("Selecting out of range selects nothing rather than trapping")
    func selectionIsBoundsChecked() {
        var editor = self.editor()
        editor.select(99)
        #expect(editor.selection == nil)
        editor.select(-1)
        #expect(editor.selection == nil)
        editor.select(1)
        #expect(editor.selected?.mesh == "b")
    }

    @Test("Move, rotate and scale change only the selection")
    func operationsAffectOnlyTheSelection() {
        var editor = self.editor()
        editor.select(1)
        editor.move(by: SIMD3(0, 3, 0))
        editor.rotate(by: 0.5)
        editor.scale(by: 2)
        #expect(editor.selected?.position == SIMD3(10, 3, 0))
        #expect(editor.selected?.yaw == 1.5)
        #expect(editor.selected?.scale == 4)
        #expect(editor.level.placements[0].position == SIMD3(0, 0, 0))
        #expect(editor.level.placements[2].position == SIMD3(20, 0, 0))
    }

    /// **Scaling to nothing loses a placement**: it cannot be picked again, so the only way back is
    /// undo, and by the time anyone notices the undo is gone.
    @Test("Scale cannot reach zero")
    func scaleIsClamped() {
        var editor = self.editor()
        editor.select(0)
        for _ in 0..<50 { editor.scale(by: 0.1) }
        #expect((editor.selected?.scale ?? 0) >= 0.05)
        for _ in 0..<50 { editor.scale(by: 10) }
        #expect((editor.selected?.scale ?? .infinity) <= 100)
    }

    @Test("Delete selects the neighbour, not nothing")
    func deleteKeepsAWorkingSelection() {
        var editor = self.editor()
        editor.select(1)
        editor.delete()
        #expect(editor.level.placements.map(\.mesh) == ["a", "c"])
        #expect(editor.selected?.mesh == "c", "deleting a run one at a time should not need re-picking")
        editor.delete()
        editor.delete()
        #expect(editor.level.placements.isEmpty)
        #expect(editor.selection == nil, "an empty level cannot have something selected")
    }

    @Test("Duplicate offsets the copy and selects it")
    func duplicate() {
        var editor = self.editor()
        editor.select(0)
        editor.duplicate()
        #expect(editor.level.placements.count == 4)
        #expect(editor.selection == 1)
        #expect(editor.selected?.mesh == "a")
        #expect(editor.selected?.position != editor.level.placements[0].position,
                "a copy on top of the original cannot be told apart or picked")
    }

    @Test("Undo and redo walk the history")
    func undoRedo() {
        var editor = self.editor()
        #expect(!editor.canUndo)
        editor.select(0)
        editor.move(by: SIMD3(5, 0, 0))
        editor.move(by: SIMD3(5, 0, 0))
        #expect(editor.selected?.position == SIMD3(10, 0, 0))
        editor.undo()
        #expect(editor.selected?.position == SIMD3(5, 0, 0))
        editor.undo()
        #expect(editor.selected?.position == SIMD3(0, 0, 0))
        #expect(!editor.canUndo)
        editor.redo()
        #expect(editor.selected?.position == SIMD3(5, 0, 0))
    }

    /// A new edit abandons the redo branch — otherwise redo replays a future that no longer follows
    /// from the present.
    @Test("Editing after undo drops the redo branch")
    func editingClearsRedo() {
        var editor = self.editor()
        editor.select(0)
        editor.move(by: SIMD3(1, 0, 0))
        editor.undo()
        #expect(editor.canRedo)
        editor.move(by: SIMD3(0, 0, 1))
        #expect(!editor.canRedo)
    }

    /// Undo past a delete must not leave the selection pointing off the end.
    @Test("Undo repairs a selection that no longer exists")
    func undoClampsSelection() {
        var editor = self.editor()
        editor.select(2)
        editor.delete()
        editor.select(1)
        editor.undo()
        #expect(editor.selection.map { editor.level.placements.indices.contains($0) } ?? true)
    }

    @Test("Saving clears the dirty flag and round-trips")
    func saving() throws {
        var editor = self.editor()
        editor.select(1)
        editor.move(by: SIMD3(0, 0, 7))
        #expect(editor.isDirty)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-test-\(UUID().uuidString).json")
        try editor.save(to: url)
        #expect(!editor.isDirty)

        let reloaded = try Level.decode(from: try Data(contentsOf: url))
        #expect(reloaded == editor.level)
        try? FileManager.default.removeItem(at: url)
    }

    /// **Dirty means "different from what was saved"**, and an undo back to the saved level is not.
    /// It used to stay dirty, and an editor that claims unsaved changes when there are none trains
    /// people to ignore it.
    @Test("Undo back to what was saved is clean, and redo away from it is not")
    func undoToTheSavedStateIsClean() throws {
        var editor = self.editor()
        editor.select(1)
        editor.move(by: SIMD3(0, 0, 7))
        editor.undo()
        #expect(!editor.isDirty, "back where it was opened")
        editor.redo()
        #expect(editor.isDirty)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try editor.save(to: url)
        editor.move(by: SIMD3(1, 0, 0))
        #expect(editor.isDirty)
        editor.undo()
        #expect(!editor.isDirty, "back to what was saved")
        editor.undo()
        #expect(editor.isDirty, "before the save is not what is on disk")
        editor.redo()
        #expect(!editor.isDirty)
        // A new edit from an earlier state is a different level, even where it repeats one.
        editor.undo()
        editor.move(by: SIMD3(0, 0, 7))
        #expect(editor.isDirty)
    }

    @Test("The steps a key makes are the editor's configuration")
    func configuredSteps() {
        var editor = LevelEditor(level: self.editor().level,
                                 configuration: .init(nudge: 2, undoDepth: 1))
        editor.select(0)
        editor.duplicate()
        #expect(editor.selected?.position == SIMD3(4, 0, 4), "a copy lands two nudges away")
        editor.move(by: SIMD3(1, 0, 0))
        editor.undo()
        #expect(!editor.canUndo, "only one step is remembered")
    }

    // MARK: - The selection's lamp

    private let lamp = PunctualLight(position: SIMD3(0, 1.5, 0), color: SIMD3(40, 28, 16), range: 12)

    @Test("A lamp can be given, and taken away, and both undo")
    func giveAndTakeALamp() {
        var editor = self.editor()
        editor.select(0)
        editor.setLight(lamp)
        #expect(editor.level.placements[0].light == lamp)
        #expect(editor.level.placements[1].light == nil, "the lamp went to something not selected")
        editor.setLight(nil)
        #expect(editor.level.placements[0].light == nil)
        editor.undo()
        #expect(editor.level.placements[0].light == lamp)
        editor.undo()
        #expect(editor.level.placements[0].light == nil)
    }

    /// **The lamp is the placement's**, so the placement's own edits carry it — which is the whole
    /// reason it is not a free-standing light.
    @Test("A lamp given in the editor moves, turns and copies with its placement")
    func lampTravelsWithItsPlacement() {
        var editor = self.editor()
        editor.select(0)
        editor.setLight(PunctualLight(position: SIMD3(0.5, 1.5, 0), color: SIMD3(1, 1, 1), range: 5))
        editor.move(by: SIMD3(3, 0, 0))
        editor.rotate(by: .pi / 2)
        let ground = Level.Ground(height: { _, _ in 0 })
        let before = editor.level.carriedLights(on: ground).first { $0.placement == 0 }!.light.position
        #expect(abs(before.x - 3) < 1e-4 && abs(before.z + 0.5) < 1e-4,
                "turned a quarter, the lamp's +x offset should point along -z: \(before)")
        editor.duplicate()
        #expect(editor.level.carriedLights(on: ground).count == 2, "the copy should carry a lamp too")
    }

    @Test("Raising a lamp is in metres of the world, whatever the placement's size")
    func raiseIsInWorldMetres() {
        var editor = self.editor()
        editor.select(1)                       // scale 2
        editor.setLight(lamp)
        editor.raiseLight(by: 0.5)
        #expect(abs(editor.level.placements[1].light!.position.y - 1.75) < 1e-5,
                "a 0.5 m raise on a placement at scale 2 is a 0.25 offset")
        let ground = Level.Ground(height: { _, _ in 0 })
        let world = editor.level.carriedLights(on: ground).first { $0.placement == 1 }!.light.position.y
        #expect(abs(world - 3.5) < 1e-4, "1.75 in the placement's space, doubled, is 3.5 m up")
    }

    @Test("Brightening keeps the colour's hue, in thirds of a stop, and cannot reach zero")
    func brightenKeepsHue() {
        var editor = self.editor()
        editor.select(0)
        editor.setLight(lamp)
        for _ in 0..<3 { editor.brightenLight(by: editor.configuration.lampBrighten) }
        let c = editor.level.placements[0].light!.color
        #expect(abs(c.x - 80) < 1e-2, "three thirds of a stop should double 40 to 80, got \(c.x)")
        #expect(abs(c.y / c.x - 28.0 / 40) < 1e-5 && abs(c.z / c.x - 16.0 / 40) < 1e-5, "the hue moved")
        for _ in 0..<200 { editor.brightenLight(by: 1 / editor.configuration.lampBrighten) }
        #expect(abs(editor.level.placements[0].light!.color.max() - editor.configuration.lampIntensityRange.lowerBound) < 1e-4)
    }

    @Test("Lamp edits on a placement without a lamp change nothing and dirty nothing")
    func noLampNoChange() {
        var editor = self.editor()
        editor.select(2)
        editor.raiseLight(by: 1)
        editor.brightenLight(by: 2)
        editor.setLight(nil)
        #expect(!editor.isDirty && !editor.canUndo)
    }

    @Test("A placement can be added with its lamp")
    func addWithALamp() {
        var editor = self.editor()
        editor.add(mesh: "brazier", at: SIMD3(1, 0, 1), light: lamp)
        #expect(editor.selected?.light == lamp)
        #expect(editor.level.carriedLights(on: Level.Ground(height: { _, _ in 0 })).contains { $0.placement == editor.selection })
    }

    // MARK: - Adding by kind

    private var mixedLevel: Level {
        let lamp = PunctualLight(position: SIMD3(0, 1.8, 0), color: SIMD3(60, 36, 18), range: 14)
        return Level(name: "mixed", placements: [
            Level.Placement(mesh: "box", position: SIMD3(1, 0, 1), scale: 2, tags: ["solid"], surface: "wood"),
            Level.Placement(mesh: "step", position: SIMD3(4, -0.7, 4), anchor: .absolute, tags: ["solid"], surface: "stone"),
            Level.Placement(mesh: "box", position: SIMD3(5, 0, 9), yaw: 1, scale: 2, tags: ["solid"], surface: "wood"),
            Level.Placement(mesh: "step", position: SIMD3(4, -0.4, 3), anchor: .absolute, tags: ["solid"], surface: "stone"),
            Level.Placement(mesh: "brazier", position: SIMD3(-4, 0, -10), tags: ["solid"], light: lamp, surface: "metal"),
            Level.Placement(mesh: "brazier", position: SIMD3(3, 0, -2), tags: ["solid"]),
        ])
    }

    /// Where a thing is and which way it faces do not make it a different kind; its lamp does.
    @Test("A level's kinds are one of each thing, ignoring where each is")
    func kinds() {
        let kinds = LevelEditor(level: mixedLevel).kinds()
        #expect(kinds.map(\.mesh) == ["box", "step", "brazier", "brazier"],
                "\(kinds.map(\.mesh)) — two crates in different places and turns are one kind, a lit brazier and a cold one are two")
        #expect(kinds.allSatisfy { $0.position.x == 0 && $0.position.z == 0 && $0.yaw == 0 })
        #expect(kinds[1].position.y == -0.7, "the height is part of what a sunk tread is — kept from the first")
        #expect(kinds[2].light != nil && kinds[3].light == nil)
    }

    @Test("Adding a kind brings everything but the place, and undoes")
    func addAKind() {
        var editor = LevelEditor(level: mixedLevel)
        let brazier = editor.kinds()[2]
        editor.add(brazier, at: SIMD2(7, -3))
        let added = editor.selected!
        #expect(added.position == SIMD3(7, 0, -3))
        #expect(added.tags == ["solid"] && added.surface == "metal" && added.scale == 1)
        #expect(added.light == brazier.light)
        let lamps = editor.level.carriedLights(on: Level.Ground(height: { _, _ in 0 }))
        #expect(lamps.contains { $0.placement == editor.selection && abs($0.light.position.x - 7) < 1e-4 },
                "the added brazier should light where it stands")
        editor.undo()
        #expect(editor.level == mixedLevel)
    }

    @Test("Adding puts a placement where it was asked for and selects it")
    func adding() {
        var editor = self.editor()
        editor.add(mesh: "new", at: SIMD3(1, 2, 3), tags: ["solid"])
        #expect(editor.selected?.mesh == "new")
        #expect(editor.selected?.position == SIMD3(1, 2, 3))
        #expect(editor.selected?.tags == ["solid"])
        editor.undo()
        #expect(editor.level.placements.count == 3)
    }
}

struct BoundingBoxContainsTests {
    private let box = BoundingBox(minimum: SIMD3(-1, 0, -1), maximum: SIMD3(1, 2, 1))

    @Test func insideAndOutside() {
        #expect(box.contains(SIMD3(0, 1, 0)))
        #expect(!box.contains(SIMD3(0, 3, 0)))
        #expect(!box.contains(SIMD3(2, 1, 0)))
        #expect(!box.contains(SIMD3(0, -0.1, 0)))
    }

    /// Hand-authored levels put everything on round numbers, so points land exactly on faces all the
    /// time — and "on the wall" reading as "outside it" is how a player ends up standing inside one.
    @Test func facesAndCornersCount() {
        #expect(box.contains(SIMD3(1, 0, -1)))
        #expect(box.contains(SIMD3(-1, 2, 1)))
        #expect(box.contains(SIMD3(0, 0, 0)))
    }
}

/// **The engine must not say another product's name.**
///
/// Its gamepad connect/disconnect messages were logged under the name of the *game* it was first
/// extracted from — found by running the sample, where a controller was plugged in and the console
/// announced a product that was not running. Anybody else would have seen the same thing in their
/// own app.
struct EngineIdentityTests {
    @Test func theEngineNamesItself() {
        #expect(Engine.name == "Windage Engine")
        #expect(!Engine.name.isEmpty)
    }
}
