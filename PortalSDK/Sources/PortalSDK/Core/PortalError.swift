import Foundation

public enum PortalError: Error, Sendable, Equatable {
    case bluetoothUnavailable
    case notConnected
    case timeout
    case busy
    case malformedFrame
    case checksumFailed
    case incompleteDump
}

extension PortalError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth is unavailable. Turn it on in Settings."
        case .notConnected: return "The portal isn't connected."
        case .timeout: return "The portal didn't answer in time."
        case .busy: return "The portal is busy with another request."
        case .malformedFrame: return "The portal sent data in an unexpected format."
        case .checksumFailed: return "The data failed its checksum. Re-place the item, or it may not be a Skylanders figure."
        case .incompleteDump: return "Not every block could be read."
        }
    }
}
