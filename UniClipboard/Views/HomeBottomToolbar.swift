import SwiftUI

/// Bottom toolbar replacing the TabView — search, server picker, sync.
/// Uses Liquid Glass styling on iOS 26+, falls back to thin material below.
struct HomeBottomToolbar: View {
    let serverLabel: String
    var isAutoSwitched: Bool = false
    var isSyncing: Bool = false
    let onSearch: () -> Void
    let onServerPicker: () -> Void
    let onSync: () -> Void

    var body: some View {
        HStack {
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .liquidGlassCircle()
            }

            Spacer()

            Button(action: onServerPicker) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(serverLabel)
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 52)
                .padding(.horizontal, 16)
                .liquidGlassCapsule()
                .overlay(alignment: .topTrailing) {
                    if isAutoSwitched {
                        Text("自动")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .offset(x: 6, y: -8)
                    }
                }
            }

            Spacer()

            Button(action: onSync) {
                Group {
                    if isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title2)
                    }
                }
                .frame(width: 52, height: 52)
                .liquidGlassCircle()
            }
            .disabled(isSyncing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

#Preview {
    VStack {
        Spacer()
        HomeBottomToolbar(
            serverLabel: "My Server",
            isAutoSwitched: true,
            isSyncing: false,
            onSearch: {},
            onServerPicker: {},
            onSync: {}
        )
    }
}
