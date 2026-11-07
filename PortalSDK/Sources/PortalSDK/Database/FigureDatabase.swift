import Foundation

/// One line of figures.json.
public struct FigureRecord: Decodable, Hashable, Sendable {
    public let number: Int          // the unique figure number apps should store
    public let figureID: UInt16
    public let variantID: UInt16
    public let name: String
    public let character: String?
    public let element: String?
    public let game: String?
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case number, figureID, variantID, name, character, element, game, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        figureID = try Self.hex16(c, .figureID)
        variantID = try Self.hex16(c, .variantID)
        name = try c.decode(String.self, forKey: .name)
        character = try c.decodeIfPresent(String.self, forKey: .character)
        element = try c.decodeIfPresent(String.self, forKey: .element)
        game = try c.decodeIfPresent(String.self, forKey: .game)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    private static func hex16(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> UInt16 {
        let text = try c.decode(String.self, forKey: key)
        let digits = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
        guard let value = UInt16(digits, radix: 16) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c,
                debugDescription: "Expected hex like 0x0013, got \"\(text)\""
            )
        }
        return value
    }
}

public enum ResolvedFigure: Hashable, Sendable {
    case known(FigureRecord)
    case unknown(SkylanderIdentity)

    /// The single unique figure number, or nil if the database doesn't know this figure yet.
    public var number: Int? {
        if case .known(let record) = self { return record.number }
        return nil
    }
}

public struct FigureDatabase: Sendable {
    public enum LoadError: Error, Equatable {
        case unsupportedSchema(Int)
        case duplicateNumber(Int)
        case duplicateIDs(figureID: UInt16, variantID: UInt16)
    }

    private struct File: Decodable {
        let schemaVersion: Int
        let databaseVersion: String?
        let figures: [FigureRecord]
    }

    public let version: String?
    public let records: [FigureRecord]
    private let byIdentity: [SkylanderIdentity: FigureRecord]
    private let byNumber: [Int: FigureRecord]

    public static let empty: FigureDatabase = {
        // An empty list can't fail validation.
        // swiftlint:disable:next force_try
        try! FigureDatabase(records: [], version: nil)
    }()

    public init(json: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: json)
        guard file.schemaVersion == 1 else { throw LoadError.unsupportedSchema(file.schemaVersion) }
        try self.init(records: file.figures, version: file.databaseVersion)
    }

    private init(records: [FigureRecord], version: String?) throws {
        var identities: [SkylanderIdentity: FigureRecord] = [:]
        var numbers: [Int: FigureRecord] = [:]
        for record in records {
            if numbers[record.number] != nil { throw LoadError.duplicateNumber(record.number) }
            let key = SkylanderIdentity(figureID: record.figureID, variantID: record.variantID)
            if identities[key] != nil {
                throw LoadError.duplicateIDs(figureID: record.figureID, variantID: record.variantID)
            }
            numbers[record.number] = record
            identities[key] = record
        }
        self.records = records
        self.version = version
        self.byIdentity = identities
        self.byNumber = numbers
    }

    // MARK: Loading

    /// The figures.json shipped inside the SDK.
    public static func bundled() throws -> FigureDatabase {
        guard let url = Bundle.module.url(forResource: "figures", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try FigureDatabase(json: Data(contentsOf: url))
    }

    /// Where an app-level override file lives on the device.
    public static var userFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PortalSDK/figures.user.json")
    }

    /// Bundled figures, with entries from the user file layered on top (user entries win).
    public static func loadDefault() throws -> FigureDatabase {
        let bundled = try bundled()
        guard let data = try? Data(contentsOf: userFileURL) else { return bundled }
        return try bundled.merging(FigureDatabase(json: data))
    }

    /// Validates a downloaded or edited file, then saves it as the user override.
    public static func installUserFile(_ json: Data) throws {
        _ = try FigureDatabase(json: json)
        try FileManager.default.createDirectory(
            at: userFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try json.write(to: userFileURL, options: .atomic)
    }

    /// Entries in `other` replace entries of this database with the same number or the same IDs.
    public func merging(_ other: FigureDatabase) throws -> FigureDatabase {
        let kept = records.filter { base in
            other.byNumber[base.number] == nil
                && other.byIdentity[SkylanderIdentity(figureID: base.figureID, variantID: base.variantID)] == nil
        }
        return try FigureDatabase(records: kept + other.records, version: other.version ?? version)
    }

    // MARK: Lookup

    public func lookup(_ identity: SkylanderIdentity) -> FigureRecord? { byIdentity[identity] }
    public func lookup(number: Int) -> FigureRecord? { byNumber[number] }

    public func resolve(_ header: SkylanderHeader) -> ResolvedFigure {
        if let record = lookup(header.identity) { return .known(record) }
        return .unknown(header.identity)
    }

    /// A ready-to-paste figures.json entry for a figure the database doesn't know yet.
    public func suggestedEntry(for identity: SkylanderIdentity) -> String {
        let next = (records.map(\.number).max() ?? 0) + 1
        return """
        {
          "number": \(next),
          "figureID": "\(identity.figureIDHex)",
          "variantID": "\(identity.variantIDHex)",
          "name": "TODO: figure name"
        }
        """
    }
}
