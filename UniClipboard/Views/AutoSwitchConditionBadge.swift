import SwiftUI

/// Compact one-line badge summarizing a server's §5.3 auto-switch condition,
/// shown on server-list rows (Settings → 服务器列表 and the Home switcher
/// sheet) so the whole routing setup is visible at a glance without opening
/// each editor.
///
/// Icons mirror `AutoSwitchSection`'s picker (`SettingsView.swift`) and the
/// Setup picker so list and editor share one visual vocabulary. `.none`
/// renders nothing — a manual-only server shows no condition line, matching
/// the prior behavior where only the Wi-Fi SSID list was surfaced.
struct AutoSwitchConditionBadge: View {
    let strategy: AutoSwitchStrategy
    let wifiNames: [String]

    var body: some View {
        switch strategy {
        case .none:
            EmptyView()
        case .wifi:
            badge(icon: strategy.iconName, text: wifiText)
        case .cellular:
            badge(icon: strategy.iconName, text: Text("蜂窝"))
        case .tailscale:
            // Brand name — verbatim so it isn't treated as a catalog key.
            badge(icon: strategy.iconName, text: Text(verbatim: "Tailscale"))
        }
    }

    /// Wi-Fi shows the joined SSID list, or the bare "Wi-Fi" brand when the
    /// strategy is set but no SSID has been pinned yet (empty list).
    private var wifiText: Text {
        let names = wifiNames.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // SSID names + the "Wi-Fi" brand are verbatim — neither is a catalog key.
        return Text(verbatim: names.isEmpty ? "Wi-Fi" : names.joined(separator: ", "))
    }

    @ViewBuilder
    private func badge(icon: String, text: Text) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            text
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
}
