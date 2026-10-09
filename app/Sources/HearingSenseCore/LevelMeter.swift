import Accelerate

public enum LevelMeter {
    /// RMS 电平 (dBFS)。满幅正弦约为 -3 dBFS，静音返回 -120。
    public static func rmsDBFS(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return -120 }
        let rms = samples.withUnsafeBufferPointer { vDSP.rootMeanSquare($0) }
        return rms > 1e-6 ? 20 * log10(rms) : -120
    }

    public static func rmsDBFS(_ samples: [Float]) -> Float {
        rmsDBFS(samples[...])
    }
}
