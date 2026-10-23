// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WindageEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WindageEngine", targets: ["WindageEngine"]),
        // **The sample is a product, not a test fixture.** `swift run WindageSample` is the first
        // thing somebody who cloned this repo should be able to do.
        .executable(name: "WindageSample", targets: ["WindageSample"]),
    ],
    targets: [
        // meshoptimizer's simplifier, for level of detail (`MeshDetail`): C++, vendored unmodified from the 1.3
        // release (MIT, LICENSE beside it) — `simplifier.cpp`, the `allocator.cpp` it needs, and the header.
        // The one part of the engine not written in Swift: it is the simplifier gltfpack and most engines use,
        // and a reimplementation would be slower and less trustworthy. **An app shipping `MeshDetail` ships
        // its license.**
        .target(
            name: "MeshOptimizer",
            exclude: ["LICENSE.md"]
        ),
        // Google's Draco decoder, for glTF's KHR_draco_mesh_compression: C++, vendored unmodified from the 1.5.7
        // release (Apache 2.0, LICENSE beside it), behind a small C interface of the engine's own (`WEDraco`).
        // The reference decoder is what every serious glTF reader uses; a reimplementation would be months of
        // work and less trustworthy. `draco_features.h` is written here in place of the one Draco's CMake makes.
        .target(
            name: "Draco",
            exclude: ["LICENSE"],
            // **Silenced by name, and through the safe setting rather than a compiler flag.** Xcode warns about
            // 64-to-32-bit conversions that Draco's own build does not, and the code is Google's, unmodified.
            // `unsafeFlags` would do the same and make the package unusable by URL: SwiftPM refuses a dependency
            // fetched from a repository if any target in it uses them.
            cxxSettings: [.headerSearchPath("src"), .disableWarning("shorten-64-to-32")]
        ),
        // Binomial's Basis Universal transcoder, for glTF's KHR_texture_basisu (KTX2 textures): C++, vendored
        // unmodified from the 2.50 release with Meta's Zstandard decoder beside it (Apache 2.0 and BSD — LICENSE,
        // NOTICE and LICENSES/), behind a small C interface of the engine's own (`WEBasis`). The same decision as
        // Draco's. The excluded files are included by the transcoder's source rather than compiled on their own.
        .target(
            name: "Basis",
            exclude: ["LICENSE", "NOTICE", "LICENSES", "src/transcoder/basisu_astc_cfgs.inl",
                      "src/transcoder/basisu_dds_transcoder.inl", "src/transcoder/basisu_etc1_mods.inl",
                      "src/transcoder/basisu_xbc7_decoder.inl", "src/transcoder/basisu_transcoder_tables_astc.inc",
                      "src/transcoder/basisu_transcoder_tables_astc_0_255.inc",
                      "src/transcoder/basisu_transcoder_tables_atc_55.inc", "src/transcoder/basisu_transcoder_tables_atc_56.inc",
                      "src/transcoder/basisu_transcoder_tables_bc7_m5_alpha.inc",
                      "src/transcoder/basisu_transcoder_tables_bc7_m5_color.inc",
                      "src/transcoder/basisu_transcoder_tables_dxt1_5.inc", "src/transcoder/basisu_transcoder_tables_dxt1_6.inc",
                      "src/transcoder/basisu_transcoder_tables_pvrtc2_45.inc",
                      "src/transcoder/basisu_transcoder_tables_pvrtc2_alpha_33.inc"],
            cSettings: [.define("BASISD_SUPPORT_KTX2", to: "1"), .define("BASISD_SUPPORT_KTX2_ZSTD", to: "1")],
            cxxSettings: [.headerSearchPath("src"), .define("BASISD_SUPPORT_KTX2", to: "1"),
                          .define("BASISD_SUPPORT_KTX2_ZSTD", to: "1")]
        ),
        .target(
            name: "WindageEngine",
            dependencies: ["MeshOptimizer", "Draco", "Basis"],
            // Declared so SwiftPM synthesises `Bundle.module`, which the HUD and tone-map pipelines
            // load their shaders from. Xcode compiles the .metal into the same bundle as `default.metallib`;
            // SwiftPM's CLI does not compile Metal at all, which is why `swift test` can build the
            // package but cannot exercise anything needing a GPU.
            resources: [.copy("HUDShaders.metal"), .copy("ToneMapShaders.metal"),
                        .copy("ParticleShaders.metal")],
            swiftSettings: [
                // Matches the game targets: everything is main-actor by default unless it says
                // otherwise. Engine types that must run off the main thread say `nonisolated`
                // explicitly, which is a decision worth having to write down.
                .defaultIsolation(MainActor.self)
            ]
        ),
        // A complete, deliberately dull game built against the engine's **public API only**.
        //
        // It is the standing check that the engine is usable by someone who did not write it: if
        // the sample cannot be built without reaching inside, the API is wrong. It found its first
        // one immediately — `swift build` compiles no Metal, so nothing that loaded a default
        // library could start outside Xcode. See `ShaderLibrary`.
        // **The sample's logic, split out of its app the way the studio requires of a title.**
        // A game loop, a save format and a level's contents need no window, so they live where
        // `swift test` can reach them — and the sample demonstrating the recommended shape is worth
        // more than the fifty lines it costs.
        .target(
            name: "WindageSampleCore",
            dependencies: ["WindageEngine"],
            // **The levels are files, and this is where they ship from.** `.process` rather than
            // `.copy` so they land flat in the bundle, which is where `Level.load(named:bundle:)`
            // looks — the same arrangement a title uses.
            resources: [.process("Resources")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "WindageSampleCoreTests",
            dependencies: ["WindageSampleCore"]
        ),
        .executableTarget(
            name: "WindageSample",
            dependencies: ["WindageEngine", "WindageSampleCore"],
            // `.copy` and not `.process`: the shader **source** has to survive into the bundle so it
            // can be compiled at runtime when no metallib exists.
            resources: [.copy("SampleShaders.metal"), .process("Resources")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "WindageEngineTests",
            dependencies: ["WindageEngine"],
            // A rig and a textured-material fixture, so the loaders are tested against real files
            // rather than mocks of them. Neither a skeleton nor a material's numbers need a GPU,
            // which is the whole reason `RigLoader` and `Material` are split from the halves that
            // do — see their doc comments.
            resources: [.process("Resources")]
        )
    ],
    // Draco and Basis Universal are C++17; meshoptimizer is happy with anything since C++98.
    cxxLanguageStandard: .cxx17
)
