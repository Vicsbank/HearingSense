import Foundation
import MLX
import Testing
@testable import QwenRuntime

#if targetEnvironment(simulator)
/// Evaluates real arrays: covers allocation, device discovery, events and stream fences.
/// A metadata-only availability check cannot catch the former fatal Metal initialization.
@Test func simulatorEvaluatesWithTheNativeCPUBackend() {
    #expect(Device.defaultDevice().deviceType == .cpu)
    let left = MLXArray([Float(1), 2, 3, 4], [2, 2])
    let right = MLXArray.ones([2, 2])
    let result = matmul(left, right)
    eval(result)
    #expect(result.asArray(Float.self) == [3, 3, 7, 7])
    MLX.Memory.clearCache()
}

@Test func missingCheckpointReachesTheNormalAvailabilityCheckOnSimulator() async {
    let engine = QwenSummarizationEngine(modelDirectory: URL(fileURLWithPath: "/nonexistent/qwen"))
    #expect(await engine.unavailabilityReason() == "qwen_model_not_installed")
    #expect(QwenSummarizationEngine.executionBackend == "cpu")
    await engine.releaseResources()
}

@Test func simulatorAffineFourBitMatmulKeepsPackedValuesAndBFloat16Output() {
    // Each packed word contains 0,1,...,7; eight words cover one 64-value group.
    let packed = MLXArray([UInt32](repeating: 0x76543210, count: 16), [2, 8])
    let scales = MLXArray([Float(1), 2], [2, 1]).asType(.bfloat16)
    let biases = MLXArray([Float(0), -1], [2, 1]).asType(.bfloat16)
    let input = MLXArray.ones([2, 64]).asType(.bfloat16)
        * MLXArray([Float(1), 2], [2, 1]).asType(.bfloat16)
    let output = quantizedMM(input, packed, scales: scales, biases: biases,
                             groupSize: 64, bits: 4)
    eval(output)
    #expect(output.dtype == .bfloat16)
    #expect(output.asType(.float32).asArray(Float.self) == [224, 384, 448, 768])
}

@Test func simulatorParallelMatmulPreservesBothInputLayouts() {
    let left = MLXArray((1...16).flatMap { row in [Float](repeating: Float(row), count: 64) }, [16, 64])
    let transposedLeft = swappedAxes(MLXArray((0..<64).flatMap { _ in (1...16).map(Float.init) }, [64, 16]), 0, 1)
    let weights = MLXArray((1...2048).flatMap { row in [Float](repeating: Float(row), count: 64) }, [2048, 64])
    let transposedRight = swappedAxes(weights, 0, 1)
    let contiguousRight = MLXArray((0..<64).flatMap { _ in (1...2048).map(Float.init) }, [64, 2048])
    let expected = (1...16).flatMap { row in (1...2048).map { Float(64 * row * $0) } }
    for (a, b) in [(left, transposedRight), (left, contiguousRight), (transposedLeft, transposedRight)] {
        let result = matmul(a, b)
        eval(result)
        #expect(result.asArray(Float.self) == expected)
    }
}

@Test func simulatorPackedDecodeSupportsMixedDtypesAndUnevenRowPartitions() {
    let rows = 1033
    let packed = MLXArray([UInt32](repeating: 0x76543210, count: rows * 8), [rows, 8])
    let scales = MLXArray.ones([rows, 1]).asType(.bfloat16)
    let biases = MLXArray.zeros([rows, 1]).asType(.bfloat16)
    let output = quantizedMM(MLXArray.ones([1, 64]), packed, scales: scales,
                             biases: biases, groupSize: 64, bits: 4)
    eval(output)
    #expect(output.dtype == .float32)
    #expect(output.asArray(Float.self) == [Float](repeating: 224, count: rows))
}

@Test func simulatorPackedPrefillAndDecodeMatchUnpackedAffineReference() {
    let rows = 5, width = 128
    let packed = MLXArray((0..<rows * width / 8).map { UInt32($0) &* 0x9e3779b9 }, [rows, width / 8])
    let scales = MLXArray((0..<rows * 2).map { Float($0 % 7 + 1) / 64 }, [rows, 2]).asType(.bfloat16)
    let biases = MLXArray((0..<rows * 2).map { Float($0 % 3 - 1) / 8 }, [rows, 2]).asType(.bfloat16)
    let full = dequantized(packed, scales: scales, biases: biases, groupSize: 64, bits: 4, dtype: .float32)
    for tokens in [1, 3] {
        let input = MLXArray((0..<tokens * width).map { Float($0 % 11 - 5) / 5 }, [tokens, width])
        let actual = quantizedMM(input, packed, scales: scales, biases: biases, groupSize: 64, bits: 4)
        let reference = matmul(input, swappedAxes(full, 0, 1))
        eval(actual, reference)
        let a = actual.asArray(Float.self), b = reference.asArray(Float.self)
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 0.0001 })
    }
}
#endif
