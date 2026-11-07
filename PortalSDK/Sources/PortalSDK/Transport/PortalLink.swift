import Foundation

public enum LinkState: Sendable, Equatable {
    case idle
    case poweredOff
    case unauthorized
    case unsupported
    case scanning
    case connecting
    case connected        // characteristics found and notifications are on
    case disconnected     // lost an established connection; the link will retry
}

/// The byte pipe to the portal. `BLEPortalLink` is the real one; tests use a mock.
public protocol PortalLink: AnyObject, Sendable {
    /// Every 20-byte notification from the portal.
    var frames: AsyncStream<Data> { get }
    var states: AsyncStream<LinkState> { get }
    func connect()
    func disconnect()
    /// Write with response to the command characteristic.
    func write(_ data: Data) async throws
}
