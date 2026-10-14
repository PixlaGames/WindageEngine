//
//  SplashScreenTests.swift
//  WindageEngineTests
//

import Testing
@testable import WindageEngine

@Suite("The engine's splash")
struct SplashScreenTests {

    /// Run one from nothing to `seconds`, stepping `rate` times a second, with an optional press.
    private func run(to seconds: Float, at rate: Float, pressingAt press: Float? = nil) -> SplashScreen {
        var splash = SplashScreen()
        let dt = 1 / rate
        var t: Float = 0
        while t < seconds - dt / 2 {
            if let press, t >= press, t - dt < press { splash.skip() }
            splash.advance(by: dt)
            t += dt
        }
        return splash
    }

    @Test("It fades up, holds, fades away, and then has nothing left to draw")
    func theShape() {
        var splash = SplashScreen()
        #expect(splash.opacity == 0, "it starts at \(splash.opacity), so its first frame is a flash")
        splash.advance(by: splash.fadeIn / 2)
        #expect(abs(splash.opacity - 0.5) < 1e-5, "half way up it is \(splash.opacity)")
        splash.advance(by: splash.fadeIn / 2 + splash.hold / 2)
        #expect(splash.opacity == 1)
        splash.advance(by: splash.hold / 2 + splash.fadeOut / 2)
        #expect(abs(splash.opacity - 0.5) < 1e-5, "half way down it is \(splash.opacity)")
        splash.advance(by: splash.fadeOut / 2)
        #expect(splash.opacity == 0 && splash.isFinished)
    }

    /// **The same picture at the same moment, however often the game steps.** Everything here is
    /// linear in a sum of step lengths, which is the cheapest way to be rate-independent and the
    /// reason to reach for a ramp rather than an ease when a fade is only a fade.
    @Test("Its opacity at a moment is the same at any step rate", arguments: [Float(30), 60, 120, 240])
    func sameAtAnyRate(rate: Float) {
        for moment in [Float(0.2), 0.4, 1.0, 2.2, 2.4] {
            let mine = run(to: moment, at: rate).opacity
            let reference = run(to: moment, at: 1000).opacity
            #expect(abs(mine - reference) < 1e-3,
                    "at \(rate) a second, \(moment) s in it was \(mine) where it is \(reference)")
        }
    }

    /// **A press on the first frame is the press that launched the game.** Without this the splash is
    /// skipped before it has been seen once, which reads as the engine's mark never having been drawn.
    @Test("A press too early is not a skip")
    func tooEarly() {
        var splash = SplashScreen()
        splash.advance(by: splash.skipDelay / 2)
        splash.skip()
        #expect(!splash.isSkipped && splash.opacity > 0 && splash.elapsed < splash.fadeIn,
                "a press \(splash.skipDelay / 2) s in took it to \(splash.elapsed)")
    }

    /// A skip runs it to the *start of its fade*, so it leaves the way it would have anyway. Cutting
    /// straight to nothing is indistinguishable from a dropped frame.
    @Test("A skip fades out rather than cutting")
    func skipFades() {
        var splash = SplashScreen()
        splash.advance(by: 0.8)
        splash.skip()
        #expect(splash.isSkipped)
        #expect(splash.opacity == 1, "the frame it was skipped on drew at \(splash.opacity)")
        #expect(!splash.isFinished)
        splash.advance(by: splash.fadeOut / 2)
        #expect(abs(splash.opacity - 0.5) < 1e-5, "half a fade later it is \(splash.opacity)")
        splash.advance(by: splash.fadeOut / 2)
        #expect(splash.isFinished)
    }

    /// Leaning on a key must not shorten the fade twice over.
    @Test("Skipping again while it is already going does nothing")
    func skipTwice() {
        var splash = SplashScreen()
        splash.advance(by: 0.8)
        splash.skip()
        let afterFirst = splash.elapsed
        splash.advance(by: splash.fadeOut / 2)
        splash.skip()
        #expect(abs(splash.elapsed - (afterFirst + splash.fadeOut / 2)) < 1e-5,
                "a second press moved it to \(splash.elapsed)")
    }

    /// It ends, and stays ended: a game that keeps stepping a finished splash must not see the clock
    /// run away and the opacity come back.
    @Test("It never runs past its own end")
    func stopsAtTheEnd() {
        var splash = SplashScreen()
        splash.advance(by: 60)
        #expect(splash.elapsed == splash.duration && splash.opacity == 0 && splash.isFinished)
    }

    /// **The defaults are taste, and these are the two things taste is not allowed to break.** Every
    /// other test here checks the *shape* — a ramp, a hold, a ramp — against whatever the numbers are,
    /// which is right, and which means a fat finger on one of them changes nothing anywhere. A splash
    /// nobody can get past is the commonest complaint players have about them, and a fade longer than
    /// the thing it is fading is a fade nobody reads as one.
    @Test("A splash a player would forgive")
    func withinReason() {
        let splash = SplashScreen()
        #expect(splash.duration <= 3, "it lasts \(splash.duration) s before anybody presses anything")
        #expect(splash.fadeIn + splash.fadeOut < splash.hold,
                "it spends \(splash.fadeIn + splash.fadeOut) s fading and \(splash.hold) s being read")
        #expect(splash.skipDelay < splash.fadeIn,
                "it cannot be skipped until \(splash.skipDelay) s, by which time it has finished appearing")
    }

    /// The name it draws is the engine's, from the one place that holds it.
    @Test("It says the engine's own name and version")
    func saysTheName() {
        #expect(Engine.name == "Windage Engine")
        #expect(Engine.version == Engine.semanticVersion.description)
    }

    /// No engine shows its version on a shipped game's splash; a development build turns it on.
    @Test("The version is off unless a game asks for it")
    func noVersion() {
        #expect(!SplashScreen().showsVersion)
    }
}
