import Foundation

/// A named temperature built from one or more SMC keys.
public struct SensorGroup: Sendable, Identifiable, Hashable {
    public enum Combine: String, Sendable { case average, maximum }
    public let id: String        // stable id stored in rules, e.g. "cpu-hot"
    public let name: String
    public let prefixes: [String]
    public let combine: Combine

    public init(_ id: String, _ name: String, _ prefixes: [String], _ combine: Combine) {
        self.id = id; self.name = name; self.prefixes = prefixes; self.combine = combine
    }
}

public struct SensorReading: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let celsius: Double
}

public enum Sensors {
    /// Groups found on Apple Silicon Macs (key families are shared across M-series chips).
    public static let groups: [SensorGroup] = [
        .init("cpu-hot", "CPU Hottest Core", ["Tp0", "Te0"], .maximum),
        .init("cpu-p", "CPU Performance Cores", ["Tp0"], .average),
        .init("cpu-e", "CPU Efficiency Cores", ["Te0"], .average),
        .init("gpu", "GPU", ["Tg0"], .average),
        .init("memory", "Memory", ["Tm0"], .average),
        .init("ssd", "SSD", ["TH0"], .maximum),
        .init("battery", "Battery", ["TB0T", "TB1T", "TB2T"], .maximum),
        .init("wifi", "Wi-Fi", ["TW0P"], .maximum),
        .init("palm-left", "Palm Rest Left", ["Ts0P"], .maximum),
        .init("palm-right", "Palm Rest Right", ["Ts1P"], .maximum),
    ]

    public static func group(_ id: String) -> SensorGroup? { groups.first { $0.id == id } }
}

/// Resolves sensor groups to SMC keys once (listing all keys is slow), then reads them cheaply.
public final class SensorReader: @unchecked Sendable {
    private let smc: SMC
    private let keys: [String: [String]]   // group id -> keys present on this Mac

    public init(smc: SMC) {
        self.smc = smc
        let all = smc.allKeys().filter { $0.hasPrefix("T") }
        var map: [String: [String]] = [:]
        for group in Sensors.groups {
            let found = all.filter { key in group.prefixes.contains { key.hasPrefix($0) } }
                .filter { (smc.number($0) ?? 0) > 1 }   // skip keys that read 0 on this model
            if !found.isEmpty { map[group.id] = found }
        }
        keys = map
    }

    public var available: [SensorGroup] { Sensors.groups.filter { keys[$0.id] != nil } }

    public func celsius(_ id: String) -> Double? {
        guard let group = Sensors.group(id), let list = keys[id] else { return nil }
        let values = list.compactMap { smc.number($0) }.filter { $0 > 1 && $0 < 150 }
        guard !values.isEmpty else { return nil }
        return group.combine == .maximum ? values.max() : values.reduce(0, +) / Double(values.count)
    }

    public func readings() -> [SensorReading] {
        available.compactMap { g in celsius(g.id).map { SensorReading(id: g.id, name: g.name, celsius: $0) } }
    }
}
