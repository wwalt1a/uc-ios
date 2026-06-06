import Foundation

/// §5.3 — the single network condition under which a config auto-activates.
/// Each config picks exactly one. Persisted as its raw string; an absent or
/// unknown value decodes to `.none`.
public enum AutoSwitchStrategy: String, Codable, Sendable {
    case none       // never auto-activate (manual only)
    case wifi       // when connected to one of `autoSwitchWifiNames`
    case cellular   // on cellular data
    case tailscale  // when a Tailscale virtual network is up (100.64.0.0/10)

    /// SF Symbol name for this strategy — the single source of truth shared by
    /// the editor pickers (Settings + Setup) and the server-list condition
    /// badge, so the list and editor can't drift to different icons. It's just
    /// a `String`, so this stays valid in the SwiftUI/UIKit-free `Shared/` layer.
    public var iconName: String {
        switch self {
        case .none:      return "hand.raised"
        case .wifi:      return "wifi"
        case .cellular:  return "antenna.radiowaves.left.and.right"
        case .tailscale: return "network.badge.shield.half.filled"
        }
    }
}

/// One server profile. Spec: docs/SYNC_PROTOCOL.md §5.1.
public struct ServerConfig: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var url: String
    public var username: String
    public var password: String
    public var autoSwitchWifiNames: [String]
    /// §5.3 — the one network condition under which this config auto-activates.
    /// Only `.wifi` consults `autoSwitchWifiNames`.
    public var autoSwitchStrategy: AutoSwitchStrategy

    public init(
        id: String,
        name: String? = nil,
        url: String,
        username: String,
        password: String,
        autoSwitchWifiNames: [String] = [],
        autoSwitchStrategy: AutoSwitchStrategy = .none
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.password = password
        self.autoSwitchWifiNames = autoSwitchWifiNames
        self.autoSwitchStrategy = autoSwitchStrategy
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, username, password, autoSwitchWifiNames, autoSwitchStrategy
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(String.self, forKey: .id)
        name     = try c.decodeIfPresent(String.self, forKey: .name)
        url      = try c.decode(String.self, forKey: .url)
        username = try c.decode(String.self, forKey: .username)
        password = try c.decode(String.self, forKey: .password)
        autoSwitchWifiNames = try c.decodeIfPresent([String].self, forKey: .autoSwitchWifiNames) ?? []
        // Migration: pre-strategy data has no `autoSwitchStrategy`. A non-empty
        // SSID list meant "Wi-Fi auto-switch", so map it to `.wifi`; otherwise
        // `.none`. An unknown raw value also degrades to `.none`.
        if c.contains(.autoSwitchStrategy) {
            // Key present: decode it. An unknown raw value (e.g. a strategy a
            // newer build introduced, or null) degrades to `.none` — it must
            // NOT fall into the SSID-list migration below, or a config the user
            // never set to Wi-Fi would silently start auto-switching on Wi-Fi.
            autoSwitchStrategy = (try? c.decode(AutoSwitchStrategy.self, forKey: .autoSwitchStrategy)) ?? .none
        } else {
            // Key absent (pre-strategy data): a non-empty SSID list meant
            // "Wi-Fi auto-switch", so map it to `.wifi`; otherwise `.none`.
            autoSwitchStrategy = autoSwitchWifiNames.isEmpty ? .none : .wifi
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encode(username, forKey: .username)
        try c.encode(password, forKey: .password)
        try c.encode(autoSwitchWifiNames, forKey: .autoSwitchWifiNames)
        try c.encode(autoSwitchStrategy, forKey: .autoSwitchStrategy)
    }

    /// §5.1 — fall back to URL when name is nil/empty/whitespace.
    public var displayLabel: String {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        return url
    }

    /// §5.1 SSID normalization: trim → strip outer quotes → reject Android privacy placeholders.
    public static func normalizeSSID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.isEmpty || s == "<unknown ssid>" || s == "0x" { return nil }
        return s
    }

    /// §5.3 — true iff the normalized current SSID is in the normalized auto-switch list.
    public func matchesWifiName(_ currentSsid: String?) -> Bool {
        guard let target = Self.normalizeSSID(currentSsid) else { return false }
        return autoSwitchWifiNames.contains { Self.normalizeSSID($0) == target }
    }
}

/// Persisted multi-server collection. Spec: §5.2.
public struct ServerConfigList: Codable, Equatable, Hashable, Sendable {
    public var configs: [ServerConfig]
    public var activeConfigId: String?

    public init(
        configs: [ServerConfig] = [],
        activeConfigId: String? = nil
    ) {
        self.configs = configs
        self.activeConfigId = activeConfigId
    }

    private enum CodingKeys: String, CodingKey {
        // `manualOverrideConfigId` is decode-only: a pre-unification key we
        // migrate away from (see init(from:)) and never re-encode.
        case configs, activeConfigId, manualOverrideConfigId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configs = try c.decodeIfPresent([ServerConfig].self, forKey: .configs) ?? []
        let decodedActive = try c.decodeIfPresent(String.self, forKey: .activeConfigId)
        // One-shot migration: pre-unification builds persisted a home-chip
        // "pin" in `manualOverrideConfigId` that out-prioritized
        // `activeConfigId`. The pin concept is gone — the user's last
        // explicit pick IS the current server now — so promote a resolvable
        // legacy pin into `activeConfigId` and never re-encode the old key
        // (see encode(to:)). Absent/unresolvable → fall back to the
        // persisted `activeConfigId`.
        let legacyPin = try c.decodeIfPresent(String.self, forKey: .manualOverrideConfigId)
        if let pin = legacyPin, configs.contains(where: { $0.id == pin }) {
            activeConfigId = pin
        } else {
            activeConfigId = decodedActive
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(configs, forKey: .configs)
        try c.encodeIfPresent(activeConfigId, forKey: .activeConfigId)
    }

    /// §5.2 — stale activeConfigId falls back to configs[0]; nil iff configs is empty.
    public var activeConfig: ServerConfig? {
        guard !configs.isEmpty else { return nil }
        if let id = activeConfigId, let hit = configs.first(where: { $0.id == id }) { return hit }
        return configs.first
    }

    /// §5.3 — the server to use *right now*, applying the on-demand
    /// auto-switch rules as an overlay over the manual baseline. `nil` only
    /// when there's no config at all (mirrors `activeConfig`).
    ///
    /// Pure read — never mutates `activeConfigId`. The manual pick stays the
    /// persisted baseline; network rules override it transiently, so leaving
    /// a matched network restores the baseline and no two processes race to
    /// write the active id. The main app and the keyboard extension both call
    /// this to pick a server, so they stay in lockstep.
    public func effectiveActiveConfig(network: NetworkContext) -> ServerConfig? {
        resolveAutoSwitch(network: network) ?? activeConfig
    }

    /// §5.3 — the config a network rule selects for `network`, or `nil` when
    /// no rule applies (caller falls back to `activeConfig`).
    ///
    /// Priority **P1 Tailscale > P2 named Wi-Fi > P3 cellular**. Tailscale is
    /// on top because it overlays whatever the physical link is — when it's up
    /// and a config opts into it, it wins over the Wi-Fi the device is on.
    /// Each config picks exactly one strategy (`autoSwitchStrategy`). Within a
    /// tier the active config wins if it qualifies (anti-flap — don't bounce
    /// off a server that already fits), otherwise `configs` order decides
    /// (first-wins). Tailscale up but no config opted into it falls through to
    /// the Wi-Fi / cellular tiers. Nothing matches → nil → manual baseline.
    func resolveAutoSwitch(network: NetworkContext) -> ServerConfig? {
        let current = activeConfig
        func pick(_ matches: [ServerConfig]) -> ServerConfig? {
            guard !matches.isEmpty else { return nil }
            return matches.first { $0.id == current?.id } ?? matches.first
        }
        if network.isTailscale {
            if let hit = pick(configs.filter { $0.autoSwitchStrategy == .tailscale }) { return hit }
        }
        if let ssid = ServerConfig.normalizeSSID(network.ssid) {
            if let hit = pick(configs.filter {
                $0.autoSwitchStrategy == .wifi && $0.matchesWifiName(ssid)
            }) { return hit }
        }
        if network.isCellular {
            if let hit = pick(configs.filter { $0.autoSwitchStrategy == .cellular }) { return hit }
        }
        return nil
    }
}

/// Read-only legacy single-config shape. Spec: §5.5.
public struct LegacyServerConfig: Codable, Equatable, Sendable {
    public var url: String
    public var username: String
    public var password: String

    public init(url: String, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }

    /// §5.5 — wrap into a ServerConfigList with a fresh UUID v4 and mark active.
    public func migrated(idProvider: () -> String = { UUID().uuidString.lowercased() }) -> ServerConfigList {
        let cfg = ServerConfig(
            id: idProvider(),
            name: nil,
            url: url,
            username: username,
            password: password,
            autoSwitchWifiNames: []
        )
        return ServerConfigList(configs: [cfg], activeConfigId: cfg.id)
    }
}
