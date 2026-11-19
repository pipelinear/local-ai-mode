import Foundation

enum PerformanceError: LocalizedError {
    case authorizationCancelled
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationCancelled: return "Administrator authorization was cancelled; power settings were not changed."
        case .commandFailed(let s): return "pmset failed: \(s)"
        }
    }
}

/// Parses `pmset -g custom` output into per-source power-mode settings.
enum PMSetParser {
    static let powerModeKeys = ["powermode", "lowpowermode"]

    static func parsePowerModes(_ output: String) -> [PowerModeSetting] {
        var result: [PowerModeSetting] = []
        var source: PowerSource?
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Battery Power") { source = .battery; continue }
            if line.hasPrefix("AC Power") { source = .ac; continue }
            if line.hasPrefix("UPS Power") { source = nil; continue }
            guard let src = source else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, powerModeKeys.contains(String(parts[0])), let v = Int(parts[1]) else { continue }
            result.append(PowerModeSetting(key: String(parts[0]), source: src, value: v))
        }
        return result
    }

    /// Low Power Mode is value 1 for both `powermode` and the older `lowpowermode` key.
    static func commandsToDisableLowPower(_ settings: [PowerModeSetting]) -> [String] {
        settings.filter { $0.value == 1 }.map { "/usr/bin/pmset -\($0.source.rawValue) \($0.key) 0" }
    }

    static func commandsToRestore(_ original: [PowerModeSetting]) -> [String] {
        original.map { "/usr/bin/pmset -\($0.source.rawValue) \($0.key) \($0.value)" }
    }
}

/// Supported performance adjustments: Low Power Mode via `pmset` (with explicit admin authorization through the
/// standard macOS prompt) and an idle-sleep power assertion while AI Mode is on. Thermal protections are only
/// observed, never overridden.
@MainActor
final class PerformanceManager: ObservableObject {
    @Published private(set) var sleepAssertionActive = false
    @Published private(set) var lastMessage: String?

    private var activity: NSObjectProtocol?

    var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    func currentPowerModes() async -> [PowerModeSetting] {
        let output = await Self.run("/usr/bin/pmset", ["-g", "custom"])
        return PMSetParser.parsePowerModes(output.stdout)
    }

    /// Disables Low Power Mode for each power source where it is on. Returns the original values (to be journaled
    /// *before* calling this). Requires the user to authorize with an administrator password.
    func disableLowPowerMode(original: [PowerModeSetting]) async throws -> Bool {
        let commands = PMSetParser.commandsToDisableLowPower(original)
        guard !commands.isEmpty else { return false }
        try await runPrivileged(commands)
        lastMessage = "Low Power Mode turned off for AI Mode"
        return true
    }

    func restorePowerModes(_ original: [PowerModeSetting]) async throws {
        let commands = PMSetParser.commandsToRestore(original)
        guard !commands.isEmpty else { return }
        try await runPrivileged(commands)
        lastMessage = "Power settings restored"
    }

    // MARK: Sleep assertion

    func beginPerformanceActivity(preventIdleSleep: Bool) {
        guard activity == nil else { return }
        var options: ProcessInfo.ActivityOptions = [.userInitiated]
        if preventIdleSleep { options.insert(.idleSystemSleepDisabled) }
        activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "Local AI Mode is serving a local model")
        sleepAssertionActive = preventIdleSleep
    }

    func endPerformanceActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        sleepAssertionActive = false
    }

    // MARK: Process helpers

    /// Uses the documented `do shell script … with administrator privileges` mechanism, which shows the standard
    /// macOS authorization dialog. Commands are fixed pmset invocations built from parsed integers only.
    private func runPrivileged(_ commands: [String]) async throws {
        let joined = commands.joined(separator: "; ")
        let script = "do shell script \"\(joined)\" with administrator privileges"
        let result = await Self.run("/usr/bin/osascript", ["-e", script])
        if result.status != 0 {
            if result.stderr.contains("-128") || result.stderr.lowercased().contains("cancel") {
                throw PerformanceError.authorizationCancelled
            }
            throw PerformanceError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    nonisolated static func run(_ path: String, _ args: [String]) async -> (status: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { p in
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (p.terminationStatus, o, e))
            }
            do { try process.run() } catch {
                continuation.resume(returning: (-1, "", error.localizedDescription))
            }
        }
    }
}
