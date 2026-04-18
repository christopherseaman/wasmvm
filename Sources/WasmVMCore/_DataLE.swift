import Foundation

extension Data {
    public mutating func appendU8(_ value: UInt8) {
        append(value)
    }

    public mutating func appendU16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    public mutating func appendU32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    public mutating func appendU64LE(_ value: UInt64) {
        for i in 0..<8 {
            append(UInt8((value >> (8 * i)) & 0xff))
        }
    }

    public func readU8(at offset: Int) -> UInt8? {
        guard offset >= 0, offset + 1 <= count else { return nil }
        return self[index(startIndex, offsetBy: offset)]
    }

    public func readU16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let b0 = UInt16(self[index(startIndex, offsetBy: offset)])
        let b1 = UInt16(self[index(startIndex, offsetBy: offset + 1)])
        return b0 | (b1 << 8)
    }

    public func readU32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 {
            v |= UInt32(self[index(startIndex, offsetBy: offset + i)]) << (8 * i)
        }
        return v
    }

    public func readU64LE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(self[index(startIndex, offsetBy: offset + i)]) << (8 * i)
        }
        return v
    }

    public func slice(at offset: Int, length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= count else { return nil }
        let start = index(startIndex, offsetBy: offset)
        let end = index(start, offsetBy: length)
        return subdata(in: start..<end)
    }
}
