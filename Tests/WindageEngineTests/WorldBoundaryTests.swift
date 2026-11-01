import Foundation
import Metal
import Testing
import simd
@testable import WindageEngine

@Suite("The edge of a world")
struct WorldBoundaryTests {

    private let round = WorldBoundary(profile: .dome, halfSize: SIMD2(50, 50), roundness: 1, base: -10, height: 50)
    private let square = WorldBoundary(profile: .walls, halfSize: SIMD2(100, 60), roundness: 0, base: -10, height: 40)

    @Test("A body inside comes back unchanged, to the bit")
    func insideIsUntouched() {
        for feet in [SIMD3<Float>(0, 0, 0), SIMD3(30.123, 1.5, -20.7), SIMD3(-48, 0, 0)] {
            let kept = round.contain(feet: feet, radius: 0.3, height: 1.8)
            #expect(kept == feet || simd_length(SIMD2(feet.x, feet.z)) > 47, "\(feet) → \(kept)")
        }
        let inside = SIMD3<Float>(99.6, 0, 59.6)
        #expect(square.contain(feet: inside, radius: 0.3, height: 1.8) == inside)
    }

    @Test("A round dome holds a body its radius in, measured at its head where the dome leans in")
    func roundDomeHolds() {
        let kept = round.contain(feet: SIMD3(80, 0, 0), radius: 0.3, height: 1.8)
        // An ellipsoid of radius 50 and height 50 over a base 10 below the feet: at the head, 11.8 up, its radius is
        // 50·√(1 − (11.8/50)²).
        let ratio: Float = 11.8 / 50
        let expected = 50 * (1 - ratio * ratio).squareRoot() - 0.3
        #expect(abs(kept.x - expected) < 1e-3, "\(kept.x) against \(expected)")
        #expect(kept.y == 0 && abs(kept.z) < 1e-5)
        // Higher, it is held further in.
        let up = round.contain(feet: SIMD3(80, 30, 0), radius: 0.3, height: 1.8)
        #expect(up.x < kept.x - 10)
        // Along the diagonal, the same distance from the middle.
        let diagonal = round.contain(feet: SIMD3(60, 0, 60), radius: 0.3, height: 1.8)
        #expect(abs(simd_length(SIMD2(diagonal.x, diagonal.z)) - expected) < 1e-3)
    }

    @Test("Square walls reach their corners, and a body walking into them slides along")
    func squareCorners() {
        let corner = square.contain(feet: SIMD3(200, 0, 200), radius: 0.3, height: 1.8)
        #expect(abs(corner.x - 99.7) < 1e-4 && abs(corner.z - 59.7) < 1e-4)
        let side = square.contain(feet: SIMD3(105, 0, 12), radius: 0.3, height: 1.8)
        #expect(abs(side.x - 99.7) < 1e-4 && side.z == 12, "along the wall, not back toward the middle")
        // A ceiling: a body jumping into it is held under it.
        let ceiling = square.contain(feet: SIMD3(0, 29.5, 0), radius: 0.3, height: 1.8)
        #expect(abs(ceiling.y - (30 - 1.8)) < 1e-4)
    }

    @Test("A long dome curves in by the same amount on every side")
    func longDome() {
        let long = WorldBoundary(profile: .dome, halfSize: SIMD2(150, 50), roundness: 0.3, base: 0, height: 50)
        // At half its height its walls stand 50·(1 − √(1 − 0.25)) in from the footprint, on both axes.
        let k = 50 * (1 - (0.75 as Float).squareRoot())
        #expect(abs(long.inset(atHeight: 25) - k) < 1e-4)
        #expect(abs(long.contain(SIMD3(500, 25, 0)).x - (150 - k)) < 1e-3)
        #expect(abs(long.contain(SIMD3(0, 25, 500)).z - (50 - k)) < 1e-3)
        #expect(!long.contains(SIMD3(0, 50.5, 0)))
    }

    @Test("A fitted dome rises straight to the ground and curves from there, so a small map is not walled in early")
    func springsFromTheGround() {
        let small = WorldBoundary.fitted(minimum: SIMD3(-20, 0, -20), maximum: SIMD3(20, 2, 20))
        #expect(small.spring == 20 && small.base == -20)
        #expect(small.inset(atHeight: -5) == 0, "straight below the ground")
        let kept = small.contain(feet: SIMD3(0, 0, -40), radius: 0.3, height: 1.8)
        #expect(kept.z < -18.5, "nearly at the footprint at head height: \(kept.z)")
        #expect(small.top - small.base - small.spring >= 19, "and rising at least its half-width above the ground")
        let surface = small.surface(around: BoundaryRenderer.around, rings: BoundaryRenderer.rings)
        let row = BoundaryRenderer.around + 1
        #expect(surface[0].positionAndU.y == -20 && surface[row].positionAndU.y == 0, "the floor, then the spring")
    }

    @Test("A line from inside meets the shell where it is; a line that stays inside meets nothing")
    func lineMeetsShell() throws {
        let along = try #require(round.exit(from: SIMD3(0, -10, 0), direction: SIMD3(1, 0, 0), limit: 200))
        #expect(abs(along - 50) < 0.02, "\(along)")
        let up = try #require(round.exit(from: SIMD3(0, 0, 0), direction: SIMD3(0, 1, 0), limit: 200))
        #expect(abs(up - 40) < 0.02, "the crown, 40 over a point 10 above the floor: \(up)")
        #expect(round.exit(from: .zero, direction: SIMD3(1, 0, 0), limit: 20) == nil)
        #expect(round.exit(from: SIMD3(80, 0, 0), direction: SIMD3(1, 0, 0), limit: 20) == 0)
    }

    @Test("The floor is a net, not a wall: below it is fallen, not kept out")
    func floorIsANet() {
        #expect(round.isBelowFloor(SIMD3(0, -10.1, 0)))
        #expect(!round.isBelowFloor(SIMD3(0, -9.9, 0)))
        #expect(round.contain(feet: SIMD3(0, -40, 0), radius: 0.3, height: 1.8).y == -40)
    }

    @Test("Fitted to a world: inside the ground's edge, under its lowest point, over its highest")
    func fitted() {
        let fitted = WorldBoundary.fitted(minimum: SIMD3(-150, -4, -100), maximum: SIMD3(150, 30, 100))
        #expect(fitted.center == SIMD2(0, 0))
        #expect(fitted.halfSize == SIMD2(149, 99))
        #expect(fitted.base == -24)
        #expect(fitted.top >= 50, "clears the highest point by its headroom")
        #expect(fitted.height >= 99, "a dome as tall as its shorter half-width")
        let walls = WorldBoundary.fitted(minimum: SIMD3(-150, -4, -100), maximum: SIMD3(150, 30, 100), profile: .walls)
        #expect(walls.top == 50)
    }

    @Test("Saved and read back the same")
    func codable() throws {
        var boundary = square
        boundary.look = .forceField
        let data = try JSONEncoder().encode(boundary)
        #expect(try JSONDecoder().decode(WorldBoundary.self, from: data) == boundary)
        // A key it does not have keeps its default; a number out of range is clamped; a word it does not know is the
        // default's.
        let sparse = #"{"profile": "walls", "roundness": 4, "look": {"style": "lasers", "opacity": 0.3}}"#
        let read = try JSONDecoder().decode(WorldBoundary.self, from: Data(sparse.utf8))
        #expect(read.profile == .walls && read.roundness == 1 && read.halfSize == WorldBoundary().halfSize)
        #expect(read.look.style == .lattice && read.look.opacity == 0.3)
    }

    // MARK: The surface

    @Test("Every corner of the surface lies on the shell, and a square's corners are among them")
    func surfaceOnShell() {
        let long = WorldBoundary(profile: .dome, halfSize: SIMD2(150, 50), roundness: 0.3, base: 0, height: 60)
        for boundary in [round, square, long] {
            let surface = boundary.surface(around: BoundaryRenderer.around, rings: BoundaryRenderer.rings)
            #expect(surface.count == BoundaryRenderer.vertexCount)
            let walls = surface.prefix(BoundaryRenderer.rings * (BoundaryRenderer.around + 1))
            for v in walls {
                let p = SIMD3(v.positionAndU.x, v.positionAndU.y, v.positionAndU.z)
                let off = boundary.distanceOutside(SIMD2(p.x, p.z), atHeight: p.y)
                #expect(abs(off) < 0.01 || p.y >= boundary.top - 0.01, "\(p) is \(off) off the shell")
                #expect(simd_length(SIMD3(v.normalAndV.x, v.normalAndV.y, v.normalAndV.z)) > 0.99)
            }
        }
        let floor = square.surface(around: BoundaryRenderer.around, rings: BoundaryRenderer.rings)
            .prefix(BoundaryRenderer.around).map { SIMD2($0.positionAndU.x, $0.positionAndU.z) }
        for corner in [SIMD2<Float>(100, 60), SIMD2(-100, 60), SIMD2(-100, -60), SIMD2(100, -60)] {
            #expect(floor.contains { simd_distance($0, corner) < 1e-3 }, "\(corner) is a corner of the walls")
        }
    }

    @Test("The pattern fits round the perimeter a whole number of times")
    func patternCloses() {
        for boundary in [round, square] {
            let cells = boundary.perimeter / boundary.patternCell(along: true)
            #expect(abs(cells - cells.rounded()) < 1e-3)
        }
        #expect(abs(square.perimeter - 640) < 1e-3)
        #expect(abs(round.perimeter - 2 * .pi * 50) < 1e-3)
    }

    @Test("The triangles join every ring to the next and close the ceiling", arguments: [false])
    func indices(_: Bool) {
        let indices = WorldBoundary.surfaceIndices(around: 8, rings: 3)
        #expect(indices.count == 2 * 8 * 6 + 8 * 3)
        #expect(indices.max()! == UInt32(WorldBoundary.surfaceVertexCount(around: 8, rings: 3) - 1))
        #expect(MemoryLayout<BoundaryRenderer.Vertex>.stride == 32)
        #expect(MemoryLayout<BoundaryRenderer.Frame>.size == 64 + 16 * 5 + 16 * 8)
    }

    // MARK: Bodies and cameras

    private func walk(_ body: inout CharacterController, _ input: MovementInput, seconds: Float,
                      in world: CharacterController.Surroundings) {
        for _ in 0..<Int(seconds * 60) {
            body.step(yaw: 0, input: input, deltaTime: 1 / 60, in: world)
        }
    }

    @Test("A body walks up to the edge and no further, and slides along it")
    func bodyStopsAtTheEdge() {
        let world = CharacterController.Surroundings(boundary: square)
        var body = CharacterController(feet: SIMD3(0, 0, -50))
        // Yaw 0 faces −z: forwards runs into the −z wall.
        walk(&body, MovementInput(forward: 1), seconds: 4, in: world)
        #expect(abs(body.feet.z - -59.7) < 1e-3, "\(body.feet)")
        walk(&body, MovementInput(forward: 1, strafe: 1), seconds: 1, in: world)
        #expect(body.feet.x > 4 && abs(body.feet.z - -59.7) < 1e-3, "slid along it: \(body.feet)")
        #expect(body.isGrounded)
    }

    @Test("A body that falls through the floor is caught and put back on the last ground it stood on")
    func netCatches() {
        // Ground with a hole: under it, nothing for ever.
        let holed = CharacterController.Surroundings(
            groundHeight: { x, _ in x > 5 ? -10_000 : 0 }, boundary: round)
        var body = CharacterController(feet: SIMD3(0, 0, 0))
        walk(&body, MovementInput(), seconds: 0.5, in: holed)
        #expect(body.safeFeet == SIMD3(0, 0, 0))
        body.teleport(to: SIMD3(4.9, 0, 0))
        walk(&body, MovementInput(), seconds: 0.5, in: holed)
        #expect(body.safeFeet.x == 4.9)
        // Strafe right into the hole.
        var caught = false
        for _ in 0..<(60 * 6) {
            body.step(yaw: 0, input: MovementInput(strafe: 1), deltaTime: 1 / 60, in: holed)
            if body.wasCaught { caught = true; break }
        }
        #expect(caught)
        // Back on the last ground it stood on, at the brink of the hole it walked into — standing and still.
        #expect(body.feet.x >= 4.9 && body.feet.x <= 5.001 && body.feet.y == 0 && body.feet.z == 0, "\(body.feet)")
        #expect(body.verticalVelocity == 0 && body.isGrounded)
        #expect(!body.feet.y.isNaN)
    }

    @Test("Ground is not safe until it has been stood on a moment")
    func safeAfterAMoment() {
        let world = CharacterController.Surroundings(boundary: round)
        var body = CharacterController(feet: SIMD3(0, 0, 0))
        walk(&body, MovementInput(forward: 1), seconds: 1, in: world)
        // Walking, it keeps standing; safe follows it.
        #expect(body.safeFeet.z < -3)
        // Without a boundary there is no net, and nothing is tracked.
        var free = CharacterController(feet: .zero)
        walk(&free, MovementInput(forward: 1), seconds: 1, in: CharacterController.Surroundings())
        #expect(free.safeFeet == .zero)
    }

    @Test("A camera backed against the edge stays inside the world")
    func cameraStaysInside() {
        let world = CharacterController.Surroundings(boundary: square)
        let allowed = OrbitCamera.allowedDistance(aimPoint: SIMD3(0, 1.7, -57), direction: SIMD3(0, 0, -1),
                                                  desired: 10, in: world)
        #expect(abs(allowed - (3 - OrbitCamera.Tuning().probeRadius)) < 0.05, "\(allowed)")
    }

    // MARK: Drawing

    private final class Draws: GameLoop {
        let renderer: BoundaryRenderer
        let boundary: WorldBoundary
        let player: SIMD3<Float>
        let struck: SIMD3<Float>?
        var drew = false
        init(_ renderer: BoundaryRenderer, _ boundary: WorldBoundary, player: SIMD3<Float>, struck: SIMD3<Float>?) {
            self.renderer = renderer
            self.boundary = boundary
            self.player = player
            self.struck = struck
        }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
            // A few meters from the +x wall, looking at it.
            let eye = SIMD3<Float>(44, 1.7, 0)
            let view = Camera(position: eye, yaw: -.pi / 2, pitch: 0).viewMatrix
            let projection = simd_float4x4(perspectiveFovY: 60 * .pi / 180, aspectRatio: 1, nearZ: 0.1)
            if let struck { renderer.strike(at: struck, time: 0.45) }
            drew = renderer.draw(boundary, into: encoder, frameSlot: frameSlot, viewProjection: projection * view,
                                 camera: eye, player: player, time: 0.5)
        }
        func encodeHUD(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
    }

    @MainActor
    private func middlePixel(of boundary: WorldBoundary, player: SIMD3<Float> = SIMD3(44, 0, 0),
                             struck: SIMD3<Float>? = nil, device: MTLDevice) throws -> (pixel: [Int], drew: Bool) {
        let frames = try FrameRenderer(device: device)
        let renderer = try BoundaryRenderer(device: device, sampleCount: frames.effectiveSampleCount)
        frames.residencySet.addAllocations(renderer.allocations)
        let game = Draws(renderer, boundary, player: player, struck: struck)
        frames.game = game
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                  width: 64, height: 64, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        frames.residencySet.addAllocation(target)
        frames.commitResidency()
        frames.render(into: target)
        var p = [UInt8](repeating: 0, count: 4)
        target.getBytes(&p, bytesPerRow: 256, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        return (p.map(Int.init), game.drew)
    }

    @Test("Drawn where the player meets it, in its color; hidden, nothing; near, nothing from far off")
    @MainActor
    func draws() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        var red = round
        red.look = WorldBoundary.Look(style: .haze, visibility: .near, color: SIMD3(1, 0, 0), opacity: 1)
        var hidden = red
        hidden.look.visibility = .hidden
        let shown = try middlePixel(of: red, device: device)
        let none = try middlePixel(of: hidden, device: device)
        #expect(shown.drew && !none.drew)
        // BGRA: red came up, green and blue did not.
        #expect(shown.pixel[2] > none.pixel[2] + 40, "\(shown.pixel) over \(none.pixel)")
        #expect(abs(shown.pixel[1] - none.pixel[1]) < 40)
        // A near boundary, with the player far from it: nothing.
        let distant = try middlePixel(of: red, player: SIMD3(-30, 0, 0), device: device)
        #expect(abs(distant.pixel[2] - none.pixel[2]) < 4, "\(distant.pixel)")
        // Always, it is seen wherever they are.
        var always = red
        always.look.visibility = .always
        #expect(try middlePixel(of: always, player: SIMD3(-30, 0, 0), device: device).pixel[2] > none.pixel[2] + 40)
        // Struck where the view looks, a near boundary nobody is near shows the ripple there.
        var lattice = red
        lattice.look.style = .lattice
        let wall = SIMD3<Float>(lattice.contain(SIMD3(60, 1.7, 0)).x, 1.7, 0)
        let rippled = try middlePixel(of: lattice, player: SIMD3(-30, 0, 0), struck: wall, device: device)
        #expect(rippled.pixel[2] > none.pixel[2] + 30, "\(rippled.pixel) over \(none.pixel)")
    }
}
