import Testing
@testable import MacDuo

struct LidEffectPolicyTests {
    private let highThreshold = LidEffectPolicy(threshold: 130, hysteresis: 4)

    @Test
    func testOpeningReleasesWithoutReachingHysteresisAngle() {
        #expect(activeEffect(angle: 129, opening: false))
        #expect(!activeEffect(angle: 130, opening: true, minimumDurationElapsed: false))
        #expect(!activeEffect(angle: 131, opening: true))
        #expect(!activeEffect(angle: 133, opening: true))
    }

    @Test
    func testStationaryLidBelowThresholdKeepsActiveEffect() {
        #expect(activeEffect(angle: 129, opening: false))
    }

    @Test
    func testJitterAroundThresholdUsesOrdinaryHysteresis() {
        #expect(activeEffect(angle: 129.8, opening: false))
        #expect(activeEffect(angle: 130.2, opening: false))
        #expect(activeEffect(angle: 129.9, opening: false))
    }

    @Test
    func testOrdinaryConfigurationStillReleasesAtHysteresisAngle() {
        let policy = LidEffectPolicy(threshold: 90, hysteresis: 4)

        #expect(wantsActiveEffect(policy: policy, angle: 93.9, opening: false))
        #expect(!wantsActiveEffect(policy: policy, angle: 94, opening: false))
    }

    @Test
    func testOpeningReversalInvalidatesClosingMemory() {
        var intent = LidMotionIntent()
        intent.update(angularVelocity: -3, at: 10, closingSpeed: 2, openingSpeed: 2)
        #expect(intent.wasClosingRecently(at: 10.1, memoryDuration: 1.5))

        intent.update(angularVelocity: 3, at: 10.2, closingSpeed: 2, openingSpeed: 2)
        #expect(!intent.wasClosingRecently(at: 10.2, memoryDuration: 1.5))

        // A sub-threshold jitter sample must not restore closing intent.
        intent.update(angularVelocity: -0.4, at: 10.3, closingSpeed: 2, openingSpeed: 2)
        #expect(!intent.wasClosingRecently(at: 10.3, memoryDuration: 1.5))
        #expect(
            !highThreshold.wantsEffect(
                isEnabled: true,
                isActive: false,
                angle: 129.9,
                predictedAngle: 129.9,
                riseSinceLowest: 0,
                hasBeenAboveThreshold: true,
            isReArmed: true,
                wasClosingRecently: intent.wasClosingRecently(at: 10.3, memoryDuration: 1.5),
                isClearlyOpening: false,
                hasDwelledOpen: false,
                minimumDurationElapsed: true
            )
        )
    }

    @Test
    func testRestingBelowThresholdDoesNotActivate() {
        #expect(
            !highThreshold.wantsEffect(
                isEnabled: true,
                isActive: false,
                angle: 129,
                predictedAngle: 129,
                riseSinceLowest: 0,
                hasBeenAboveThreshold: true,
            isReArmed: true,
                wasClosingRecently: false,
                isClearlyOpening: false,
                hasDwelledOpen: false,
                minimumDurationElapsed: true
            )
        )
    }

    @Test
    func testSlowOpeningReleasesAfterDwell() {
        #expect(activeEffect(angle: 133, opening: false))
        #expect(!activeEffect(angle: 133, opening: false, dwelled: true))
    }

    @Test
    func testDwellAngleIsTheThreshold() {
        // A hinge whose limit rounds to the threshold must still release.
        #expect(highThreshold.dwellAngle == 130)
    }

    @Test
    func testDwellRestartsWhenLidDropsBelowDwellAngle() {
        let dwellAngle = highThreshold.dwellAngle
        var dwell = LidOpenDwell()
        dwell.update(angle: 130, at: 10, dwellAngle: dwellAngle)
        #expect(!dwell.hasDwelled(at: 10.5, duration: 1))
        #expect(dwell.hasDwelled(at: 11, duration: 1))

        // Jitter back below the start angle restarts the wait.
        dwell.update(angle: 129.5, at: 11.1, dwellAngle: dwellAngle)
        dwell.update(angle: 130, at: 11.2, dwellAngle: dwellAngle)
        #expect(!dwell.hasDwelled(at: 12, duration: 1))
    }

    @Test
    func testOneWholeDegreeStepDoesNotReleaseOnOpening() {
        // A whole-degree sensor resting on a half-degree boundary alternates
        // 129/130. The step reads as fast opening, but the rise is only 1°.
        #expect(activeEffect(angle: 130, opening: true, rise: 1))
        #expect(activeEffect(angle: 130, opening: true, rise: 1, minimumDurationElapsed: false))
    }

    @Test
    func testRiseAboveOneStepReleasesOnOpening() {
        #expect(!activeEffect(angle: 130, opening: true, rise: LidEffectPolicy.minimumReleaseRise))
        #expect(!activeEffect(angle: 130.9, opening: true, rise: 70))
    }

    @Test
    func testSmallOpeningStillReleasesThroughDwell() {
        // Too small a rise for the speed release, but held above the threshold.
        #expect(!activeEffect(angle: 130, opening: false, dwelled: true, rise: 1))
    }

    private func activeEffect(
        angle: Double,
        opening: Bool,
        dwelled: Bool = false,
        rise: Double = 40,
        minimumDurationElapsed: Bool = true
    ) -> Bool {
        wantsActiveEffect(
            policy: highThreshold,
            angle: angle,
            opening: opening,
            dwelled: dwelled,
            rise: rise,
            minimumDurationElapsed: minimumDurationElapsed
        )
    }

    private func wantsActiveEffect(
        policy: LidEffectPolicy,
        angle: Double,
        opening: Bool,
        dwelled: Bool = false,
        rise: Double = 40,
        minimumDurationElapsed: Bool = true
    ) -> Bool {
        policy.wantsEffect(
            isEnabled: true,
            isActive: true,
            angle: angle,
            predictedAngle: angle,
            riseSinceLowest: rise,
            hasBeenAboveThreshold: true,
            isReArmed: true,
            wasClosingRecently: false,
            isClearlyOpening: opening,
            hasDwelledOpen: dwelled,
            minimumDurationElapsed: minimumDurationElapsed
        )
    }
}

/// Rocking the lid around the start angle used to replay the whole effect:
/// releasing is direction-aware, so opening across the angle ends a run at
/// once, and closing back across it started another just as fast. Measured on
/// a real lid at a 105 degree start angle, runs ended at 106 and restarted at
/// 102 within 633 ms.
struct ReArmTests {

    private let policy = LidEffectPolicy(threshold: 105, hysteresis: 4)

    private func wantsStart(at angle: Double, reArmed: Bool) -> Bool {
        policy.wantsEffect(
            isEnabled: true,
            isActive: false,
            angle: angle,
            predictedAngle: angle,
            riseSinceLowest: 0,
            hasBeenAboveThreshold: true,
            isReArmed: reArmed,
            wasClosingRecently: true,
            isClearlyOpening: false,
            hasDwelledOpen: false,
            minimumDurationElapsed: true
        )
    }

    @Test func aRunThatJustEndedDoesNotStartAnother() {
        #expect(wantsStart(at: 102, reArmed: false) == false)
    }

    @Test func openingClearlyPastTheAngleArmsItAgain() {
        #expect(wantsStart(at: 102, reArmed: true))
    }

    @Test func theReArmIsWiderThanTheJitterItIsThereFor() {
        // The lid readings dither by hundredths; three degrees is well clear,
        // and still inside what a hinge can reach above a sensible start angle.
        #expect(LidEffectPolicy.reArmRise > 1)
        #expect(LidEffectPolicy.reArmRise < LidEffectPolicy.minimumReleaseRise * 4)
    }
}
