import Foundation

/// How one fan should run.
public enum FanRule: Codable, Sendable, Equatable, Hashable {
    /// macOS decides.
    case auto
    /// A fixed speed in RPM.
    case constant(rpm: Double)
    /// Follows a sensor: minimum speed at `startCelsius`, rising to maximum at `fullCelsius`.
    case sensor(id: String, startCelsius: Double, fullCelsius: Double)
}

public struct Preset: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var rules: [Int: FanRule]   // fan index -> rule; missing fans run on auto

    public init(id: UUID = UUID(), name: String, rules: [Int: FanRule]) {
        self.id = id; self.name = name; self.rules = rules
    }

    public func rule(_ fan: Int) -> FanRule { rules[fan] ?? .auto }
}

/// What the helper applies. The app writes it; the helper reads it.
public struct HelperConfig: Codable, Sendable, Equatable {
    public var rules: [Int: FanRule]
    /// On battery power every fan is handed back to macOS.
    public var autoOnBattery: Bool

    public init(rules: [Int: FanRule] = [:], autoOnBattery: Bool = true) {
        self.rules = rules
        self.autoOnBattery = autoOnBattery
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([Int: FanRule].self, forKey: .rules) ?? [:]
        autoOnBattery = try c.decodeIfPresent(Bool.self, forKey: .autoOnBattery) ?? true
    }
}

/// Bumped whenever the helper's behaviour changes, so the app can ask for a reinstall.
public enum HelperInfo {
    public static let version = 2
}

public enum Paths {
    public static let label = "com.xocode.fancontrol.helper"
    public static let helper = "/Library/PrivilegedHelperTools/\(label)"
    public static let launchDaemon = "/Library/LaunchDaemons/\(label).plist"
    /// Owned by the user who installed the helper, so only they (and root) can change the rules.
    public static let configDirectory = "/Library/Application Support/FanControl"
    public static let config = "\(configDirectory)/rules.json"
    public static let log = "/Library/Logs/FanControl.log"
    /// Written by the running helper: its HelperInfo.version.
    public static let helperVersion = "\(configDirectory)/helper-version"
}

public extension HelperConfig {
    static func load(from path: String = Paths.config) -> HelperConfig? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(HelperConfig.self, from: data)
    }

    func save(to path: String = Paths.config) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// Target speed for a rule, or nil for automatic. Below a sensor rule's start temperature the fan is
/// left to macOS, which can stop it entirely when the Mac is cool.
public func targetRPM(for rule: FanRule, fan: FanReading, sensors: SensorReader) -> Double? {
    switch rule {
    case .auto:
        return nil
    case .constant(let rpm):
        return min(max(rpm, fan.minimum), fan.maximum)
    case .sensor(let id, let start, let full):
        guard let t = sensors.celsius(id), t >= start else { return nil }
        return curveRPM(celsius: t, start: start, full: full, fan: fan)
    }
}

/// The sensor curve: minimum speed at `start`, rising in a straight line to maximum at `full`.
public func curveRPM(celsius t: Double, start: Double, full: Double, fan: FanReading) -> Double {
    let share = full > start ? (t - start) / (full - start) : (t >= full ? 1 : 0)
    return fan.minimum + max(0, min(1, share)) * (fan.maximum - fan.minimum)
}
