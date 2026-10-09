import Foundation
import Testing
@testable import HearingSenseAudio

@Suite struct CaptureThroughputTests {
    @Test func intervalCoverage() throws {
        var throughput = CaptureThroughput()
        let start = Date(timeIntervalSince1970: 1_000)
        throughput.record(frameCount: 4800, sampleRate: 48_000)
        let checkpoint = throughput.checkpoint(at: start)
        for _ in 0 ..< 100 { throughput.record(frameCount: 4800, sampleRate: 48_000) }  // 10 s of audio
        let interval = try #require(throughput.interval(since: checkpoint, now: start.addingTimeInterval(20)))
        #expect(interval.buffers == 100)
        #expect(abs(interval.capturedSeconds - 10) < 1e-9)
        #expect(abs(interval.coverage - 0.5) < 1e-9)
    }

    @Test func intervalNeedsElapsedTimeAndSampleRate() {
        let throughput = CaptureThroughput()
        let now = Date()
        #expect(throughput.interval(since: throughput.checkpoint(at: now), now: now) == nil)
    }

    @Test func resetClearsCounters() {
        var throughput = CaptureThroughput()
        throughput.record(frameCount: 10, sampleRate: 16_000)
        throughput.reset()
        #expect(throughput == CaptureThroughput())
        #expect(throughput.capturedSeconds == 0)
    }
}

@Suite struct DiagnosticEventLogTests {
    @Test func trimsOldestEntriesBeyondCapacity() {
        var log = DiagnosticEventLog(capacity: 3)
        for i in 0 ..< 5 { log.append(.capture, "event \(i)") }
        #expect(log.entries.map(\.message) == ["event 2", "event 3", "event 4"])
        #expect(log.entries.map(\.id) == [2, 3, 4])
    }

    @Test func exportContainsKindAndMessage() {
        var log = DiagnosticEventLog()
        log.append(.route, "Route changed: newDeviceAvailable")
        #expect(log.exportText().contains("[route] Route changed: newDeviceAvailable"))
        log.removeAll()
        #expect(log.entries.isEmpty)
    }
}

@Suite struct AudioSessionPolicyTests {
    @Test func everyPolicyMixesAndNeverDucks() {
        for policy in AudioSessionPolicy.all {
            #expect(policy.options.contains(.mixWithOthers), "\(policy.id) must not interrupt media apps")
        }
        #expect(Set(AudioSessionPolicy.all.map(\.id)).count == AudioSessionPolicy.all.count)
    }

    @Test func recommendedPolicyKeepsBluetoothOutputOnA2DP() {
        let policy = AudioSessionPolicy.recommended
        #expect(policy.preferredInput == .builtInMicrophone)
        #expect(policy.options.contains(.allowBluetoothA2DP))
        #expect(!policy.options.contains(.allowBluetoothHFP))
        #expect(policy.mode == .default)
        #expect(!policy.isExperimental)
    }

    #if os(iOS)
    @Test func categoryOptionsMapping() {
        let options = AudioSessionPolicy.recommended.categoryOptions
        #expect(options.contains(.mixWithOthers))
        #expect(options.contains(.allowBluetoothA2DP))
        #expect(options.contains(.defaultToSpeaker))
        #expect(!options.contains(.allowBluetoothHFP))
        #expect(!options.contains(.duckOthers))
        #expect(AudioSessionPolicy.bluetoothHFP.categoryOptions.contains(.allowBluetoothHFP))
    }
    #endif
}

@Suite struct RouteAssessmentTests {
    private let builtInMic = AudioPortInfo(name: "iPhone Microphone", kind: .builtInMic,
                                           rawType: "MicrophoneBuiltIn", uid: "mic")
    private let airPodsA2DP = AudioPortInfo(name: "AirPods Pro", kind: .bluetoothA2DP,
                                            rawType: "BluetoothA2DPOutput", uid: "airpods-a2dp", channelCount: 2)
    private let airPodsHFP = AudioPortInfo(name: "AirPods Pro", kind: .bluetoothHFP,
                                           rawType: "BluetoothHFP", uid: "airpods-hfp")
    private let speaker = AudioPortInfo(name: "Speaker", kind: .builtInSpeaker, rawType: "Speaker", uid: "spk")

    @Test func targetRoute() {
        let snapshot = AudioRouteSnapshot(isInputAvailable: true, inputs: [builtInMic], outputs: [airPodsA2DP])
        #expect(RouteAssessment.evaluate(snapshot).verdict == .targetRoute)
    }

    @Test func builtInMicWithSpeaker() {
        let snapshot = AudioRouteSnapshot(isInputAvailable: true, inputs: [builtInMic], outputs: [speaker])
        #expect(RouteAssessment.evaluate(snapshot).verdict == .builtInMicWithoutBluetoothOutput)
    }

    @Test func hfpInput() {
        let snapshot = AudioRouteSnapshot(isInputAvailable: true, inputs: [airPodsHFP], outputs: [airPodsHFP])
        #expect(RouteAssessment.evaluate(snapshot).verdict == .bluetoothHFPInput)
    }

    @Test func highQualityBluetoothInput() {
        var input = airPodsHFP
        input.highQualityRecording = .init(isSupported: true, isEnabled: true)
        let snapshot = AudioRouteSnapshot(isInputAvailable: true, inputs: [input], outputs: [airPodsHFP])
        #expect(RouteAssessment.evaluate(snapshot).verdict == .bluetoothHighQualityInput)
    }

    @Test func noInput() {
        #expect(RouteAssessment.evaluate(AudioRouteSnapshot()).verdict == .noInput)
    }

    @Test func otherInput() {
        let usb = AudioPortInfo(name: "USB Mic", kind: .usbAudio, rawType: "USBAudio", uid: "usb")
        let snapshot = AudioRouteSnapshot(isInputAvailable: true, inputs: [usb], outputs: [speaker])
        #expect(RouteAssessment.evaluate(snapshot).verdict == .otherInput)
    }

    @Test func reportListsRoutesAndAssessment() {
        let snapshot = AudioRouteSnapshot(category: "AVAudioSessionCategoryPlayAndRecord",
                                          isInputAvailable: true, inputs: [builtInMic], outputs: [airPodsA2DP],
                                          permission: .granted)
        let report = snapshot.reportText()
        #expect(report.contains("Microphone permission: granted"))
        #expect(report.contains("iPhone Microphone [MicrophoneBuiltIn]"))
        #expect(report.contains("AirPods Pro [BluetoothA2DPOutput] ch=2"))
        #expect(report.contains("Assessment: Target route"))
    }
}

#if os(iOS)
import AVFAudio

@Suite struct AudioSessionEventParsingTests {
    @Test func interruptionBeganWithReason() {
        let note = Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            AVAudioSessionInterruptionReasonKey: UInt(2),
        ])
        #expect(AudioSessionEvent(interruption: note) == .interruptionBegan(reason: "builtInMicMuted"))
    }

    @Test func interruptionEndedShouldResume() {
        let note = Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ])
        #expect(AudioSessionEvent(interruption: note) == .interruptionEnded(shouldResume: true))
    }

    @Test func routeChangeReason() {
        let note = Notification(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
        ])
        #expect(AudioSessionEvent(routeChange: note)
                == .routeChanged(reason: .oldDeviceUnavailable, previousInputs: [], previousOutputs: []))
    }

    @Test func malformedNotificationIsIgnored() {
        let note = Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [:])
        #expect(AudioSessionEvent(interruption: note) == nil)
    }
}
#endif
