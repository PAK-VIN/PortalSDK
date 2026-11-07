import Foundation

extension Data {
    /// Parses "51 10 00" or "511000". Returns nil for odd length or non-hex characters.
    public init?(hex: String) {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    /// "51 10 00 ..." in upper case, the same style as the debugger console.
    public var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
