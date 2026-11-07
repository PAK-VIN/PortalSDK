import Foundation

public enum PortalEvent: Sendable, Equatable {
    /// The set of slots that have something on them changed. Fires once for the first status frame, too.
    case slotsChanged(Set<Int>)
}

/// Talks the portal protocol over a `PortalLink`: one request at a time, with timeouts,
/// while the portal's 0.5 s status stream is turned into `PortalEvent`s.
public actor PortalSession {
    private struct Waiter {
        let id: Int
        let match: @Sendable (Data) -> Bool
        let continuation: CheckedContinuation<Data, Error>
    }

    private let link: PortalLink
    private let log: @Sendable (String) -> Void
    private let verboseStatus: Bool
    private var pump: Task<Void, Never>?
    private var waiter: Waiter?
    private var nextID = 0
    private var lastSlots: Set<Int>?

    public nonisolated let events: AsyncStream<PortalEvent>
    private nonisolated let eventContinuation: AsyncStream<PortalEvent>.Continuation

    public init(link: PortalLink,
                verboseStatus: Bool = false,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.link = link
        self.log = log
        self.verboseStatus = verboseStatus
        let made = AsyncStream<PortalEvent>.makeStream()
        events = made.stream
        eventContinuation = made.continuation
    }

    // MARK: Lifecycle

    /// Starts reading frames from the link. Safe to call more than once.
    public func start() {
        guard pump == nil else { return }
        pump = Task { [link] in
            for await frame in link.frames {
                await self.handle(frame)
            }
        }
    }

    public func stop() {
        pump?.cancel()
        pump = nil
        failWaiter(PortalError.notConnected)
    }

    /// Call when the Bluetooth connection drops, so waiting requests fail fast and presence is re-reported.
    public func linkDidDisconnect() {
        lastSlots = nil
        failWaiter(PortalError.notConnected)
    }

    // MARK: Commands

    public func activate() async throws {
        _ = try await request(PortalProtocol.activate(), timeout: .seconds(2)) {
            $0.first == PortalProtocol.activateTag
        }
        log("Portal activated")
    }

    public func setColor(red: UInt8, green: UInt8, blue: UInt8) async throws {
        let command = PortalProtocol.color(red: red, green: green, blue: blue)
        log("TX \(command.hexString)")
        try await link.write(command)
    }

    /// Sends bytes as they are. Replies show up in the log.
    public func sendRaw(_ data: Data) async throws {
        log("TX \(data.hexString)")
        try await link.write(data)
    }

    /// Reads one 16-byte block. Requests are queued one at a time.
    public func readBlock(slot: Int, block: Int, timeout: Duration = .seconds(1)) async throws -> Data {
        guard (0..<PortalStatusFrame.slotCount).contains(slot), (0..<SkylanderDump.blockCount).contains(block) else {
            throw PortalError.malformedFrame
        }
        let slotByte = UInt8(0x10 + slot)
        let blockByte = UInt8(block)
        let reply = try await request(PortalProtocol.readBlock(slot: slot, block: block), timeout: timeout) {
            let b = [UInt8]($0)
            return b.count == PortalProtocol.frameLength
                && b[0] == PortalProtocol.queryTag
                && b[1] == slotByte
                && b[2] == blockByte
        }
        let bytes = [UInt8](reply)
        return Data(bytes[3..<19])
    }

    /// Reads and checks blocks 0 and 1, retrying a few times (a figure may not be readable the instant it lands).
    public func readHeader(slot: Int, attempts: Int = 3) async throws -> SkylanderHeader {
        var lastError: Error = PortalError.timeout
        for attempt in 1...max(1, attempts) {
            do {
                let block0 = try await readBlock(slot: slot, block: 0)
                let block1 = try await readBlock(slot: slot, block: 1)
                return try SkylanderHeader(block0: block0, block1: block1)
            } catch {
                lastError = error
                if Task.isCancelled { throw CancellationError() }
                log("Header read attempt \(attempt) failed: \(error.localizedDescription)")
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        throw lastError
    }

    /// Reads a range of blocks and reports each one, so one bad block doesn't hide the rest.
    public func readBlocks(slot: Int,
                           blocks: Range<Int> = 0..<SkylanderDump.blockCount,
                           progress: (@Sendable (Int) -> Void)? = nil) async -> [BlockReadResult] {
        var results: [BlockReadResult] = []
        for block in blocks {
            if Task.isCancelled { break }
            do {
                let data = try await readBlock(slot: slot, block: block)
                results.append(BlockReadResult(block: block, data: data, errorDescription: nil))
            } catch {
                results.append(BlockReadResult(block: block, data: nil, errorDescription: error.localizedDescription))
            }
            progress?(block)
        }
        return results
    }

    // MARK: Internals

    private func handle(_ frame: Data) {
        let bytes = [UInt8](frame)
        guard let tag = bytes.first else { return }

        if tag == PortalProtocol.statusTag {
            guard let status = PortalStatusFrame(frame) else { return }
            if verboseStatus { log("RX \(frame.hexString)") }
            let slots = Set(status.occupiedSlots)
            if slots != lastSlots {
                lastSlots = slots
                log("Occupied slots: \(slots.sorted())")
                eventContinuation.yield(.slotsChanged(slots))
            }
            return
        }

        log("RX \(frame.hexString)")
        if let waiting = waiter, waiting.match(frame) {
            waiter = nil
            waiting.continuation.resume(returning: frame)
        }
    }

    private func request(_ command: Data,
                         timeout: Duration,
                         match: @escaping @Sendable (Data) -> Bool) async throws -> Data {
        // One request at a time: wait for the previous one to finish.
        var waitedMs = 0
        while waiter != nil {
            guard waitedMs < 3000 else { throw PortalError.busy }
            try await Task.sleep(for: .milliseconds(20))
            waitedMs += 20
        }

        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            // Install the waiter BEFORE writing: replies can arrive within milliseconds.
            waiter = Waiter(id: id, match: match, continuation: continuation)
            Task { await self.transmit(command, for: id) }
            Task {
                try? await Task.sleep(for: timeout)
                await self.fail(id, PortalError.timeout)
            }
        }
    }

    private func transmit(_ command: Data, for id: Int) async {
        log("TX \(command.hexString)")
        do {
            try await link.write(command)
        } catch {
            fail(id, error)
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        guard let waiting = waiter, waiting.id == id else { return }
        waiter = nil
        waiting.continuation.resume(throwing: error)
    }

    private func failWaiter(_ error: Error) {
        guard let waiting = waiter else { return }
        waiter = nil
        waiting.continuation.resume(throwing: error)
    }
}
