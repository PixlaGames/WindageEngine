# Changelog

Every release of Windage Engine, newest first. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[1.1.0]: https://github.com/PixlaGames/WindageEngine/releases/tag/1.1.0
[1.0.0]: https://github.com/PixlaGames/WindageEngine/releases/tag/1.0.0
