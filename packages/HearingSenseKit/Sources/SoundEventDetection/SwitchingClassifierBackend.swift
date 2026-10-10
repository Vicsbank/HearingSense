import Foundation
import HearingSenseDomain
import os

/// Which of a `SwitchingClassifierBackend`'s two classifiers should run. Set from any thread
/// (the app sets it when the scene moves between foreground and background).
public final class ClassifierBackendSelection: Sendable {
    private let secondary = OSAllocatedUnfairLock(initialState: false)

    public init(prefersSecondary: Bool = false) {
        secondary.withLock { $0 = prefersSecondary }
    }

    public var prefersSecondary: Bool {
        get { secondary.withLock { $0 } }
        set { secondary.withLock { $0 = newValue } }
    }
}

/// Runs one of two classifiers and changes between them without ending the segment: the hybrid
/// arrangement "Apple SoundAnalysis in the foreground, a CPU-only Core ML model in the
/// background" (docs/BACKGROUND_RECOGNITION_DECISION.md).
///
/// - The pipeline sees one continuous segment; each inner backend gets its own inner segment
///   starting at the frame where it took over, and its window times are shifted back onto the
///   outer segment.
/// - The secondary classifier runs while `selection.prefersSecondary` is set **or** after the
///   primary reported a failure. The second rule covers the time between the app entering the
///   background and the flag being set, and any background state the app did not anticipate:
///   the primary's failure is not passed on (which would make the pipeline wait and retry a
///   classifier that cannot work there); the secondary takes over with the next buffer.
/// - The primary is tried again when the selection changes back to it (not before: retrying a
///   classifier that fails would lose a window or two each time).
///
/// Used on the pipeline's queue only, like every backend; the selection and the failure flag
/// are the only state touched from other threads.
public final class SwitchingClassifierBackend: AcousticClassifierBackend {
    public static func factory(primary: ClassifierBackendFactory, secondary: ClassifierBackendFactory,
                               selection: ClassifierBackendSelection) -> ClassifierBackendFactory
    {
        let model = SoundModelID.hybrid(background: secondary.metadata.model)
        let metadata = ClassifierBackendMetadata(
            model: model, runtime: "\(primary.metadata.runtime) / \(secondary.metadata.runtime)",
            computeUnits: "\(primary.metadata.computeUnits) / \(secondary.metadata.computeUnits)",
            labelCount: nil, modelSampleRate: nil,
            summary: "Hybrid: \(primary.metadata.summary) in the foreground; \(secondary.metadata.summary) otherwise")
        return ClassifierBackendFactory(
            metadata: metadata, taxonomy: .merged(primary.taxonomy, secondary.taxonomy, model: model)
        ) {
            SwitchingClassifierBackend(primary: try primary.make(), secondary: try secondary.make(),
                                       selection: selection, metadata: metadata)
        }
    }

    public let metadata: ClassifierBackendMetadata
    public var windowDuration: TimeInterval { (usingSecondary ? secondary : primary).windowDuration }
    public var overlapFactor: Double { (usingSecondary ? secondary : primary).overlapFactor }
    /// How often the running classifier changed since the backend was created (diagnostics).
    public private(set) var switches = 0

    private let primary: any AcousticClassifierBackend
    private let secondary: any AcousticClassifierBackend
    private let selection: ClassifierBackendSelection
    private let primaryFailed = OSAllocatedUnfairLock(initialState: false)
    private var usingSecondary = false
    private var selectionWasSecondary = false
    private var isInnerSegmentOpen = false
    private var innerOffset: Int64 = 0
    private var sampleRate: Double = 0
    private var configuration = ClassifierConfiguration.standard
    private var sink: ClassifierBackendSink?

    init(primary: any AcousticClassifierBackend, secondary: any AcousticClassifierBackend,
         selection: ClassifierBackendSelection, metadata: ClassifierBackendMetadata)
    {
        self.primary = primary
        self.secondary = secondary
        self.selection = selection
        self.metadata = metadata
    }

    public func startSegment(sampleRate: Double, configuration: ClassifierConfiguration,
                             sink: ClassifierBackendSink) throws
    {
        finishSegment()
        self.sampleRate = sampleRate
        self.configuration = configuration
        self.sink = sink
        selectionWasSecondary = selection.prefersSecondary
        usingSecondary = wantsSecondary
        try openInnerSegment(at: 0)
    }

    public func analyze(_ samples: [Float], framePosition: Int64) {
        guard sink != nil else { return }
        let selected = selection.prefersSecondary
        if selectionWasSecondary, !selected { primaryFailed.withLock { $0 = false } }  // back to the primary: try it again
        selectionWasSecondary = selected
        let wanted = wantsSecondary
        if wanted != usingSecondary || !isInnerSegmentOpen {
            closeInnerSegment()
            usingSecondary = wanted
            switches += 1
            do {
                try openInnerSegment(at: framePosition)
            } catch {
                sink?.failure("Could not start the \(wanted ? "background" : "foreground") classifier: "
                    + error.localizedDescription)
                return
            }
        }
        (usingSecondary ? secondary : primary).analyze(samples, framePosition: framePosition - innerOffset)
    }

    public func finishSegment() {
        closeInnerSegment()
        sink = nil
    }

    private var wantsSecondary: Bool {
        selection.prefersSecondary || primaryFailed.withLock { $0 }
    }

    private func openInnerSegment(at framePosition: Int64) throws {
        guard let sink else { return }
        innerOffset = framePosition
        let shift = Double(framePosition) / sampleRate
        let backend = usingSecondary ? secondary : primary
        let model = backend.metadata.model
        let isPrimary = !usingSecondary
        let primaryFailed = self.primaryFailed
        let inner = ClassifierBackendSink(
            result: { result in
                var result = result
                result.windowStart += shift
                result.model = result.model ?? model
                sink.result(result)
            },
            failure: { message in
                if isPrimary {
                    primaryFailed.withLock { $0 = true }  // the secondary takes over with the next buffer
                } else {
                    sink.failure(message)
                }
            })
        try backend.startSegment(sampleRate: sampleRate, configuration: configuration, sink: inner)
        isInnerSegmentOpen = true
    }

    private func closeInnerSegment() {
        guard isInnerSegmentOpen else { return }
        (usingSecondary ? secondary : primary).finishSegment()
        isInnerSegmentOpen = false
    }
}
