import Foundation
import HearingSenseDomain

/// What a classifier backend is, for diagnostics and stored metadata.
public struct ClassifierBackendMetadata: Hashable, Sendable {
    public var model: SoundModelID
    /// Framework that runs the model: "SoundAnalysis" or "Core ML".
    public var runtime: String
    /// Compute units the model may use ("system-chosen" when the framework offers no setting).
    public var computeUnits: String
    public var labelCount: Int?
    /// Sample rate the model expects; nil when the framework resamples internally.
    public var modelSampleRate: Double?
    public var summary: String

    public init(model: SoundModelID, runtime: String, computeUnits: String, labelCount: Int?,
                modelSampleRate: Double?, summary: String)
    {
        self.model = model
        self.runtime = runtime
        self.computeUnits = computeUnits
        self.labelCount = labelCount
        self.modelSampleRate = modelSampleRate
        self.summary = summary
    }
}

/// One analysis window as a backend reports it: every label in the model's own vocabulary with
/// the model's own score. Mapping to kinds happens later, in `SoundTaxonomy`.
public struct ClassifierWindowResult: Sendable {
    /// Seconds from the start of the current segment to the start of the window.
    public var windowStart: TimeInterval
    public var windowDuration: TimeInterval
    public var classifications: [(label: String, score: Double)]
    public var deliveredAt: Date
    /// Wall-clock duration of the model call for this window, when the backend can measure it.
    public var inferenceSeconds: TimeInterval?
    /// The model that produced this window, when it is not the pipeline's default (a backend
    /// that switches between two models sets it).
    public var model: SoundModelID?

    public init(windowStart: TimeInterval, windowDuration: TimeInterval,
                classifications: [(label: String, score: Double)], deliveredAt: Date = .now)
    {
        self.windowStart = windowStart
        self.windowDuration = windowDuration
        self.classifications = classifications
        self.deliveredAt = deliveredAt
    }
}

/// Where a backend delivers its output. Both closures may be called from any thread, during or
/// after `analyze`; the pipeline restores the order.
public struct ClassifierBackendSink: Sendable {
    public var result: @Sendable (ClassifierWindowResult) -> Void
    /// The current segment cannot continue. The pipeline starts a new segment after a back-off.
    public var failure: @Sendable (String) -> Void

    public init(result: @escaping @Sendable (ClassifierWindowResult) -> Void,
                failure: @escaping @Sendable (String) -> Void)
    {
        self.result = result
        self.failure = failure
    }
}

/// A streaming sound classifier: mono float audio in, per-window label scores out.
///
/// The seam between "which model, on which runtime" and everything after it (taxonomy, event
/// detection, speech activation), which only sees `ClassificationFrame`s. Implementations:
/// `AppleSoundAnalysisBackend` (built-in classifier) and `CoreMLSoundClassifierBackend`
/// (a converted third-party model on explicitly chosen compute units).
///
/// Threading: an instance is created and used on the recognition pipeline's serial queue only.
/// A segment is a run of contiguous audio at one sample rate; frame positions restart at 0 with
/// every segment and may jump forward when the pipeline dropped buffers.
public protocol AcousticClassifierBackend: AnyObject {
    var metadata: ClassifierBackendMetadata { get }
    /// Window length and overlap actually in use (valid after `startSegment`).
    var windowDuration: TimeInterval { get }
    var overlapFactor: Double { get }

    func startSegment(sampleRate: Double, configuration: ClassifierConfiguration, sink: ClassifierBackendSink) throws
    func analyze(_ samples: [Float], framePosition: Int64)
    /// Flushes pending windows (delivering their results) and releases per-segment resources.
    func finishSegment()
}

/// Creates the backend on the pipeline's queue and names the taxonomy that reads its labels.
public struct ClassifierBackendFactory: Sendable {
    public var metadata: ClassifierBackendMetadata
    public var taxonomy: SoundTaxonomy
    public var make: @Sendable () throws -> any AcousticClassifierBackend

    public init(metadata: ClassifierBackendMetadata, taxonomy: SoundTaxonomy,
                make: @escaping @Sendable () throws -> any AcousticClassifierBackend)
    {
        self.metadata = metadata
        self.taxonomy = taxonomy
        self.make = make
    }
}
