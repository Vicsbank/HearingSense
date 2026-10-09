import AVFAudio
import Foundation
import Testing
@testable import HearingSenseAudio

@Suite struct LevelMeterTests {
    private func sine(amplitude: Float, count: Int = 4800, cycles: Int = 100) -> [Float] {
        (0 ..< count).map { amplitude * sin(2 * .pi * Float(cycles) * Float($0) / Float(count)) }
    }

    @Test func fullScaleSine() {
        let level = LevelMeter.measure(sine(amplitude: 1))
        #expect(abs(level.rmsDBFS - (-3.0103)) < 0.01)
        #expect(abs(level.peakDBFS) < 0.01)
    }

    @Test func halfAmplitudeIsSixDecibelsLower() {
        let full = LevelMeter.measure(sine(amplitude: 1))
        let half = LevelMeter.measure(sine(amplitude: 0.5))
        #expect(abs((full.rmsDBFS - half.rmsDBFS) - 6.0206) < 0.01)
    }

    @Test func silenceAndEmptyInputClampToFloor() {
        #expect(LevelMeter.measure([Float](repeating: 0, count: 512)) == .silence)
        #expect(LevelMeter.measure([Float]()) == .silence)
    }

    @Test func normalizationClamps() {
        #expect(AudioLevel(rmsDBFS: -40, peakDBFS: 0).normalizedRMS(range: -80 ... 0) == 0.5)
        #expect(AudioLevel(rmsDBFS: -200, peakDBFS: 0).normalizedRMS() == 0)
        #expect(AudioLevel(rmsDBFS: 6, peakDBFS: 6).normalizedPeak() == 1)
    }

    @Test func pcmBufferReportsLoudestChannel() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let frames = 4800
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let quiet = sine(amplitude: 0.01, count: frames)
        let loud = sine(amplitude: 0.5, count: frames)
        let channels = try #require(buffer.floatChannelData)
        for i in 0 ..< frames {
            channels[0][i] = quiet[i]
            channels[1][i] = loud[i]
        }
        let level = try #require(LevelMeter.measure(buffer))
        #expect(abs(level.rmsDBFS - LevelMeter.measure(loud).rmsDBFS) < 0.01)
    }

    @Test func interleavedBufferMatchesDeinterleaved() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                channels: 2, interleaved: true))
        let frames = 4800
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let loud = sine(amplitude: 0.25, count: frames)
        let data = try #require(buffer.floatChannelData)
        for i in 0 ..< frames {
            data[0][2 * i] = 0
            data[0][2 * i + 1] = loud[i]
        }
        let level = try #require(LevelMeter.measure(buffer))
        #expect(abs(level.rmsDBFS - LevelMeter.measure(loud).rmsDBFS) < 0.01)
    }

    @Test func nonFloatBufferIsRejected() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                                channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        #expect(LevelMeter.measure(buffer) == nil)
    }
}
