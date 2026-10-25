import Foundation

public struct FanReading: Sendable, Identifiable, Equatable {
    public let id: Int          // SMC index: 0 = F0, 1 = F1
    public let name: String
    public let rpm: Double
    public let target: Double
    public let minimum: Double
    public let maximum: Double
    public let manual: Bool

    /// Share of the fan's range in use, 0...1.
    public var load: Double { maximum > minimum ? max(0, min(1, (rpm - minimum) / (maximum - minimum))) : 0 }
}

public extension SMC {
    var fanCount: Int { Int(number("FNum") ?? 0) }

    /// MacBook Pros with two fans have one on each side: F0 on the left, F1 on the right.
    static func fanName(_ index: Int, count: Int) -> String {
        if count == 2 { return index == 0 ? "Left Fan" : "Right Fan" }
        return count == 1 ? "Fan" : "Fan \(index + 1)"
    }

    func fans() -> [FanReading] {
        let count = fanCount
        return (0..<count).map { i in
            FanReading(id: i, name: Self.fanName(i, count: count),
                       rpm: number("F\(i)Ac") ?? 0, target: number("F\(i)Tg") ?? 0,
                       minimum: number("F\(i)Mn") ?? 0, maximum: number("F\(i)Mx") ?? 0,
                       manual: (number("F\(i)Md") ?? 0) == 1)
        }
    }

    /// Takes the fan out of automatic control and holds it at `rpm` (clamped to its range). Needs root.
    func setFan(_ index: Int, rpm: Double) throws {
        let low = number("F\(index)Mn") ?? 0, high = number("F\(index)Mx") ?? rpm
        if (number("F\(index)Md") ?? 0) != 1 {
            // Some Apple Silicon models must be unlocked first; harmless where the key does not exist.
            if (try? read("Ftst")) != nil { try write("Ftst", number: 1) }
            try write("F\(index)Md", number: 1)
        }
        try write("F\(index)Tg", number: min(max(rpm, low), high))
    }

    /// Hands the fan back to macOS. Needs root.
    func setAuto(_ index: Int) throws {
        try write("F\(index)Md", number: 0)
        if (try? read("Ftst")) != nil, fans().allSatisfy({ !$0.manual }) { try? write("Ftst", number: 0) }
    }

    func setAllAuto() {
        for i in 0..<fanCount { try? setAuto(i) }
    }
}
