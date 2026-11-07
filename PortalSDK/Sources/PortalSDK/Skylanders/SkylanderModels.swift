import Foundation

/// The two numbers that identify a figure type (not one physical copy).
public struct SkylanderIdentity: Hashable, Sendable {
    public let figureID: UInt16
    public let variantID: UInt16

    public init(figureID: UInt16, variantID: UInt16) {
        self.figureID = figureID
        self.variantID = variantID
    }

    public var figureIDHex: String { String(format: "0x%04X", figureID) }
    public var variantIDHex: String { String(format: "0x%04X", variantID) }
}

public enum SkylanderChecksum {
    /// CRC-16/CCITT-FALSE: polynomial 0x1021, initial value 0xFFFF, no reflection, no final XOR.
    public static func crc16CCITT(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
            }
        }
        return crc
    }
}

/// Blocks 0 and 1 of a figure, checked and parsed.
/// - `uid` tells two copies of the same figure apart.
/// - `identity` says which figure it is (little-endian: block 1 bytes 0-1 and 12-13).
public struct SkylanderHeader: Hashable, Sendable {
    public let uid: Data
    public let identity: SkylanderIdentity

    public init(block0: Data, block1: Data) throws {
        let a = [UInt8](block0)
        let b = [UInt8](block1)
        guard a.count == 16, b.count == 16 else { throw PortalError.malformedFrame }

        // Byte 4 of block 0 is the XOR of the four UID bytes.
        guard a[4] == (a[0] ^ a[1] ^ a[2] ^ a[3]) else { throw PortalError.checksumFailed }

        // Block 1 bytes 14-15 hold a CRC16 over block 0 plus the first 14 bytes of block 1 (little-endian).
        let stored = UInt16(b[14]) | UInt16(b[15]) << 8
        guard SkylanderChecksum.crc16CCITT(Data(a + b[0..<14])) == stored else {
            throw PortalError.checksumFailed
        }

        uid = Data(a[0..<4])
        identity = SkylanderIdentity(
            figureID: UInt16(b[0]) | UInt16(b[1]) << 8,
            variantID: UInt16(b[12]) | UInt16(b[13]) << 8
        )
    }
}

public struct BlockReadResult: Sendable {
    public let block: Int
    public let data: Data?
    public let errorDescription: String?
}

/// A complete 1,024-byte image (64 blocks of 16 bytes).
public struct SkylanderDump: Sendable, Equatable {
    public static let blockCount = 64
    public let blocks: [Data]

    public init(blocks: [Data]) throws {
        guard blocks.count == Self.blockCount, blocks.allSatisfy({ $0.count == 16 }) else {
            throw PortalError.incompleteDump
        }
        self.blocks = blocks
    }

    public init(results: [BlockReadResult]) throws {
        var byBlock: [Int: Data] = [:]
        for result in results {
            if let data = result.data { byBlock[result.block] = data }
        }
        try self.init(blocks: (0..<Self.blockCount).map { byBlock[$0] ?? Data() })
    }

    public var bytes: Data { blocks.reduce(into: Data()) { $0.append($1) } }

    public func header() throws -> SkylanderHeader {
        try SkylanderHeader(block0: blocks[0], block1: blocks[1])
    }
}
