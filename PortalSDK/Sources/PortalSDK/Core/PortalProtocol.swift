import Foundation

/// Command and frame layout of the Trap Team BLE portal, as reverse engineered from captures.
/// Every frame is 20 bytes. Commands go to characteristic ...1543, replies and status come back on ...1542.
enum PortalProtocol {
    static let frameLength = 20

    static let statusTag: UInt8 = 0x53     // 'S'  portal -> app, about every 0.5 s
    static let activateTag: UInt8 = 0x41   // 'A'
    static let colorTag: UInt8 = 0x43      // 'C'
    static let queryTag: UInt8 = 0x51      // 'Q'  read one 16-byte block

    static func activate() -> Data {
        Data([activateTag, 0x01, 0, 0, 0, 0])
    }

    static func color(red: UInt8, green: UInt8, blue: UInt8) -> Data {
        Data([colorTag, red, green, blue, 0, 0])
    }

    /// Slot byte is 0x10 + slot. Verified for slot 0 only.
    static func readBlock(slot: Int, block: Int) -> Data {
        Data([queryTag, UInt8(0x10 + slot), UInt8(block), 0, 0, 0])
    }
}

/// `53 | presence x4 | counter | active | AA xx 02 19 | stale bytes`
/// Presence uses 2 bits per slot; the low bit of each pair means "something is on this slot".
/// Bytes after index 10 are leftovers of the previous reply and must be ignored.
struct PortalStatusFrame: Equatable {
    static let slotCount = 16

    let presence: UInt32
    let counter: UInt8

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == PortalProtocol.frameLength, bytes[0] == PortalProtocol.statusTag else {
            return nil
        }
        presence = UInt32(bytes[1])
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3]) << 16
            | UInt32(bytes[4]) << 24
        counter = bytes[5]
    }

    var occupiedSlots: [Int] {
        (0..<Self.slotCount).filter { (presence >> UInt32($0 * 2)) & 1 == 1 }
    }
}
