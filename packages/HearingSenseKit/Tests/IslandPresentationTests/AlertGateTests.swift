import Foundation
import IslandPresentation
import Testing

@Suite struct AlertGateTests {
    @Test func theLockStateIsOnlyKnownWithAPasscode() {
        func estimate(_ passcode: Bool?, _ available: Bool, _ observed: Bool = true) -> DeviceLockEstimate {
            DeviceLockEstimate.estimate(passcodeSet: passcode, protectedDataAvailable: available, lockSignalObserved: observed)
        }
        #expect(estimate(true, true) == .unlocked)
        #expect(estimate(true, false) == .locked)
        #expect(estimate(false, true) == .unknown)
        #expect(estimate(nil, true) == .unknown)
        #expect(estimate(nil, false) == .unknown)
    }

    /// The iOS Simulator reports a passcode and available data while it is locked: "available"
    /// means nothing until the signal has been seen to change on this installation.
    @Test func availableDataMeansNothingUntilTheSignalWasSeenToChange() {
        #expect(DeviceLockEstimate.estimate(passcodeSet: true, protectedDataAvailable: true, lockSignalObserved: false) == .unknown)
        #expect(DeviceLockEstimate.estimate(passcodeSet: true, protectedDataAvailable: false, lockSignalObserved: false) == .locked)
    }

    @Test func expansionIsOffUnlessTheUserTurnsItOn() {
        #expect(IslandSettings.default.expandsForImportantEvents == false)
        #expect(AlertGate.evaluate(settings: .default, lock: .unlocked, appIsActive: false) == .blocked(.disabledInSettings))
    }

    @Test func anAlertIsSentOnlyWhenTheDeviceIsJudgedUnlocked() {
        var settings = IslandSettings.default
        settings.expandsForImportantEvents = true
        #expect(AlertGate.evaluate(settings: settings, lock: .unlocked, appIsActive: false) == .send)
        #expect(AlertGate.evaluate(settings: settings, lock: .locked, appIsActive: false) == .blocked(.deviceLocked))
        #expect(AlertGate.evaluate(settings: settings, lock: .unknown, appIsActive: false) == .blocked(.lockStateUnknown))
        #expect(AlertGate.evaluate(settings: settings, lock: .unlocked, appIsActive: true) == .blocked(.appInForeground))
    }

    @Test func theSettingTurnsExpansionOffEverywhere() {
        var settings = IslandSettings.default
        settings.expandsForImportantEvents = false
        for lock in [DeviceLockEstimate.unlocked, .locked, .unknown] {
            #expect(AlertGate.evaluate(settings: settings, lock: lock, appIsActive: false) == .blocked(.disabledInSettings))
        }
    }

    @Test func storedSettingsFromAnOlderBuildKeepTheirDefaults() throws {
        let decoded = try JSONDecoder().decode(IslandSettings.self, from: Data(#"{"showsAmbientIcons":false}"#.utf8))
        var expected = IslandSettings.default
        expected.showsAmbientIcons = false
        #expect(decoded == expected)
        #expect(IslandSettings.default.playsAlertSound == false)
    }
}
