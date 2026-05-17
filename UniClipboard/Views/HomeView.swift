import SwiftUI

/// Home tab — the focal point. Two cards (Server vs Device) bridged by a
/// connector strip that mirrors the auto-sync engine's current state.
/// Cycle 9: removed the "推送" floating accessory and the "应用到本机"
/// button — the engine handles both directions on a 1Hz foreground tick.
/// Save-to-Documents stays as a discrete user action on the server card.
struct HomeView: View {
    @Bindable var vm: AppViewModel

    private var engineState: SyncEngine.State { vm.engine.state }
    private var isExplicitlyRefreshing: Bool { vm.engine.isExplicitlyRefreshing }

    /// Server has a pending entry waiting for the user (auto-apply off).
    /// Drives card highlight and auto-expanded preview.
    private var serverHasUnwritten: Bool { engineState == .hasNewUnwritten }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let err = vm.engine.lastError {
                    errorRow(err, prefix: "")
                }
                if let err = vm.saveError {
                    errorRow(err, prefix: String(localized: "保存失败:"))
                }

                ServerSnapshotCard(
                    entry: vm.serverLatest,
                    lastSyncedAt: vm.engine.lastSyncedAt ?? vm.lastSyncedAt,
                    isSaving: vm.isSaving,
                    lastSavedFileURL: vm.lastSavedFileURL,
                    isHighlighted: serverHasUnwritten,
                    onSave: { Task { await vm.saveServerAttachment() } }
                )

                connector

                DeviceClipboardCard(
                    entry: vm.deviceClipboard,
                    inSyncWithServer: engineState == .succeeded
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable {
            await vm.engine.explicitRefresh()
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("剪贴板")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ServerChip(
                    activeServer: vm.effectiveActiveConfig,
                    defaultServerId: vm.servers.activeConfigId,
                    isAutoSwitched: vm.isAutoSwitchOverridden,
                    allServers: vm.servers.configs,
                    onSelect: { id in vm.servers.activeConfigId = id }
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    vm.engine.forceTickNow()
                } label: {
                    if isExplicitlyRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isExplicitlyRefreshing)
            }
        }
    }

    @ViewBuilder
    private func errorRow(_ err: SyncError, prefix: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(prefix.isEmpty ? errorMessage(err) : "\(prefix) \(errorMessage(err))")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let detail = err.underlying, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorMessage(_ err: SyncError) -> String {
        switch err.kind {
        case .authFailed:                return String(localized: "认证失败 — 请检查用户名和密码")
        case .connectTimeout:            return String(localized: "连接超时 — 请检查服务器地址")
        case .receiveTimeout:            return String(localized: "接收超时 — 请稍后重试")
        case .networkUnreachable:        return String(localized: "无法连接 — 请检查网络和 URL")
        case .invalidURL:                return String(localized: "服务器地址无效")
        case .decodingFailed:            return String(localized: "服务器返回的数据无法解析")
        case .protocolError(let code):   return String(localized: "服务器返回 HTTP \(code)")
        case .serverError(let code):     return String(localized: "服务器错误 \(code)")
        case .notFound:                  return String(localized: "服务器尚未发布剪贴板")
        case .hashMismatch:              return String(localized: "内容校验失败 — 文件可能损坏")
        }
    }

    private var connector: some View {
        HStack(spacing: 8) {
            if isExplicitlyRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: connectorIcon)
                    .foregroundStyle(connectorTint)
            }
            Text(connectorText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private var connectorIcon: String {
        switch engineState {
        case .idle:             return "circle.dashed"
        case .succeeded:        return "checkmark.circle.fill"
        case .hasNewUnwritten:  return "tray.and.arrow.down.fill"
        case .offlineRetrying:  return "arrow.triangle.2.circlepath"
        case .authFailed:       return "lock.slash.fill"
        }
    }

    private var connectorTint: Color {
        switch engineState {
        case .succeeded:        return .green
        case .hasNewUnwritten:  return .indigo
        case .offlineRetrying:  return .orange
        case .authFailed:       return .red
        case .idle:             return .secondary
        }
    }

    private var connectorText: LocalizedStringKey {
        if isExplicitlyRefreshing { return "同步中…" }
        switch engineState {
        case .idle:             return "准备同步…"
        case .succeeded:
            return vm.serverLatest == nil ? "已同步 · 等待新内容" : "已同步"
        case .hasNewUnwritten:  return "有新内容 · 未自动写入"
        case .offlineRetrying:  return "离线 · 重试中"
        case .authFailed:       return "认证失败 · 检查设置"
        }
    }
}

// MARK: - Server's-latest card

private struct ServerSnapshotCard: View {
    let entry: Clipboard?
    let lastSyncedAt: Date?
    let isSaving: Bool
    let lastSavedFileURL: URL?
    /// True when the engine has staged a new server entry that wasn't
    /// auto-written (auto-apply toggle is off). Card border / background
    /// pop, preview expands.
    let isHighlighted: Bool
    let onSave: () -> Void

    /// Save means "write the payload to Documents". Image and file are
    /// supported this cycle; Group disabled until §4.3 ZIP-traversal hash
    /// has its own slice.
    private var canSave: Bool {
        guard let e = entry else { return false }
        return e.hasData && (e.type == .image || e.type == .file)
    }

    var body: some View {
        GlassCard(highlighted: isHighlighted) {
            if let entry {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        ClipboardKindBadge(kind: entry.type, size: .medium)
                        Spacer()
                        Text("服务器")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(.tertiary.opacity(0.4), in: Capsule())
                    }

                    previewBlock(entry: entry, expanded: isHighlighted)

                    metadataRow(entry: entry)

                    if entry.hasData && (entry.type == .image || entry.type == .file) {
                        Divider().opacity(0.4)
                        Button {
                            onSave()
                        } label: {
                            HStack(spacing: 6) {
                                if isSaving {
                                    ProgressView().controlSize(.small)
                                    Text("正在保存…")
                                } else {
                                    Image(systemName: "square.and.arrow.down")
                                    Text("保存到 Documents")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(!canSave || isSaving)
                    }

                    if let savedURL = lastSavedFileURL {
                        savedToCaption(url: savedURL)
                    }
                }
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private func previewBlock(entry: Clipboard, expanded: Bool) -> some View {
        switch entry.type {
        case .text:
            Text(entry.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(expanded ? 12 : 4)
                .multilineTextAlignment(.leading)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        case .image, .file, .group:
            HStack(spacing: 14) {
                ClipboardKindBadge(kind: entry.type, size: .large, showsLabel: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let dataName = entry.dataName, dataName != entry.text {
                        Text(dataName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(14)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func metadataRow(entry: Clipboard) -> some View {
        HStack(spacing: 12) {
            if let size = entry.size {
                Label(formatSize(size, kind: entry.type), systemImage: "ruler")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let lastSyncedAt {
                Label(lastSyncedAt.relativeShort, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let hash = entry.hash {
                Text(hash.shortHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// "已保存到 …/<dataName>" line under the action row. Sticky until
    /// the next save attempt or a refresh — `AppViewModel` clears it.
    private func savedToCaption(url: URL) -> some View {
        let leaf = url.pathComponents.suffix(2).joined(separator: "/")
        return HStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(.green)
            Text("已保存到 \(leaf)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("服务器还没有发布过剪贴板")
                .font(.subheadline.weight(.semibold))
            Text("复制内容后会自动同步上传")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Device-current card

private struct DeviceClipboardCard: View {
    let entry: Clipboard?
    let inSyncWithServer: Bool

    var body: some View {
        GlassCard {
            if let entry {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        ClipboardKindBadge(kind: entry.type, size: .medium)
                        Spacer()
                        Text(inSyncWithServer ? "已同步" : "本机")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(inSyncWithServer ? .green : .indigo)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                (inSyncWithServer ? Color.green : Color.indigo).opacity(0.12),
                                in: Capsule()
                            )
                    }

                    previewBlock(entry: entry)

                    if let size = entry.size {
                        HStack(spacing: 10) {
                            Label(formatSize(size, kind: entry.type), systemImage: sizeIcon(for: entry.type))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            } else {
                Text("无法读取本机剪贴板")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private func previewBlock(entry: Clipboard) -> some View {
        switch entry.type {
        case .text:
            Text(entry.text)
                .font(.callout)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        case .image, .file, .group:
            HStack(spacing: 14) {
                ClipboardKindBadge(kind: entry.type, size: .large, showsLabel: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let dataName = entry.dataName, dataName != entry.text {
                        Text(dataName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(14)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func sizeIcon(for kind: Clipboard.Kind) -> String {
        switch kind {
        case .text:                  return "character"
        case .image, .file, .group:  return "ruler"
        }
    }
}

// MARK: - Top toolbar server chip

private struct ServerChip: View {
    /// Effective active server — what the sync engine is actually talking
    /// to right now. May differ from the user's default when a Wi-Fi
    /// auto-switch is in effect (§5.3).
    let activeServer: ServerConfig?
    /// User-chosen default. Sheet rows annotate it with "默认" so the
    /// override semantics stay legible.
    let defaultServerId: String?
    /// True iff `activeServer.id != defaultServerId`. Drives the small
    /// wifi sub-icon on the chip.
    let isAutoSwitched: Bool
    let allServers: [ServerConfig]
    let onSelect: (String) -> Void

    @State private var showingSwitcher: Bool =
        ProcessInfo.processInfo.environment["UC_OPEN_SWITCHER"] == "1"

    var body: some View {
        // `.fixedSize(horizontal: true, ...)` is load-bearing — without it
        // SwiftUI's navigation bar squeezes the leading toolbar item to
        // ~30pt and truncates the alias Text to zero width.
        HStack(spacing: 6) {
            if isAutoSwitched {
                Image(systemName: "wifi")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            }
            Text(verbatim: activeServer?.displayLabel ?? String(localized: "未配置"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.thinMaterial, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Capsule())
        .onTapGesture { showingSwitcher = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(isAutoSwitched ? "切换服务器 · 已根据 WiFi 自动切换" : "切换服务器"))
        .accessibilityValue(Text(activeServer?.displayLabel ?? String(localized: "未配置")))
        .sheet(isPresented: $showingSwitcher) {
            ServerSwitcherSheet(
                activeId: activeServer?.id,
                defaultId: defaultServerId,
                servers: allServers,
                onSelect: { id in
                    onSelect(id)
                    showingSwitcher = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct ServerSwitcherSheet: View {
    let activeId: String?
    let defaultId: String?
    let servers: [ServerConfig]
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(servers) { server in
                    Button {
                        onSelect(server.id)
                    } label: {
                        ServerSwitcherRow(
                            server: server,
                            isActive: server.id == activeId,
                            isDefault: server.id == defaultId
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        server.id == activeId
                            ? Color.green.opacity(0.08)
                            : Color.clear
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("切换服务器")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ServerSwitcherRow: View {
    let server: ServerConfig
    let isActive: Bool
    let isDefault: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isActive ? Color.green : Color.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(server.displayLabel)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    if isDefault && !isActive {
                        // Auto-switch swapped the active away from this
                        // user-default; surface the override so they
                        // don't think the chip picked the wrong row.
                        Text("默认")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(server.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !server.autoSwitchWifiNames.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "wifi")
                            .font(.caption2)
                        Text(server.autoSwitchWifiNames.joined(separator: ", "))
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Glass card container

private struct GlassCard<Content: View>: View {
    var highlighted: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        highlighted ? Color.indigo.opacity(0.7) : Color.white.opacity(0.12),
                        lineWidth: highlighted ? 2 : 0.5
                    )
            )
            .shadow(color: highlighted ? .indigo.opacity(0.18) : .black.opacity(0.06),
                    radius: highlighted ? 16 : 12, y: 4)
    }
}

// MARK: - Helpers

private extension Date {
    var relativeShort: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: .now)
    }
}

private extension String {
    var shortHash: String {
        guard count >= 12 else { return self }
        return String(prefix(6)) + "…" + String(suffix(4))
    }
}

private func formatSize(_ size: Int, kind: Clipboard.Kind) -> String {
    switch kind {
    case .text:
        return String(localized: "\(size) 字")
    case .image, .file, .group:
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

// MARK: - Preview

private func previewVM(serverLatest: Clipboard?, lastSyncedAt: Date?, deviceText: String?) -> AppViewModel {
    let vm = AppViewModel.preview(deviceText: deviceText)
    vm.serverLatest = serverLatest
    vm.lastSyncedAt = lastSyncedAt
    return vm
}

#Preview("Home — 不一致") {
    NavigationStack {
        HomeView(vm: previewVM(
            serverLatest: Mock.serverLatest,
            lastSyncedAt: Mock.serverLastSyncedAt,
            deviceText: Mock.deviceClipboard.text
        ))
    }
    .tint(.indigo)
}

#Preview("Home — 已同步") {
    // Server side and device side must be the same text-typed Clipboard;
    // image-typed Mock.serverLatest can no longer match a UIPasteboard string.
    let synced = "Hello, SyncClipboard!"
    NavigationStack {
        HomeView(vm: previewVM(
            serverLatest: Clipboard.fromText(synced),
            lastSyncedAt: Mock.serverLastSyncedAt,
            deviceText: synced
        ))
    }
    .tint(.indigo)
}

#Preview("Home — 服务器空") {
    NavigationStack {
        HomeView(vm: previewVM(
            serverLatest: nil,
            lastSyncedAt: nil,
            deviceText: nil
        ))
    }
    .tint(.indigo)
}
