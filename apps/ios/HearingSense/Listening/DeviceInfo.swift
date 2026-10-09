import UIKit

/// Device description recorded with diagnostics so test results can be attributed.
enum DeviceInfo {
    static var summary: String {
        let device = UIDevice.current
        let simulator = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        let kind = simulator.map { "Simulator (\($0))" } ?? modelIdentifier
        return "\(kind), \(device.systemName) \(device.systemVersion)"
    }

    /// Hardware identifier such as "iPhone17,1".
    private static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
