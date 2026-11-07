import Combine
import Foundation

public struct ScannedFigure: Equatable, Sendable {
    public let slot: Int
    public let header: SkylanderHeader
    public let resolved: ResolvedFigure
}

/// High-level, one-item-at-a-time front door for apps.
///
/// Connects to the portal, keeps it activated, and publishes what is on it.
/// Exactly one item is supported: with two or more, `state` becomes `.unsupported`.
@MainActor
public final class PortalClient: ObservableObject {
    public enum State: Equatable {
        case idle
        case bluetoothOff
        case bluetoothUnauthorized
        case bluetoothUnsupported
        case searching                       // scanning for, or connecting to, the portal
        case ready                           // connected and activated, nothing on the portal
        case reading
        case figure(ScannedFigure)
        case unsupported(String)             // more than one item, or something that isn't a readable figure
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    public private(set) var database: FigureDatabase

    private let link: PortalLink
    private let session: PortalSession
    private let log: @Sendable (String) -> Void
    private var listeners: [Task<Void, Never>] = []
    private var readTask: Task<Void, Never>?
    private var currentSlots: Set<Int> = []
    private var isActivated = false

    public init(link: PortalLink = BLEPortalLink(),
                database: FigureDatabase? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.link = link
        self.log = log
        self.session = PortalSession(link: link, log: log)
        if let database {
            self.database = database
        } else {
            do {
                self.database = try FigureDatabase.loadDefault()
            } catch {
                log("Figure database problem: \(error). Using the bundled copy only.")
                self.database = (try? FigureDatabase.bundled()) ?? .empty
            }
        }
    }

    // MARK: Lifecycle

    public func start() {
        guard listeners.isEmpty else { return }
        Task { await session.start() }
        listeners.append(Task { [weak self, link] in
            for await linkState in link.states {
                await self?.handle(linkState)
            }
        })
        listeners.append(Task { [weak self, session] in
            for await event in session.events {
                self?.handle(event)
            }
        })
        link.connect()
    }

    public func stop() {
        listeners.forEach { $0.cancel() }
        listeners = []
        readTask?.cancel()
        link.disconnect()
        Task { await session.stop() }
        currentSlots = []
        isActivated = false
        state = .idle
    }

    // MARK: Tools

    public func readAllBlocks(progress: (@Sendable (Int) -> Void)? = nil) async throws -> [BlockReadResult] {
        guard case .figure(let figure) = state else { throw PortalError.notConnected }
        return await session.readBlocks(slot: figure.slot, progress: progress)
    }

    public func setColor(red: UInt8, green: UInt8, blue: UInt8) async throws {
        try await session.setColor(red: red, green: green, blue: blue)
    }

    public func sendRaw(hex: String) async throws {
        guard let data = Data(hex: hex), !data.isEmpty else { throw PortalError.malformedFrame }
        try await session.sendRaw(data)
    }

    /// Re-reads figures.json (and the user override) and re-matches the current figure without touching the portal.
    public func reloadDatabase() throws {
        database = try FigureDatabase.loadDefault()
        if case .figure(let figure) = state {
            state = .figure(ScannedFigure(slot: figure.slot,
                                          header: figure.header,
                                          resolved: database.resolve(figure.header)))
        }
    }

    // MARK: Internals

    private func handle(_ linkState: LinkState) async {
        switch linkState {
        case .idle:
            state = .idle
        case .poweredOff:
            await linkLost()
            state = .bluetoothOff
        case .unauthorized:
            await linkLost()
            state = .bluetoothUnauthorized
        case .unsupported:
            state = .bluetoothUnsupported
        case .scanning, .connecting:
            state = .searching
        case .disconnected:
            await linkLost()
            state = .searching
        case .connected:
            log("Portal connected")
            do {
                try await session.activate()
                isActivated = true
                reevaluate()
            } catch {
                state = .failed("Couldn't activate the portal: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ event: PortalEvent) {
        switch event {
        case .slotsChanged(let slots):
            currentSlots = slots
            reevaluate()
        }
    }

    private func linkLost() async {
        readTask?.cancel()
        isActivated = false
        currentSlots = []
        await session.linkDidDisconnect()
    }

    private func reevaluate() {
        readTask?.cancel()
        guard isActivated else { return }
        switch currentSlots.count {
        case 0:
            state = .ready
        case 1:
            let slot = currentSlots.first ?? 0
            state = .reading
            readTask = Task { await readFigure(slot: slot) }
        default:
            state = .unsupported("\(currentSlots.count) items are on the portal. Remove all but one figure.")
        }
    }

    private func readFigure(slot: Int) async {
        do {
            let header = try await session.readHeader(slot: slot)
            guard !Task.isCancelled else { return }
            let resolved = database.resolve(header)
            state = .figure(ScannedFigure(slot: slot, header: header, resolved: resolved))
            log("Figure \(header.identity.figureIDHex) / \(header.identity.variantIDHex), UID \(header.uid.hexString)")
        } catch {
            guard !Task.isCancelled else { return }
            state = .unsupported("Couldn't read this item: \(error.localizedDescription)")
        }
    }
}
