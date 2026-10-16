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
    public let attributes: UInt8
    public let bytes: [UInt8]

    public init(key: String, type: String, attributes: UInt8, bytes: [UInt8]) {
        self.key = key
        self.type = type
        self.attributes = attributes
        self.bytes = bytes
    }

    public var isWritable: Bool { attributes & 0x40 != 0 }

    /// Trên Apple Silicon, key có bit thuộc tính 0x04 lưu số little-endian, các key còn lại big-endian
    /// (ví dụ `#KEY`, `B0RM`, `D4MV`). Trên Intel số nguyên là big-endian, riêng `flt ` là little-endian.
    public var isLittleEndian: Bool {
        Platform.isAppleSilicon ? attributes & 0x04 != 0 : type == "flt "
    }

    public var doubleValue: Double? {
        Self.decode(type: type, bytes: bytes, littleEndian: isLittleEndian)
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Giải mã các kiểu số thường gặp của SMC.
    public static func decode(type: String, bytes: [UInt8], littleEndian: Bool) -> Double? {
        func unsigned(_ count: Int) -> UInt64? {
            guard bytes.count == count else { return nil }
            let ordered = littleEndian ? bytes.reversed() : bytes
            return ordered.reduce(0) { $0 << 8 | UInt64($1) }
        }
        switch type {
        case "flt ":
            return unsigned(4).map { Double(Float(bitPattern: UInt32($0))) }
        case "ui8 ", "flag":
            return unsigned(1).map { Double($0) }
        case "ui16":
            return unsigned(2).map { Double($0) }
        case "ui32":
            return unsigned(4).map { Double($0) }
        case "si8 ":
            return unsigned(1).map { Double(Int8(bitPattern: UInt8($0))) }
        case "si16":
            return unsigned(2).map { Double(Int16(bitPattern: UInt16($0))) }
        case "si32":
            return unsigned(4).map { Double(Int32(bitPattern: UInt32($0))) }
        case "sp78":
            return unsigned(2).map { Double(Int16(bitPattern: UInt16($0))) / 256 }
        case "fp88":
            return unsigned(2).map { Double($0) / 256 }
        default:
            return nil
        }
    }
}

/// Đọc/ghi SMC. Tách thành protocol để kiểm thử các backend bằng SMC giả lập.
public protocol SMCAccess: AnyObject {
    func read(_ key: String) -> SMCReading?
    func write(_ key: String, _ bytes: [UInt8]) throws
}

/// Kết nối tới AppleSMC. Đọc không cần quyền root, ghi thì cần.
public final class SMC: SMCAccess {
    private var connection: io_connect_t = 0
    /// Thông tin key (kích thước, kiểu) không đổi: nhớ lại để mỗi lần đọc chỉ gọi SMC một lần thay vì hai.
    private var keyInfo: [String: SMCValue] = [:]
    private let keyInfoLock = NSLock()

    public init() throws {
        let result = smc_open(&connection)
        guard result == KERN_SUCCESS else { throw SMCError(key: "open", code: result) }
    }

    deinit { smc_close(connection) }

    public func read(_ key: String) -> SMCReading? {
        var value = SMCValue()
        if let known = keyInfoLock.withLock({ keyInfo[key] }) {
            value = known
            guard smc_read_key_known(connection, key, &value) == KERN_SUCCESS else {
                keyInfoLock.withLock { keyInfo[key] = nil }
                return nil
            }
        } else {
            guard smc_read_key(connection, key, &value) == KERN_SUCCESS else { return nil }
            keyInfoLock.withLock { keyInfo[key] = value }
        }
        let size = Int(value.dataSize)
        let bytes = withUnsafeBytes(of: value.bytes) { Array($0.prefix(size)) }
        let t = value.dataType
        let type = String(bytes: [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)],
                          encoding: .ascii) ?? "????"
        return SMCReading(key: key, type: type, attributes: value.dataAttributes, bytes: bytes)
    }

    public func hasKey(_ key: String) -> Bool { read(key) != nil }

    /// Tất cả tên key của SMC (đọc "#KEY" rồi lần lượt theo chỉ số). Vài nghìn key, mất khoảng chục mili giây.
    public func allKeys() -> [String] {
        guard let count = read("#KEY").flatMap({ $0.bytes.count == 4 ? $0.bytes : nil }) else { return [] }
        let total = count.reduce(0) { $0 << 8 | Int($1) }   // ui32, big-endian
        var keys: [String] = []
        keys.reserveCapacity(min(total, 10_000))
        var name = [CChar](repeating: 0, count: 5)
        for index in 0..<min(total, 10_000) where smc_key_at_index(connection, UInt32(index), &name) == KERN_SUCCESS {
            keys.append(String(cString: name))
        }
        return keys
    }

    public func write(_ key: String, _ bytes: [UInt8]) throws {
        let result = smc_write_key(connection, key, bytes, UInt32(bytes.count))
        guard result == KERN_SUCCESS else { throw SMCError(key: key, code: result) }
    }
}
