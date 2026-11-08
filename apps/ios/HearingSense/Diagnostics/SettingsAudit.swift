import Foundation

/// A short, persistent record of changes to the privacy-relevant switches ("Transcribe nearby
/// speech", the Dynamic Island settings): when, which, from what to what.
///
/// Why it exists: during the Window 5 device sessions "Transcribe nearby speech" and "Expand for
/// important events" were found on although nobody remembered turning them on. The app only
/// changes them through its own switches, and its event log is in memory, so after a relaunch
/// there was no way to tell when a switch had been used. This record survives relaunches and is
/// part of the diagnostics report. It holds switch names, values and times only.
enum SettingsAudit {
    private static let key = "settings.audit.v1"
    static let capacity = 40

    static func record(_ setting: String, from old: Bool, to new: Bool, defaults: UserDefaults = .standard) {
        var entries = defaults.stringArray(forKey: key) ?? []
        entries.append("\(Date.now.formatted(.iso8601)) \(setting): \(old ? "on" : "off") → \(new ? "on" : "off")")
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        defaults.set(entries, forKey: key)
    }

    static func entries(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Lines for the diagnostics report, oldest first.
    static func reportLines(defaults: UserDefaults = .standard) -> [String] {
        let entries = entries(defaults: defaults)
        return ["Setting changes made with the app's switches (stored on this iPhone, oldest first; "
            + "recorded since the build that introduced this list):"]
            + (entries.isEmpty ? ["  none recorded"] : entries.map { "  " + $0 })
    }
}
