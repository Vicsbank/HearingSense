#if DEBUG
import Foundation
@testable import HearingSenseAudio
import Testing

struct DeviceTestConfigurationTests {
    private func stored(_ configuration: DeviceTestConfiguration) throws -> Data {
        try JSONEncoder().encode(configuration)
    }

    // MARK: - Fail-closed

    @Test func nothingStoredIsLocked() {
        let (configuration, origin) = DeviceTestConfiguration.resolve(nil)
        #expect(origin == .missing)
        #expect(configuration == .locked)
        #expect(configuration.prohibitsMicrophone)
        #expect(configuration.prohibitsTranscription)
        #expect(configuration.prohibitsModelInference)
        #expect(configuration.effectiveSessionLimit == 180)
        #expect(configuration.exportsDiagnostics)
    }

    @Test func damagedDataIsLocked() {
        for text in ["", "x", "{}", #"{"version":1}"#, #"{"version":1,"isEnabled":false}"#, "[true]"] {
            let (configuration, origin) = DeviceTestConfiguration.resolve(Data(text.utf8))
            #expect(origin == .unreadable, "\(text)")
            #expect(configuration == .locked, "\(text)")
        }
    }

    @Test func anotherVersionIsLockedWhateverItAllows() throws {
        var other = DeviceTestConfiguration(isEnabled: false, allowsMicrophone: true, allowsTranscription: true,
                                            allowsModelInference: true)
        other.version = DeviceTestConfiguration.currentVersion + 1
        let (configuration, origin) = try DeviceTestConfiguration.resolve(stored(other))
        #expect(origin == .unreadable)
        #expect(configuration == .locked)
    }

    @Test func aStoredRecordIsUsedAsStoredWithItsLimitInRange() throws {
        let allowed = DeviceTestConfiguration(allowsMicrophone: true, sessionLimit: 100_000)
        let (configuration, origin) = try DeviceTestConfiguration.resolve(stored(allowed))
        #expect(origin == .stored)
        #expect(!configuration.prohibitsMicrophone)
        #expect(configuration.prohibitsTranscription)
        #expect(configuration.sessionLimit == 600)
        #expect(try DeviceTestConfiguration.resolve(stored(DeviceTestConfiguration(sessionLimit: 0))).configuration.sessionLimit == 10)
    }

    // MARK: - Rules

    @Test func lockedNeverGivesTheMicrophone() {
        for source in [ListeningRequestSource.app, .intent, .automation] {
            #expect(DeviceTestConfiguration.locked.capture(for: source) == .synthetic)
        }
    }

    @Test func aStartByAScriptIsNeverARecording() {
        let allowed = DeviceTestConfiguration(allowsMicrophone: true)
        #expect(allowed.capture(for: .app) == .microphone)
        #expect(allowed.capture(for: .intent) == .microphone)
        #expect(allowed.capture(for: .automation) == .synthetic)
    }

    @Test func transcriptionNeedsTheMicrophone() {
        let onlyTranscription = DeviceTestConfiguration(allowsTranscription: true)
        #expect(onlyTranscription.prohibitsTranscription)
        #expect(!DeviceTestConfiguration(allowsMicrophone: true, allowsTranscription: true).prohibitsTranscription)
    }

    @Test func theEmergencyStopRefusesEveryStartAndProhibitsEverything() {
        let halted = DeviceTestConfiguration(allowsMicrophone: true, allowsTranscription: true, allowsModelInference: true,
                                             isHalted: true)
        for source in [ListeningRequestSource.app, .intent, .automation] {
            #expect(halted.capture(for: source) == .refused)
        }
        #expect(halted.prohibitsMicrophone)
        #expect(halted.prohibitsTranscription)
        #expect(halted.prohibitsModelInference)
    }

    @Test func offRestrictsNothing() {
        let off = DeviceTestConfiguration(isEnabled: false, isHalted: true)
        #expect(off.capture(for: .automation) == .microphone)
        #expect(!off.prohibitsMicrophone)
        #expect(!off.prohibitsTranscription)
        #expect(!off.prohibitsModelInference)
        #expect(off.effectiveSessionLimit == nil)
        #expect(off.summary(origin: .stored) == "off")
    }

    // MARK: - Commands

    @Test func noArgumentsChangeNothing() {
        let (configuration, notes) = DeviceTestConfiguration.locked.applying(arguments: ["app", "--hs-autostart"])
        #expect(configuration == .locked)
        #expect(notes.isEmpty)
    }

    @Test func permissionsAreOnlyAddedByName() {
        let (configuration, notes) = DeviceTestConfiguration.locked
            .applying(arguments: ["--hs-test-allow", "microphone,everything", "--hs-test-session-limit", "60"])
        #expect(configuration.allowsMicrophone)
        #expect(!configuration.allowsTranscription)
        #expect(!configuration.allowsModelInference)
        #expect(configuration.sessionLimit == 60)
        #expect(notes.contains("unknown permission “everything” ignored"))
    }

    @Test func unknownCommandsChangeNothing() {
        for arguments in [["--hs-test-mode", "open"], ["--hs-test-mode"], ["--hs-test-session-limit", "soon"],
                          ["--hs-test-session-limit", "-5"], ["--hs-test-allow"]] {
            #expect(DeviceTestConfiguration.locked.applying(arguments: arguments).configuration == .locked, "\(arguments)")
        }
    }

    @Test func stopWinsOverEverythingInTheSameLaunch() {
        let (configuration, _) = DeviceTestConfiguration.locked
            .applying(arguments: ["--hs-test-allow", "microphone", "--hs-test-mode", "stop"])
        #expect(configuration.isHalted)
        #expect(configuration.capture(for: .app) == .refused)
        #expect(configuration.prohibitsMicrophone)
        let resumed = configuration.applying(arguments: ["--hs-test-mode", "resume"]).configuration
        #expect(!resumed.isHalted)
    }

    @Test func lockedResetsPermissionsAndTheStop() {
        let open = DeviceTestConfiguration(isEnabled: false, allowsMicrophone: true, allowsTranscription: true,
                                           allowsModelInference: true, sessionLimit: 600, isHalted: true)
        #expect(open.applying(arguments: ["--hs-test-mode", "locked"]).configuration == .locked)
    }

    @Test func theSummaryNamesEveryRestriction() {
        #expect(DeviceTestConfiguration.locked.summary(origin: .missing)
            == "on(microphone=prohibited,transcription=prohibited,model=prohibited,sessionLimit=180s,halted=no,origin=missing)")
    }
}
#endif
