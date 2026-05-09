import Foundation

/// On-the-wire clipboard snapshot. Spec: docs/SYNC_PROTOCOL.md §3.
public struct Clipboard: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text  = "Text"
        case image = "Image"
        case file  = "File"
        case group = "Group"
    }

    public var type: Kind
    public var hash: String?
    public var text: String
    public var hasData: Bool
    public var dataName: String?
    public var size: Int?

    public init(
        type: Kind,
        hash: String? = nil,
        text: String,
        hasData: Bool,
        dataName: String? = nil,
        size: Int? = nil
    ) {
        self.type = type
        self.hash = Self.normalizeHash(hash)
        self.text = text
        self.hasData = hasData
        self.dataName = dataName
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case type, hash, text, hasData, dataName, size
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type    = try c.decode(Kind.self, forKey: .type)
        text    = try c.decode(String.self, forKey: .text)
        hasData = try c.decode(Bool.self, forKey: .hasData)
        hash    = Self.normalizeHash(try c.decodeIfPresent(String.self, forKey: .hash))
        dataName = try c.decodeIfPresent(String.self, forKey: .dataName)
        size     = try c.decodeIfPresent(Int.self, forKey: .size)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(hash, forKey: .hash)
        try c.encode(text, forKey: .text)
        try c.encode(hasData, forKey: .hasData)
        try c.encodeIfPresent(dataName, forKey: .dataName)
        try c.encodeIfPresent(size, forKey: .size)
    }

    /// §3.1 — empty / whitespace-only hash is normalized to nil so the encoder omits the key.
    private static func normalizeHash(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }
}

public extension Clipboard {
    /// §4.4 — null/empty `expected` matches anything.
    static func hashMatches(expected: String?, actual: String) -> Bool {
        guard let e = expected?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty else {
            return true
        }
        return e.uppercased() == actual.uppercased()
    }
}
