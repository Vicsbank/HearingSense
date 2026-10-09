import Foundation

/// 固定容量的单声道 Float 环形缓冲区。音频线程写入，分析线程读取最新的窗口。
/// 只在内存中保存最近几秒的音频，从不写入磁盘。
public final class AudioRingBuffer: @unchecked Sendable {
    private var storage: [Float]
    private var writeIndex = 0
    private var filled = 0
    private var totalWritten: Int64 = 0
    private let lock = NSLock()

    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    public func append(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        var src = samples[...]
        // 写入量超过容量时只保留最后 capacity 个样本
        if src.count > capacity { src = src.suffix(capacity) }
        totalWritten += Int64(samples.count)
        var remaining = src.count
        var offset = src.startIndex
        while remaining > 0 {
            let n = min(remaining, capacity - writeIndex)
            storage.withUnsafeMutableBufferPointer { dst in
                for i in 0..<n { dst[writeIndex + i] = samples[offset + i] }
            }
            writeIndex = (writeIndex + n) % capacity
            offset += n
            remaining -= n
        }
        filled = min(capacity, filled + src.count)
    }

    public func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// 已写入的样本总数（用作音频时钟）
    public var samplesWritten: Int64 {
        lock.lock(); defer { lock.unlock() }
        return totalWritten
    }

    public var availableCount: Int {
        lock.lock(); defer { lock.unlock() }
        return filled
    }

    /// 最近的 count 个样本（按时间顺序）；不足时返回 nil
    public func latest(_ count: Int) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard count <= filled, count <= capacity else { return nil }
        var out = [Float](repeating: 0, count: count)
        let start = (writeIndex - count + capacity) % capacity
        storage.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for i in 0..<count { dst[i] = src[(start + i) % capacity] }
            }
        }
        return out
    }

    /// 清空缓冲区（停止监听时调用，确保不残留音频）
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        for i in storage.indices { storage[i] = 0 }
        writeIndex = 0
        filled = 0
        totalWritten = 0
    }
}
