import CSMC
import Foundation

public enum SMCError: Error, CustomStringConvertible {
    case unavailable(kern_return_t)
    case failed(String, kern_return_t)
    case notPermitted(String)
    case unsupportedType(String, String)

    public var description: String {
        switch self {
        case .unavailable(let r): return "The SMC could not be opened (\(String(format: "0x%08x", r)))."
        case .failed(let key, let r): return "SMC key \(key) failed (\(String(format: "0x%08x", r)))."
        case .notPermitted(let key): return "Writing \(key) needs administrator rights (run with sudo or install the helper)."
        case .unsupportedType(let key, let type): return "SMC key \(key) has unsupported type '\(type)'."
        }
    }
}

/// Four-character code helpers ("F0Ac" <-> 0x46304163).
public enum FourCC {
    public static func code(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
    public static func string(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? "????"
    }
}

/// A raw SMC value with its type, decoded into a number when the type is numeric.
public struct SMCValue {
    public let key: String
    public let type: String
    public let bytes: [UInt8]

    public var number: Double? {
        switch type {
        case "flt ": return bytes.count >= 4 ? Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)) : nil
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
        case "ui32": return bytes.count >= 4 ? Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) : nil
        case "fpe2": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4 : nil
        case "sp78": return bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256 : nil
        case "si8 ": return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16": return bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) : nil
        default: return nil
        }
    }
}

/// One open connection to the SMC. Reading works for any user; writing needs root.
public final class SMC: @unchecked Sendable {
    private let connection: io_connect_t
    private let lock = NSLock()

    public init() throws {
        var c: io_connect_t = 0
        let r = smc_open(&c)
        guard r == kIOReturnSuccess else { throw SMCError.unavailable(r) }
        connection = c
    }

    deinit { smc_close(connection) }

    public func read(_ key: String) throws -> SMCValue {
        lock.lock(); defer { lock.unlock() }
        var info = smc_key_info()
        var raw = [UInt8](repeating: 0, count: 32)
        let r = raw.withUnsafeMutableBufferPointer { smc_read(connection, FourCC.code(key), $0.baseAddress, &info) }
        guard r == kIOReturnSuccess else { throw SMCError.failed(key, r) }
        return SMCValue(key: key, type: FourCC.string(info.type), bytes: Array(raw.prefix(Int(min(info.size, 32)))))
    }

    public func number(_ key: String) -> Double? { (try? read(key))?.number }

    public func write(_ key: String, bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let r = bytes.withUnsafeBufferPointer { smc_write(connection, FourCC.code(key), $0.baseAddress, UInt32($0.count)) }
        guard r == kIOReturnSuccess else {
            throw r == kIOReturnNotPrivileged || geteuid() != 0 ? SMCError.notPermitted(key) : SMCError.failed(key, r)
        }
    }

    /// Writes a number in the key's own type.
    public func write(_ key: String, number: Double) throws {
        let type = try read(key).type
        let bytes: [UInt8]
        switch type {
        case "flt ":
            let bits = Float(number).bitPattern
            bytes = [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 24)]
        case "ui8 ": bytes = [UInt8(clamping: Int(number.rounded()))]
        case "fpe2":
            let v = UInt16(clamping: Int((number * 4).rounded()))
            bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        default: throw SMCError.unsupportedType(key, type)
        }
        try write(key, bytes: bytes)
    }

    /// Every key the SMC exposes.
    public func allKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var count: UInt32 = 0
        guard smc_key_count(connection, &count) == kIOReturnSuccess else { return [] }
        return (0..<count).compactMap { i in
            var key: UInt32 = 0
            return smc_key_at(connection, i, &key) == kIOReturnSuccess ? FourCC.string(key) : nil
        }
    }
}
