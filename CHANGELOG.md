# Changelog

Every release of Windage Engine, newest first. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Wading through water and other liquids**: `CharacterController.Surroundings` has a new `liquidHeight` closure that returns the liquid's surface height at a world x/z, or nil where there is none. A body walks the bed underneath and slows down the deeper it wades. `Surroundings.liquidDepth(at:)` returns how deep a pair of feet stands.
- **Wading pace tuning**: `CharacterController.Tuning.wadingPace` is a curve of depth, as a fraction of standing height, against the fraction of pace kept. By default knee-deep keeps 85%, waist-deep 50% and chest-deep 20%, and deeper water stays at 20%, so it never stops a body completely. `wadingSprintDepth` sets the depth (waist-deep by default) where a sprint becomes a walk, and `wadingFraction(atDepth:)` reads the curve. An empty curve means water costs nothing.
- **`CharacterController.wadingDepth`**: how deep the feet stood in a liquid when the last step began, or 0 on dry ground.
- **The orbit camera stays above liquids**: `OrbitCamera.keepClear(of:deltaTime:)` now raises the camera to stay `Tuning.liquidClearance` (default 0.3 m) above any liquid in the surroundings. When the character wades deeper than the shoulder, it also raises the aim point. Both rise at once and ease back down over `recoveryHalfLife`. The amounts are readable as `liquidLift` and `aimLift` and are blended by `interpolated(from:to:alpha:)`. `orbitPosition` is where the camera would be before its own lift. `OrbitCamera.liquidLift(at:in:clearance:)` works out the lift for any point.
- **`InterfaceImage`**: describes how a HUD image is cut. It can be nine-sliced (`border`, `borderScale`, `fillsCentre`) or partly filled (`Fill.horizontal`, `.vertical` or `.radial`). Use it for frames, bars and dials. `triangles(origin:size:textureSize:)` produces the geometry without a GPU, and `InterfaceImage.clip(_:to:size:)` cuts triangles to a rectangle.
- **Sliced, filled and clipped HUD images**: `HUDRenderer.image(_:origin:size:cut:rotation:color:clip:)` draws a texture cut by an `InterfaceImage`, optionally rotated and clipped to a rectangle. `HUDRenderer.image(_:triangles:color:clip:)` draws a texture across any triangles you supply as `InterfaceImage.Corner`s.
- **HUD text in your own font**: `HUDRenderer.text(_:atBaseline:pointSize:color:font:clip:)` takes an optional `FontAtlas` in place of the HUD's own font, and an optional clip rectangle, such as a compass strip scrolling under a window. `HUDRenderer.width(of:pointSize:font:)` measures text in that font. Add `FontAtlas.allocation` to your residency set before drawing with it. `FontAtlas.ascent(pointSize:)` gives the height of the font's tallest glyphs above the baseline, for placing a line in a box.

## [1.3.0] — 2026-11-03

### Added

- **Skinning on the GPU** — `SkinnedModel` loads a skinned USD character, including one exported as many separate skinned parts (body, head, hair, armor), into a single mesh with its parts grouped by material. `makeInstance()` gives a `SkinnedInstance` that holds its own `pose`. `SkinningPass` skins every instance in one compute dispatch per character per frame. Encode it in `GameLoop.encodePrePasses(into:frameSlot:interpolation:)` and draw from `vertexBufferAddress(_:frameSlot:)` or `posedBuffer(_:frameSlot:)`. `SkinnedGeometry.read(url:vertexDescriptor:semantics:)` reads the same data without a device, and `SkinnedModel.triangles(boundTo:least:)` returns the triangles bound to part of the rig.
- **Mixing and layering clips** — `SkeletonPose.set(mixing:)` blends any number of weighted playheads. It normalizes the weights and handles quaternion hemispheres correctly. `SkeletonPose.overlay(_:mask:modelRotationAt:)` lays clips over part of the rig, for example an upper body aiming while the legs keep walking. `Skeleton.mask(from:weight:)` builds the mask for a joint and everything below it.
- **Locomotion blending** — `LocomotionBlend.choose(airborne:rising:groundSpeed:heading:clips:)` picks the idle, gait, rise and fall clips and their weights from the body's state. Gaits (`LocomotionBlend.Gait`) are keyed to the speed each clip was authored at, and a gait can have directional clips (`LocomotionBlend.Direction`) such as strafes and backpedals. `LocomotionBlend.Clips` describes a game's clip set, and `StrideClock` keeps every stride on one phase.
- **`FigureMotion`** — turns a body's state (`FigureMotion.Body`) into the clips to sample this frame (`[FigureMotion.Play]`). It eases between clips, keeps every gait on a shared stride phase, plays a jump from take-off, runs the stride backwards when backpedaling, and layers one-shots such as a swing or a flinch on top (`FigureMotion.OneShot`, with an `envelope(at:lasting:fadeIn:fadeOut:)` helper).
- **`StrideAlignment`** — `StrideAlignment.align(_:on:footJoint:…)` measures where each gait's stride lines up with the others' on a skeleton. Blended walks and runs then don't cross their legs.
- **Root motion on clips** — `AnimationClip.travel(ofJoint:)` gives how far a joint moves over the clip, which is the speed a gait was authored at. `AnimationClip.inPlace(joint:)` removes a joint's travel along the ground so the game can move the figure instead.
- **`OrbitCamera`** — a third-person camera with orbit and zoom, smoothed follow, recentering behind the character (`recentre(behind:deltaTime:active:)`) and an over-the-shoulder offset. It pulls in when something blocks the view (`keepClear(of:deltaTime:)`, `constrain(to:deltaTime:)`, `allowedDistance(…)`). `OrbitCamera.interpolated(from:to:alpha:)` interpolates between fixed steps, and `viewMatrix` and `projectionMatrix(aspect:)` follow the engine's reversed-Z convention.
- **`CharacterFacing`** — turns a third-person character toward its movement over a short half-life. Backing away keeps it facing forward, `isHeld` holds its facing during an attack, `isBackpedaling` reports when it is backing away, and `backpedalled(_:axis:minimum:)` slows backward movement in proportion to how much of the input points back.
- **`CameraShake`** — camera shake based on trauma that decays over time, with two channels: `landed(force:towards:)` for a directional punch when you land a blow, and `took(force:)` for a shake when you take one. Call `advance(by:)` once a step and add `offset` to the camera position. The `CameraShake.Tuning` defaults are set for `OrbitCamera`'s default framing.
- **World boundaries** — `WorldBoundary` is a dome- or wall-shaped edge of the world, fitted to a level with `fitted(minimum:maximum:profile:)`, with `contains`, `contain`, `exit(from:direction:limit:)` and Codable support. `BoundaryRenderer` draws it in the HDR scene in one of four looks (`WorldBoundary.Look`: lattice, grid, force field or haze). A boundary can be shown always or only near the player, and `strike(at:time:)` sends ripples across it.
- **`CharacterController.Surroundings.boundary`** — keeps the body inside a `WorldBoundary`. A body that falls below the boundary's floor is put back on the last safe ground (`safeFeet`), and `wasCaught` reports that it happened this step.
- **`NavigationGrid`** — a walkable grid built from a `CollisionMesh` and a ground function, sized for a body (`NavigationGrid.Body`, which can be built from `CharacterController.Tuning`). `path(from:to:searchLimit:)` finds a path between two points, and `place(near:within:)`, `neighbour(of:way:)` and `position(of:)` give lower-level access.
- **`HoldPress`** — a button held for a moment that acts once, such as holstering a weapon or reviving a friend, stepped with the simulation. `progress` drives a fill ring and `cancel()` resets a hold that is under way.
- **HUD images** — `HUDRenderer.image(_:center:size:rotation:color:)` draws a texture (a crosshair sprite, an icon) tinted and rotated. Images and shapes still composite in the order they were submitted.
- **Particle recipes** — new `ParticleRecipe` properties:
  - `softness` fades particles where they meet solid geometry. Pass the scene's depth to `ParticleRenderer.draw` through the new `solidDepth:` and `nearPlane:` parameters.
  - `lands` ends a particle where it comes back down to its birth height.
  - `then`, `thenCount` and `generations` chain recipes, throwing new particles where one dies.
  - `mesh` lets the game draw its own mesh for each particle, placed by `ParticleSystem.meshTransform(of:)`.
  - `unlit` draws matter in its own color regardless of the scene's light.
  - `sizeOverLife`, `opacityOverLife` and `colourOverLife` are curves over a particle's life, like Unity's.

  `ParticleRecipe.shiftingThen(by:)` lets several effects share one system, and `ParticleSystem.hasLive` is a cheap check for whether anything is alive.
- **Sorted see-through copies** — `InstanceBatches.init(farthestFirst:from:)` orders blended copies back to front, one batch each. Copies at equal distances keep their order from frame to frame.
- **Skipping the opaque color copy** — `GameLoop.wantsOpaqueColour` (default `true`). A game whose second pass reads only the solid scene's depth returns `false`, and the color is no longer copied every frame.
- **Shipping and sharing compressed textures** — `CompressedTextures.cached(_:isColor:origin:quality:in:)` finds an already-compressed file without encoding anything, for example from a cache bundled with the game. `CompressedTextures.appCache(named:bundle:)` returns the right cache folder whether or not the app is sandboxed. `CompressedTextures.version` names the current cache format.
- **`TextureStore.adopt(_:for:isColor:origin:)`** — hands the store a texture the game already loaded, so later requests for that source reuse it. `TextureSource.contents(in:)` reads a source's bytes, including an entry inside a `.usdz` file.

### Changed

- **The compressed-texture cache is keyed by file contents, not by path** — the same image copied into Debug, Release and archived builds is compressed once, not once per copy. Files now go in a folder named after `CompressedTextures.version` inside the cache folder, and files left by older versions are removed when a new one is made. Expect every texture to be compressed once more on the first launch after upgrading.
- **`CollisionMesh.standingFloor(x:z:below:)` bridges narrow gaps** — a gap narrower than two footings, with floor on both sides, is now treated as floor, so a body no longer drops through the cracks between stair treads. An edge with floor on only one side still lets a body step off.
- **Performance and stability improvements** — `CollisionMesh.firstHit(from:direction:limit:)` walks only the grid cells the ray crosses, nearest first, which makes camera and line-of-sight tests in dense geometry much cheaper. Particles too faint to show are skipped, and each particle's recipe is read once per draw. The shadow passes wait for skinning before they draw.

### Fixed

- **Distant mips of textures with alpha drew too dark** — compressed textures with an alpha channel (leaf sheets, cut-outs) stored premultiplied color in their mips, so far-off foliage drew nearly black. Each mip level is now un-premultiplied before encoding, and texels with no coverage take their neighbors' color instead of black.
- **A released `FrameRenderer` could keep its memory resident** — when a `CAMetalLayer` outlived its renderer, the command queue kept every buffer and texture the renderer had made resident. That could be a gigabyte for a large scene. The renderer now removes its residency set from the queue when it is released.
- **Meshes without normals drew unlit** — when a vertex descriptor asks for normals and a mesh loaded through Model I/O has none, smooth normals are now generated for it.

## [1.2.0] — 2026-10-29

### Added

- **Decals**: `DecalSet` keeps marks left on surfaces, such as bullet holes, scorches and footprints. Each mark is lifted off its surface so it doesn't z-fight, held for `holdSeconds`, faded over `fadeSeconds`, and the oldest is replaced when the set is full. `DecalRenderer` draws them, cut from a `DecalAtlas`, after the opaque scene and before particles.
- **Time-of-day sky**: `DaySky` turns one `timeOfDay` value into the sun or moon direction, light colour, sky colours and an exposure lift for night (`Lighting.exposureStops`). It also has a hand-placed `Sun`, distance fog (`fogDensity`, `fog(atDistance:)`) and a per-world `saturation` and `zenithBrightness`. `SkyPass` draws it.
- **Triangle collision**: `CollisionMesh` builds walkable collision from world-space or placed triangles, for bridge decks, caves and boulders. It answers `floor(x:z:below:)`, `standingFloor(x:z:below:)`, `ceiling(x:z:above:below:)`, `pushOut(_:radius:height:stepHeight:passes:)` and `firstHit(from:direction:limit:)`. Pass it to `CharacterController.Surroundings.meshes`.
- **Custom character walls**: `CharacterController.Surroundings.isBlocked` lets a game refuse moves by its own rule, such as an occupancy grid or a navigation mask. The body slides along the wall rather than sticking to it.
- **Weapon bob in step with footsteps**: `CharacterController.stridePhase` and `nextFoot` are now public, so a game can lock a weapon bob to the footsteps.
- **Static ray tests**: `StaticVolumes` is a grid of boxes for segment and ray hits (`firstHit(segmentFrom:to:)`, `firstHit(origin:direction:…)`).
- **Graphics settings**: `GraphicsSettings` covers `shadows`, `drawDistance`, `plantDensity`, `renderScale`, `frameRate`, `antiAliasing`, `reflections` and `textureQuality`. It has `Low`/`Medium`/`High` presets, is `Codable` (sets saved before a setting existed keep the rest), and is applied with `FrameRenderer.apply(_:automaticScaling:)`.
- **Scene scaling and multisampling**: `FrameRenderer.sceneScaling` (`SceneScaling.native`, `.fraction`, `.capped`) draws the 3D scene smaller than the window while the interface stays sharp. `FrameRenderer.sampleCount` turns on MSAA, with `supportsSampleCount(_:)` and `effectiveSampleCount`.
- **Opaque textures**: a game that returns `true` from `wantsOpaqueTextures` gets `encodeTransparent(into:opaque:frameSlot:…)` with `OpaqueTextures`, a copy of the solid scene's colour and depth to draw over, for water and refraction.
- **Compressed textures**: set `TextureStore.compressionCache` to a folder and textures are compressed to ASTC 4×4 the first time they load, then read back from that cache. `CompressedTextures` exposes the encoder and KTX loader. `TextureStore.quality` loads textures at full, half or quarter size.
- **Alpha cut-outs**: `Material.alphaCutoff` stops drawing pixels below a threshold, and they cast no shadow either. It is read from glTF mask materials and from USD opacity maps.
- **Frame checks and timing**: `FrameRenderer.pngFrame(width:height:)` draws a frame off screen as PNG, and `timeFrames(width:height:count:warmUp:)` times off-screen frames. `FrameRenderer.lastFrameTimes` gives each frame's interval, CPU time and GPU time (`FrameTimes`), and `FrameTimesAverage` averages them for a readout.
- **Flythrough benchmarks**: `Flythrough`, `FlythroughRun` and `FlythroughReport` fly a fixed, ground-following camera route. They report frame costs per leg and per pass, including passes with one feature switched off and a baseline flown again to show drift. `FrameRenderer.flyThrough(_:passes:width:height:framesPerSecond:ground:place:switchPass:)` runs one off screen.
- **Memory readout**: `MemoryUse.measure(device:)` reports the process footprint and graphics memory against the device's budget.
- **Music**: `MusicPlayer` plays a score with a fade-in on start, a fade on `stop(fade:)`, and quiet while the app is in the background. `apply(_:)` takes the player's `PlayerSettings`.
- **Audio mixing**:
  - `AudioEngine.effectsVolume` sets every one-shot's level, beside `loopVolume` and under `masterVolume`.
  - `apply(_:)` sets all of them from `PlayerSettings`.
  - `playsInBackground` keeps sound playing while the game isn't the front app.
  - `startMetering()` and `readPeak(resetting:)` measure the mix.
- **Audio playback and loading**:
  - `play(_:volume:pan:rate:)` adds pan and pitch to unplaced sounds, which now play in their own channels at any sample rate.
  - `startAmbience(_:volume:)` and `setAmbienceVolume(_:to:)` play beds heard everywhere, such as wind or rain.
  - `load(_:url:)` loads a single file, and `load(_:)` loads many off the main thread.
  - `isLoaded(_:)` and `duration(of:)` report on loaded sounds.
- **Sound variation**: `SoundVariation` picks among takes of a sound without repeating and adds a little pitch and gain spread, so one recording sounds like many.
- **Controller calibration**: `PadMeasurement` measures each stick's resting point and dead zone. The results are stored as `StickCalibration` and `PadCalibration` in `PlayerSettings.padCalibration`. `StickResponse.shaped(_:calibration:exponent:)` uses them and gives back the travel a drifting stick loses.
- **Pad and input tracking**:
  - `InputState.rawSticks` gives the raw stick readings.
  - `isPadReportFrozen` (backed by `FrozenStickWatch`) flags a pad that keeps repeating one reading.
  - `lastDevice` and `noteKeyboardUse()` let button prompts follow the device actually in use.
  - `acceptsPadSticks` stops the sticks moving the player while a menu or chat box has the pad.
  - `releaseKeys()` lets go of every held key.
- **Player settings**: `PlayerSettings` adds `invertMouseHorizontal`, `invertStickHorizontal`, `sprintsByDefault` (the keyboard sprints unless Shift is held), `effectsVolume`, `musicVolume` and `soundInBackground`. Settings saved by earlier versions still decode.
- **D-pad and options bindings**: `PadButton` gains `.dpadUp`, `.dpadDown`, `.dpadLeft`, `.dpadRight` and `.options`, plus `PadButton.actionButtons` and `isDirection`.
- **Camera speed and boost**: `Camera.Tuning.speedScale` and `stepSpeedScale(_:)` step the speed along `Camera.speedScales`. `boost` and `boostTime` build speed while a direction is held, and `Camera.boostNow` and `heldFor` read it back.
- **Particle look**:
  - Sprites from an atlas (`ParticleRenderer` `sprites:atlas:`, `ParticleRecipe.sprite`).
  - Velocity- or axis-aligned and stretched quads (`alignment`, `axis`, `stretch`, `aspect`).
  - Light shafts from a `DaySky` (`shafts(of:)`).
- **Particle motion and spawning**:
  - Motion: `wander`, `wanderRate` and `maxSpeed`.
  - Fading: `fadeIn`, `fadeOut` and `flapRate`.
  - Spawning on a disc: `spawnRadius` and `spawnsLevel`.
  - `prewarm` starts emitters already running.
- **Particle renderer and recipe options**: `ParticleRenderer` takes a `colorPixelFormat` and a `sampleCount`, and `ParticleRecipe` is now `Codable`.
- **Feathered HUD edges**: `HUDRenderer.line` and `fillRing` take a `feather:` parameter.
- **Frustum containment**: `Frustum.contains(_:)` tests whether a whole box is inside the frustum.
- **Pre-sorted instances**: `InstanceBatches.init(transforms:runs:)` takes copies that are already grouped by kind.
- **Partial shadows**:
  - `ShadowMap.encode(into:frameSlot:batches:castingCascades:)` draws casters into only the nearer cascades.
  - `ShadowMap.cascades` can be updated in place, as long as the count and resolution stay the same.
  - The shadow pipeline descriptor accepts a `fragmentFunction`, for cut-out casters.

### Changed

- **Breaking:** an `AudioEngine` now goes silent while the app isn't the front app. Set `playsInBackground = true`, or pass `PlayerSettings.soundInBackground`, to keep it playing.
- **Breaking:** `PadButton` has five new cases, so a `switch` over `PadButton` with no `default` no longer compiles. Add the d-pad and `.options` cases, or a `default`.
- **Breaking:** `HUDRenderer.line(from:to:thickness:color:)` and `fillRing(center:innerRadius:outerRadius:segments:color:)` now feather their edges by one HUD unit by default. Pass `feather: 0` to keep hard edges.
- **Breaking:** a USD material whose opacity comes from a texture is now drawn as an alpha cut-out at 0.5 (`Material.alphaCutoff`) rather than solid. Set `alphaCutoff = nil` to draw it solid again.
- **Breaking:** `AudioEngine.play(_:volume:)` no longer goes through the 3D spatializer. Stereo sounds now play in stereo, and when every voice for a format is busy, the oldest is cut.
- **Breaking:** if Metal stops running the app's GPU work after a fault, the app now stops with the first fault as the reason, instead of waiting forever. A frame the GPU dropped is no longer waited for.
- **Performance and stability improvements**: faster model loading, because textures are no longer decoded once per mesh. Collision meshes build faster, and character steps only test nearby solids. Particle systems reuse dead slots. Audio starts off the main thread, and GPU faults are now written to the log.

### Fixed

- **Walking on a turning platform**: a body walking across ground that turns now moves the way the view faces after the turn, instead of a step behind. The path no longer changes with the frame rate.
- **Sideways drift after landing**: a body landing from a sideways shove no longer carries on drifting for the rest of the step.
- **Sun angles in saved levels**: `ProceduralSky.sunPitchDegrees` and `sunYawDegrees` read back the values they were given. A sun set at yaw 295 no longer comes back as −65.00003.
- **Compressed texture upload**: compressed texture data is now uploaded at the 16-byte alignment Metal's validation requires.

## [1.1.0] — 2026-10-23

### Added

- **glTF and GLB loading** — `MeshLoader` now loads `.gltf` and `.glb` the way it loads USD: meshes placed by their
  nodes, metallic-roughness materials with their textures, and compressed files (meshopt, Draco, quantized
  attributes, KTX2 textures through Basis Universal). Skins and animation are not read; a skinned mesh arrives in
  its bind pose. A file requiring an extension the engine does not read is refused with `GLTFError`.
- **`ImportedModel`**, `ImportedMesh`, `ImportedMaterial`, `ImportedTextureReference` and `ImportedTexture` — a
  model as plain values, for a tool that wants what a file holds without drawing it. `ImportedModel.read(gltf:)` and
  `MeshLoader.model(url:)` make one from glTF; `MeshLoader.load(model:named:device:vertexDescriptor:semantics:)` draws one a game's own
  reader made.
- Google's Draco decoder (Apache 2.0) and Binomial's Basis Universal transcoder with Zstandard (Apache 2.0 and BSD)
  are vendored for this and linked into every game built with the engine, so **a game ships their licenses**
  beside meshoptimizer's — in `Sources/Draco` and `Sources/Basis`.
- **`TextureStore.forget(file:)`** — drops the textures loaded from a file, or from inside a `.usdz`, so the next
  request reads it again. For an editor whose files are exported over while it runs.

### Fixed

- **Archiving for the Mac App Store** — the engine now compiles for Intel as well as Apple silicon, so a game's
  universal Release build or archive no longer fails on `Float16`, which Swift does not have on Intel. Metal 4
  still needs Apple silicon to run; nothing draws differently.
- **Textures inside a `.usdz` file** — they drew white, because the texture's address was the package itself. They
  now load from inside the package. A packed texture's `TextureSource.url` is the `.usdz` with the texture's path in
  the package as its fragment.

## [1.0.0] — 2026-10-14

**Initial release.** A Swift 6 and Metal 4 game engine for the Mac, extracted from working games.

### Added

- **Frame pacing:** frames in flight, a fixed simulation step, and a clock that keeps time with the window
  hidden. `GameLoop`, `FrameRenderer`, `FixedTimestep`.
- **Rendering:** reversed-Z depth, an HDR scene with tone mapping and exposure in stops, physically based
  materials (base color, normal, occlusion–roughness–metallic and emission maps), and image-based lighting
  from the sky.
- **Light and shadow:** cascaded sun shadows, and spot and point lights binned into clusters, each able to
  cast. `ShadowMap`, `ClusteredLights`.
- **Meshes:** loading through Model I/O, with USD's orientation and units handled. `MeshLoader`.
- **Many copies:** instanced drawing, one draw per kind of prop. `InstanceBatches`, `InstanceBuffer`.
- **Detail by distance:** simpler tiers of every mesh made when it loads, and the tier a copy's distance
  earns. `MeshDetail`, using meshoptimizer's simplifier (MIT).
- **Culling:** frustum culling for the screen and for each shadow cascade. `Frustum`.
- **Characters:** skinned animation from USD, cross-fades, and things hung off joints. `SkeletonPose`,
  `TransformHierarchy`.
- **A body with feet:** stairs, slopes, lifts, turntables and being pushed, with the same result at any
  step rate. `CharacterController`.
- **Particles:** sparks, embers and dust, simulated on the fixed step and drawn in one instanced draw.
  `ParticleSystem`.
- **Levels:** a versioned level format, and an editor you use inside your running game. `Level`,
  `LevelEditor`.
- **Sound:** positional audio and looping ambience that belongs to a place. `AudioEngine`.
- **Input and settings:** keys and controllers a player rebinds, per-device sensitivity, dead zones and
  invert, and settings that save. `InputBindings`, `SaveStore`.
- **The HUD:** text and shapes drawn after the tone map. `HUDRenderer`.
- **Your game's name:** a splash screen and the engine's mark. `SplashScreen`, `EngineMark`.
- **Checks:** a frame drawn into a texture of your own, and a sample that runs headless and scripted, so a
  change that moves the player or the picture can fail a check instead of going unnoticed.
  `FrameRenderer.render(into:)`.
- **A sample game** built only against the public API. `swift run WindageSample`.

[1.3.0]: https://github.com/PixlaGames/WindageEngine/releases/tag/1.3.0
[1.2.0]: https://github.com/PixlaGames/WindageEngine/releases/tag/1.2.0
[1.1.0]: https://github.com/PixlaGames/WindageEngine/releases/tag/1.1.0
[1.0.0]: https://github.com/PixlaGames/WindageEngine/releases/tag/1.0.0
