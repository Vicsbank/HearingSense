import Darwin
import Foundation

/// Process-wide CPU time and memory footprint, read from the kernel. Two samples give the
/// average CPU utilization in between (100 % = one fully busy core).
public struct ProcessResourceUsage: Sendable, Equatable {
    public var date: Date
    /// User + system CPU time consumed by the whole process since launch.
    public var cpuSeconds: Double
    /// `phys_footprint` (what Xcode's memory gauge and jetsam use), in bytes. nil if unavailable.
    public var memoryFootprintBytes: UInt64?
    public var thermalState: ProcessInfo.ThermalState

    public static func sample(at date: Date = .now) -> ProcessResourceUsage {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return ProcessResourceUsage(date: date, cpuSeconds: cpu, memoryFootprintBytes: footprint(),
                                    thermalState: ProcessInfo.processInfo.thermalState)
    }

    /// Average CPU utilization between `earlier` and `self` (1.0 = one core).
    public func cpuUtilization(since earlier: ProcessResourceUsage) -> Double? {
        let wall = date.timeIntervalSince(earlier.date)
        guard wall > 0 else { return nil }
        return max(cpuSeconds - earlier.cpuSeconds, 0) / wall
    }

    public var memoryFootprintMB: Double? {
        memoryFootprintBytes.map { Double($0) / 1_048_576 }
    }

    public var thermalDescription: String {
        switch thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
