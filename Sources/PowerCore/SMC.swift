import CSMC
import Foundation
import IOKit

public struct SMCError: Error, CustomStringConvertible {
    public let key: String
    public let code: kern_return_t
    public var description: String {
        let hex = String(UInt32(bitPattern: code), radix: 16)
        return "SMC lỗi với key \(key): 0x\(hex)"
    }
}

public struct SMCReading: Sendable {
    public let key: String
    public let type: String
    public let bytes: [UInt8]

    /// Giải mã các kiểu số thường gặp trên Apple Silicon.
    public var doubleValue: Double? {
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "sp78":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count == 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default:
            return nil
        }
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// Kết nối tới AppleSMC. Đọc không cần quyền root, ghi thì cần.
public final class SMC {
    private var connection: io_connect_t = 0

    public init() throws {
        let result = smc_open(&connection)
        guard result == KERN_SUCCESS else { throw SMCError(key: "open", code: result) }
    }

    deinit { smc_close(connection) }

    public func read(_ key: String) -> SMCReading? {
        var value = SMCValue()
        guard smc_read_key(connection, key, &value) == KERN_SUCCESS else { return nil }
        let size = Int(value.dataSize)
        let bytes = withUnsafeBytes(of: value.bytes) { Array($0.prefix(size)) }
        let t = value.dataType
        let type = String(bytes: [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)],
                          encoding: .ascii) ?? "????"
        return SMCReading(key: key, type: type, bytes: bytes)
    }

    public func hasKey(_ key: String) -> Bool { read(key) != nil }

    public func write(_ key: String, _ bytes: [UInt8]) throws {
        let result = smc_write_key(connection, key, bytes, UInt32(bytes.count))
        guard result == KERN_SUCCESS else { throw SMCError(key: key, code: result) }
    }
}
