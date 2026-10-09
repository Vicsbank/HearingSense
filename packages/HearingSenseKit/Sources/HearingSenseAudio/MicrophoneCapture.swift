import AVFAudio
import os

/// One tap callback's worth of real microphone data, summarized for the UI.
public struct CaptureTick: Sendable, Equatable {
    public var level: AudioLevel
    public var frameCount: Int
    public var sampleRate: Double
}

public enum CaptureError: LocalizedError, Equatable {
    /// The input node reports a 0 Hz / 0-channel format: no input route, or the audio
    /// session category does not allow recording.
    case noInputAvailable
    case engineStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noInputAvailable:
            "No microphone input is available. Check the audio session category and the current route."
        case .engineStartFailed(let message):
            "The audio engine could not start: \(message)"
        }
    }
}

/// Captures microphone audio with AVAudioEngine and reports levels measured from the
/// actual samples. Audio stays in memory; this type never writes audio to disk.
///
/// Threading: call `start()`, `stop()` and `restart()` from one controlling context (the
/// app's main actor). The tap block runs on an engine-owned thread; it updates counters,
/// forwards the buffer to consumers and reports a `CaptureTick` through the tick handler.
/// The tap block is built in a nonisolated method so it never inherits main-actor isolation.
///
/// The audio session (iOS) must be configured and active before `start()`; see
/// `AudioSessionController`.
public final class MicrophoneCapture: @unchecked Sendable {
    public typealias TickHandler = @Sendable (CaptureTick) -> Void
    public typealias ConfigurationChangeHandler = @Sendable () -> Void

    private struct Shared: Sendable {
        var consumers: [any AudioStreamConsumer] = []
        var tickHandler: TickHandler?
        var throughput = CaptureThroughput()
    }

    // Mutable state touched by the tap thread lives behind this lock. `engine` and
    // `configurationObserver` are only used from the controlling context.
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let engine = AVAudioEngine()
    private let bufferSize: AVAudioFrameCount
    private var configurationObserver: (any NSObjectProtocol)?

    /// - Parameter bufferSize: requested tap size in frames. iOS may deliver a different
    ///   size; 4096 frames is about 85 ms at 48 kHz.
    public init(bufferSize: AVAudioFrameCount = 4096) {
        self.bufferSize = bufferSize
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    public var isRunning: Bool { engine.isRunning }

    /// Buffers and frames delivered since the last `start()`.
    public var throughput: CaptureThroughput { shared.withLock { $0.throughput } }

    public func setTickHandler(_ handler: TickHandler?) {
        shared.withLock { $0.tickHandler = handler }
    }

    public func addConsumer(_ consumer: any AudioStreamConsumer) {
        shared.withLock { $0.consumers.append(consumer) }
    }

    public func removeAllConsumers() {
        shared.withLock { $0.consumers.removeAll() }
    }

    /// Called (on an arbitrary thread) when AVAudioEngine stops itself because the input or
    /// output hardware format changed, e.g. after a route change. Call `restart()` in response.
    public func setConfigurationChangeHandler(_ handler: ConfigurationChangeHandler?) {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let handler else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in handler() }
    }

    /// Installs the input tap and starts the engine. Returns the live input format.
    @discardableResult
    public func start() throws -> CaptureFormat {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputAvailable }
        if engine.isRunning { return CaptureFormat(format) }

        shared.withLock { $0.throughput.reset() }
        input.removeTap(onBus: 0)
        // format: nil taps the node's current output format, which avoids the
        // "format mismatch" exception when the hardware format changes between the read
        // above and this call.
        input.installTap(onBus: 0, bufferSize: bufferSize, format: nil, block: makeTapBlock())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
        for consumer in shared.withLock({ $0.consumers }) { consumer.captureDidStart(format: format) }
        return CaptureFormat(format)
    }

    /// Removes the tap and stops the engine. Safe to call when already stopped.
    public func stop() {
        let wasActive = engine.isRunning
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        if wasActive {
            for consumer in shared.withLock({ $0.consumers }) { consumer.captureDidStop() }
        }
    }

    /// Stops and starts again with the current hardware format (after a configuration change).
    @discardableResult
    public func restart() throws -> CaptureFormat {
        stop()
        return try start()
    }

    private nonisolated func makeTapBlock() -> AVAudioNodeTapBlock {
        let shared = self.shared
        return { buffer, time in
            guard let level = LevelMeter.measure(buffer) else { return }
            let tick = CaptureTick(level: level,
                                   frameCount: Int(buffer.frameLength),
                                   sampleRate: buffer.format.sampleRate)
            let (consumers, handler) = shared.withLock { state in
                state.throughput.record(frameCount: tick.frameCount, sampleRate: tick.sampleRate)
                return (state.consumers, state.tickHandler)
            }
            for consumer in consumers { consumer.captureDidReceive(buffer, at: time) }
            handler?(tick)
        }
    }
}
