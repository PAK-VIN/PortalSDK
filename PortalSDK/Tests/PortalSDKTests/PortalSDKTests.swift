import XCTest
@testable import PortalSDK

// Real bytes captured from a Big Bang Trigger Happy on a Trap Team portal.
private let block0Hex = "0F AF 22 54 D6 81 01 0F C4 22 00 00 00 00 00 13"
private let block1Hex = "13 00 00 00 76 28 10 A3 A3 8A 00 00 05 28 A0 97"

private func status(_ presence: String, counter: String = "5C") -> Data {
    Data(hex: "53 \(presence) \(counter) 00 AA AE 02 19 00 00 00 00 00 00 00 00 00")!
}

// MARK: - Status frames

final class StatusFrameTests: XCTestCase {
    func testPresenceBitsMatchTheCaptures() {
        XCTAssertEqual(PortalStatusFrame(status("00 00 00 00"))?.occupiedSlots, [])
        XCTAssertEqual(PortalStatusFrame(status("01 00 00 00"))?.occupiedSlots, [0])      // one figure
        XCTAssertEqual(PortalStatusFrame(status("04 00 00 00"))?.occupiedSlots, [1])      // trap only
        XCTAssertEqual(PortalStatusFrame(status("05 00 00 00"))?.occupiedSlots, [0, 1])   // figure + trap
        XCTAssertEqual(PortalStatusFrame(status("11 00 00 00"))?.occupiedSlots, [0, 2])   // two figures
        XCTAssertEqual(PortalStatusFrame(status("15 00 00 00"))?.occupiedSlots, [0, 1, 2])
    }

    func testCounterIsParsed() {
        XCTAssertEqual(PortalStatusFrame(status("01 00 00 00", counter: "26"))?.counter, 0x26)
    }

    func testRejectsOtherFramesAndWrongLength() {
        XCTAssertNil(PortalStatusFrame(Data(hex: "41 01 62 02 19 AA 01 80 5F C6 B0 CC F8 00 00 00 00 00 00 00")!))
        XCTAssertNil(PortalStatusFrame(Data(hex: "53 01 00 00 00")!))
    }

    func testStaleTailBytesAreIgnored() {
        let frame = Data(hex: "53 01 00 00 00 5B 00 AA AC 02 19 00 00 00 00 05 28 A0 97 00")!
        XCTAssertEqual(PortalStatusFrame(frame)?.occupiedSlots, [0])
    }
}

// MARK: - Header parsing

final class HeaderTests: XCTestCase {
    func testParsesRealFigure() throws {
        let header = try SkylanderHeader(block0: Data(hex: block0Hex)!, block1: Data(hex: block1Hex)!)
        XCTAssertEqual(header.uid, Data(hex: "0F AF 22 54")!)
        XCTAssertEqual(header.identity.figureID, 0x0013)
        XCTAssertEqual(header.identity.variantID, 0x2805)
        XCTAssertEqual(header.identity.figureIDHex, "0x0013")
        XCTAssertEqual(header.identity.variantIDHex, "0x2805")
    }

    func testCRCMatchesCapturedValue() {
        let input = Data(hex: block0Hex)! + Data(hex: block1Hex)!.prefix(14)
        XCTAssertEqual(SkylanderChecksum.crc16CCITT(input), 0x97A0)
    }

    func testCorruptedBlocksAreRejected() {
        var badUID = Data(hex: block0Hex)!
        badUID[0] ^= 0xFF
        XCTAssertThrowsError(try SkylanderHeader(block0: badUID, block1: Data(hex: block1Hex)!)) {
            XCTAssertEqual($0 as? PortalError, .checksumFailed)
        }

        var badBlock1 = Data(hex: block1Hex)!
        badBlock1[4] ^= 0x01
        XCTAssertThrowsError(try SkylanderHeader(block0: Data(hex: block0Hex)!, block1: badBlock1)) {
            XCTAssertEqual($0 as? PortalError, .checksumFailed)
        }
    }

    func testWrongSizeIsRejected() {
        XCTAssertThrowsError(try SkylanderHeader(block0: Data(), block1: Data()))
    }

    func testHexHelpers() {
        XCTAssertEqual(Data(hex: "51 10 00")?.hexString, "51 10 00")
        XCTAssertNil(Data(hex: "5"))
        XCTAssertNil(Data(hex: "ZZ"))
    }
}

// MARK: - Database

final class DatabaseTests: XCTestCase {
    func testBundledDatabaseResolvesBigBangTriggerHappy() throws {
        let database = try FigureDatabase.bundled()
        let header = try SkylanderHeader(block0: Data(hex: block0Hex)!, block1: Data(hex: block1Hex)!)
        guard case .known(let record) = database.resolve(header) else { return XCTFail("Expected a known figure") }
        XCTAssertEqual(record.name, "Big Bang Trigger Happy")
        XCTAssertEqual(record.number, 1)
        XCTAssertEqual(database.resolve(header).number, 1)
    }

    func testUnknownFigureKeepsItsIdentity() throws {
        let database = try FigureDatabase.bundled()
        let identity = SkylanderIdentity(figureID: 0x000F, variantID: 0x0000)
        XCTAssertNil(database.lookup(identity))
        XCTAssertTrue(database.suggestedEntry(for: identity).contains("\"number\": 2"))
        XCTAssertTrue(database.suggestedEntry(for: identity).contains("0x000F"))
    }

    func testDuplicatesAreRejected() {
        let sameNumber = #"{"schemaVersion":1,"figures":[{"number":1,"figureID":"0x0001","variantID":"0x0000","name":"A"},{"number":1,"figureID":"0x0002","variantID":"0x0000","name":"B"}]}"#
        XCTAssertThrowsError(try FigureDatabase(json: Data(sameNumber.utf8)))

        let sameIDs = #"{"schemaVersion":1,"figures":[{"number":1,"figureID":"0x0001","variantID":"0x0000","name":"A"},{"number":2,"figureID":"0x0001","variantID":"0x0000","name":"B"}]}"#
        XCTAssertThrowsError(try FigureDatabase(json: Data(sameIDs.utf8)))
    }

    func testBadHexAndSchemaAreRejected() {
        let badHex = #"{"schemaVersion":1,"figures":[{"number":1,"figureID":"0xZZZZ","variantID":"0x0000","name":"A"}]}"#
        XCTAssertThrowsError(try FigureDatabase(json: Data(badHex.utf8)))

        let badSchema = #"{"schemaVersion":99,"figures":[]}"#
        XCTAssertThrowsError(try FigureDatabase(json: Data(badSchema.utf8)))
    }

    func testMergingLetsUserEntriesWin() throws {
        let base = try FigureDatabase(json: Data(#"{"schemaVersion":1,"figures":[{"number":1,"figureID":"0x0001","variantID":"0x0000","name":"Old"}]}"#.utf8))
        let user = try FigureDatabase(json: Data(#"{"schemaVersion":1,"figures":[{"number":1,"figureID":"0x0001","variantID":"0x0000","name":"New"},{"number":2,"figureID":"0x0002","variantID":"0x0000","name":"Extra"}]}"#.utf8))
        let merged = try base.merging(user)
        XCTAssertEqual(merged.lookup(number: 1)?.name, "New")
        XCTAssertEqual(merged.records.count, 2)
    }
}

// MARK: - Session (with a fake portal)

private final class MockLink: PortalLink, @unchecked Sendable {
    let frames: AsyncStream<Data>
    let states: AsyncStream<LinkState>
    private let frameContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<LinkState>.Continuation
    var responder: (@Sendable (Data) -> [Data])?
    private(set) var written: [Data] = []

    init() {
        let f = AsyncStream<Data>.makeStream()
        let s = AsyncStream<LinkState>.makeStream()
        frames = f.stream
        frameContinuation = f.continuation
        states = s.stream
        stateContinuation = s.continuation
    }

    func connect() { stateContinuation.yield(.connected) }
    func disconnect() {}

    func write(_ data: Data) async throws {
        written.append(data)
        for frame in responder?(data) ?? [] { frameContinuation.yield(frame) }
    }

    func push(_ data: Data) { frameContinuation.yield(data) }
}

final class SessionTests: XCTestCase {
    private func blockReply(slotByte: UInt8, block: UInt8, hex: String) -> Data {
        Data([0x51, slotByte, block]) + Data(hex: hex)! + Data([0x00])
    }

    func testReadHeaderIgnoresInterleavedStatusFrames() async throws {
        let link = MockLink()
        link.responder = { [self] command in
            let bytes = [UInt8](command)
            guard bytes.first == 0x51 else { return [] }
            let hex = bytes[2] == 0 ? block0Hex : block1Hex
            return [status("01 00 00 00"), blockReply(slotByte: bytes[1], block: bytes[2], hex: hex)]
        }
        let session = PortalSession(link: link)
        await session.start()

        let header = try await session.readHeader(slot: 0)
        XCTAssertEqual(header.identity.figureID, 0x0013)
        XCTAssertEqual(header.identity.variantID, 0x2805)
        XCTAssertEqual(link.written.first, Data([0x51, 0x10, 0x00, 0, 0, 0]))
    }

    func testActivateAcceptsTheCapturedReply() async throws {
        let link = MockLink()
        link.responder = { command in
            guard command.first == 0x41 else { return [] }
            return [Data(hex: "41 01 62 02 19 AA 01 80 5F C6 B0 CC F8 00 00 00 00 00 00 00")!]
        }
        let session = PortalSession(link: link)
        await session.start()
        try await session.activate()
        XCTAssertEqual(link.written.first, Data([0x41, 0x01, 0, 0, 0, 0]))
    }

    func testSilentPortalTimesOut() async throws {
        let link = MockLink()
        let session = PortalSession(link: link)
        await session.start()
        do {
            _ = try await session.readBlock(slot: 0, block: 0, timeout: .milliseconds(150))
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? PortalError, .timeout)
        }
    }

    func testSlotsChangedEventFiresOnFirstStatusAndOnChange() async {
        let link = MockLink()
        let session = PortalSession(link: link)
        await session.start()
        var iterator = session.events.makeAsyncIterator()

        link.push(status("01 00 00 00"))
        link.push(status("01 00 00 00", counter: "5D"))   // same slots: no event
        link.push(status("15 00 00 00", counter: "5E"))

        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first, .slotsChanged([0]))
        XCTAssertEqual(second, .slotsChanged([0, 1, 2]))
    }

    func testInvalidSlotOrBlockIsRejected() async {
        let session = PortalSession(link: MockLink())
        do {
            _ = try await session.readBlock(slot: 0, block: 64)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? PortalError, .malformedFrame)
        }
    }
}
