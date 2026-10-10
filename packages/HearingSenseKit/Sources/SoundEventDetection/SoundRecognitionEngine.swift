import AVFAudio
import Foundation
import HearingSenseAudio
import HearingSenseDomain
import os

/// Real-time environmental sound recognition on top of `MicrophoneCapture`.
///
/// ```
/// MicrophoneCapture tap ─▶ captureDidReceive (copy channel 0, stamp position, enqueue; never blocks)
///                       ─▶ analysis queue: AcousticClassifierBackend (default: Apple SoundAnalysis,
///                          SNClassifySoundRequest(.version1); alternative: a Core ML model on CPU)
///                       ─▶ ClassificationFrame ─▶ SoundEventDetector ─▶ outputs (AsyncStream)
/// ```
///
/// Usage: `capture.addConsumer(engine)`, iterate `engine.outputs` (single consumer), call
/// `endSession()` when the user stops listening or iOS interrupts capture. No audio is stored:
/// buffers live only until analyzed; outputs carry metadata.
///
/// Thread safety: all mutable tap-side state is behind a lock; analyzer state is isolated to the
/// worker actor. Every method may be called from any thread.
public final class SoundRecognitionEngine: AudioStreamConsumer {
    public let outputs: AsyncStream<SoundRecognitionOutput>
    public let taxonomy: SoundTaxonomy
    public let policy: DetectionPolicy

    private struct TapState {
        var clock = StreamClock()
        var pending = 0
        var dropped = 0
        var unsupportedBuffers = 0
        var backlogLimit: Int?
    }

    private let worker: SoundAnalysisWorker
    private let continuation: AsyncStream<SoundRecognitionOutput>.Continuation
    private let tap: OSAllocatedUnfairLock<TapState>

    /// The classifier behind this engine (model, runtime, compute units).
    public let backend: ClassifierBackendMetadata

    /// - Parameters:
    ///   - backend: which classifier runs. Its labels must be the ones `taxonomy` maps, so pass
    ///     the factory's own taxonomy unless you have a reason not to (nil does that).
    public init(configuration: ClassifierConfiguration = .standard, taxonomy: SoundTaxonomy? = nil,
                policy: DetectionPolicy = .standard, backend: ClassifierBackendFactory = AppleSoundAnalysisBackend.factory)
    {
        let taxonomy = taxonomy ?? backend.taxonomy
        self.backend = backend.metadata
        let (stream, continuation) = AsyncStream.makeStream(of: SoundRecognitionOutput.self,
                                                            bufferingPolicy: .bufferingNewest(1_000))
        outputs = stream
        self.continuation = continuation
        self.taxonomy = taxonomy
        self.policy = policy
        tap = OSAllocatedUnfairLock(initialState: TapState(backlogLimit: configuration.backlogLimit))
        worker = SoundAnalysisWorker(configuration: configuration, taxonomy: taxonomy, policy: policy,
                                     backend: backend, continuation: continuation)
    }

    deinit {
        continuation.finish()
    }

    /// Takes effect when the next analyzer segment starts (next Start Listening).
    public func setConfiguration(_ configuration: ClassifierConfiguration) {
        tap.withLock { $0.backlogLimit = configuration.backlogLimit }
        worker.enqueue { $0.setConfiguration(configuration) }
    }

    /// Ends all active events and starts a fresh session (audio clock back to 0). Call after
    /// the capture stopped: user pressed Stop, or an interruption began.
    public func endSession(at date: Date = .now) {
        let next = tap.withLock { state -> Int in
            state.clock.resetSession()
            return state.clock.generation
        }
        worker.enqueue { $0.endSession(at: date, nextGeneration: next) }
    }

    /// Waits until everything enqueued so far has been processed (offline evaluation, tests).
    public func drain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            worker.enqueue { worker in
                worker.drainInbox()
                done.resume()
            }
        }
    }

    // MARK: - AudioStreamConsumer

    public func captureDidStart(format: AVAudioFormat) {
        tap.withLock { $0.clock.markDiscontinuity() }
    }

    public func captureDidReceive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let samples = AudioChunk.copyChannelZero(of: buffer) else {
            tap.withLock { $0.unsupportedBuffers += 1 }
            return
        }
        let levels = AudioChunk.levels(of: samples)
        let sampleTime = time.isSampleTimeValid ? time.sampleTime : nil
        let sampleRate = buffer.format.sampleRate
        let chunk = tap.withLock { state -> AudioChunk? in
            let placement = state.clock.place(frameCount: samples.count, sampleRate: sampleRate,
                                              sampleTime: sampleTime)
            if let limit = state.backlogLimit, state.pending >= limit {
                state.dropped += 1
                return nil
            }
            state.pending += 1
            return AudioChunk(samples: samples, placement: placement, capturedAt: .now, rms: levels.rms,
                              peak: levels.peak, droppedChunksSoFar: state.dropped,
                              gapFramesSoFar: state.clock.gapFrames, backlogAtEnqueue: state.pending)
        }
        guard let chunk else { return }
        let tap = self.tap
        worker.enqueue { worker in
            worker.analyze(chunk)
            tap.withLock { $0.pending -= 1 }
        }
    }

    public func captureDidStop() {
        tap.withLock { $0.clock.markDiscontinuity() }
        worker.enqueue { $0.endSegment() }
    }
}
