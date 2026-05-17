import SwiftUI

/// Home tab — single focal card.
///
/// Cycle 9 removed the manual "推送" / "应用到本机" buttons; the engine
/// converges both directions on a 1Hz foreground tick, so the server
/// snapshot and the device pasteboard are nearly always the same string.
/// Cycle 10 collapses the previous Server-card + connector + Device-card
/// stack into one card that shows "what's on the clipboard right now",
/// with engine state surfaced as a thin status row and exceptional
/// outcomes (auth fail, save error, save success, …) shown as a slim
/// bar pinned to the card's bottom edge.
struct HomeView: View {
    @Bindable var vm: AppViewModel

    /// Injected by `ContentView` so the error-detail sheet's "去设置" CTA
    /// can flip the TabView selection without HomeView knowing about it.
    var onGoToSettings: () -> Void = {}

    @State private var showingErrorSheet: Bool =
        ProcessInfo.processInfo.environment["UC_OPEN_ISSUE_SHEET"] == "1"

    private var engineState: SyncEngine.State { vm.engine.state }
    private var isExplicitlyRefreshing: Bool { vm.engine.isExplicitlyRefreshing }

    /// What to render in the card body. The engine keeps both sides in sync
    /// so these are almost always the same content; we prefer the server
    /// copy because it carries the canonical `hash` / `dataName` metadata
    /// the UI shows in the size row and the save-to-Documents action.
    private var displayedEntry: Clipboard? {
        vm.serverLatest ?? vm.deviceClipboard
    }

    /// Last sync timestamp shown in the card's metadata row. Falls back to
    /// the VM's snapshot timestamp for cold-launch or before the engine's
    /// first tick lands.
    private var lastSyncedAt: Date? {
        vm.engine.lastSyncedAt ?? vm.lastSyncedAt
    }

    var body: some View {
        // GeometryReader + minHeight lets the card vertically center when
        // content is short (empty state, single-line text) while still
        // scrolling cleanly when text overflows the viewport. Without the
        // minHeight pin the ScrollView shrinks to fit its content and the
        // card sticks to the top.
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ClipboardCard(
                        entry: displayedEntry,
                        lastSyncedAt: lastSyncedAt,
                        status: cardStatus,
                        isSaving: vm.isSaving,
                        lastSavedFileURL: vm.lastSavedFileURL,
                        saveError: vm.saveError,
                        bottomBar: bottomBar,
                        onSave: { Task { await vm.saveServerAttachment() } }
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: geo.size.height)
            }
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
            if let issue = currentIssue {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingErrorSheet = true
                    } label: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(issue.tint)
                    }
                    .accessibilityLabel(Text(issue.title))
                }
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
        .sheet(isPresented: $showingErrorSheet) {
            if let issue = currentIssue {
                IssueDetailSheet(
                    issue: issue,
                    onPrimaryAction: {
                        showingErrorSheet = false
                        switch issue.primaryAction {
                        case .goToSettings: onGoToSettings()
                        case .retry:        vm.engine.forceTickNow()
                        case .dismiss:      break
                        }
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    /// Active error worth surfacing as the toolbar's red bang. `nil` keeps
    /// the chrome clean. Priority: save-failure (user-initiated, sticky
    /// until next attempt) > engine state (auth fail > offline). Note that
    /// `.hasNewUnwritten` is *not* an issue — it's an opt-in waiting state
    /// the user signed up for by turning auto-apply off.
    private var currentIssue: HomeIssue? {
        if let err = vm.saveError {
            return .saveFailed(message: errorMessage(err), detail: err.underlying)
        }
        switch engineState {
        case .authFailed:
            return .authFailed(detail: vm.engine.lastError?.underlying)
        case .offlineRetrying:
            if let err = vm.engine.lastError {
                return .offline(message: errorMessage(err), detail: err.underlying)
            }
            return .offline(message: String(localized: "离线 · 重试中"), detail: nil)
        case .idle, .succeeded, .hasNewUnwritten:
            return nil
        }
    }

    /// Maps engine state to the small status pill drawn in the card's
    /// metadata row. `nil` keeps the row clean when there's nothing
    /// useful to say (idle with no content yet — the empty state takes
    /// over).
    private var cardStatus: ClipboardCard.Status? {
        if isExplicitlyRefreshing { return .syncing }
        switch engineState {
        case .idle:
            return displayedEntry == nil ? nil : .syncing
        case .succeeded:
            return .synced
        case .hasNewUnwritten:
            // The bottom bar carries the actionable copy; the pill just
            // mirrors the same idea so the row doesn't read "已同步" while
            // the bar says otherwise.
            return .pending
        case .offlineRetrying:
            return .offline
        case .authFailed:
            return .authFailed
        }
    }

    /// Bottom-bar payload. Only carries *informational* states now —
    /// "已保存到 …" (transient positive feedback) and "服务器有新内容"
    /// (an opt-in waiting state). Hard errors moved to the toolbar's red
    /// bang + detail sheet, so the card itself never wears warning paint.
    private var bottomBar: ClipboardCard.BottomBar? {
        if let url = vm.lastSavedFileURL {
            return .saved(url: url)
        }
        if engineState == .hasNewUnwritten {
            return .pendingApply
        }
        return nil
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
}

// MARK: - Single clipboard card

private struct ClipboardCard: View {
    enum Status {
        case syncing, synced, pending, offline, authFailed
    }

    enum BottomBar {
        case saved(url: URL)
        case pendingApply
    }

    let entry: Clipboard?
    let lastSyncedAt: Date?
    let status: Status?
    let isSaving: Bool
    let lastSavedFileURL: URL?
    let saveError: SyncError?
    let bottomBar: BottomBar?
    let onSave: () -> Void

    private var canSave: Bool {
        guard let entry else { return false }
        return entry.hasData && (entry.type == .image || entry.type == .file)
    }

    var body: some View {
        if let entry {
            VStack(spacing: 0) {
                contentBlock(entry: entry)
                if let bottomBar {
                    Divider().opacity(0.25)
                    bottomBarView(bottomBar)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        } else {
            // No card chrome on the empty state — ContentUnavailableView
            // is the iOS 17+ native pattern (large symbol, headline,
            // secondary copy), centered without a container.
            emptyState
        }
    }

    // MARK: Content

    @ViewBuilder
    private func contentBlock(entry: Clipboard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(entry: entry)
            preview(entry: entry)
            metadataRow(entry: entry)
            if canSave {
                saveButton
            }
        }
        .padding(20)
    }

    private func header(entry: Clipboard) -> some View {
        HStack(spacing: 10) {
            ClipboardKindBadge(kind: entry.type, size: .small)
            Spacer()
            if let status, status != .synced {
                statusPill(for: status)
            }
        }
    }

    @ViewBuilder
    private func preview(entry: Clipboard) -> some View {
        switch entry.type {
        case .text:
            Text(entry.text)
                .font(.title3)
                .foregroundStyle(.primary)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .image, .file, .group:
            HStack(spacing: 14) {
                ClipboardKindBadge(kind: entry.type, size: .large, showsLabel: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .font(.headline)
                        .lineLimit(1)
                    if let dataName = entry.dataName, dataName != entry.text {
                        Text(dataName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func metadataRow(entry: Clipboard) -> some View {
        HStack(spacing: 8) {
            if let size = entry.size {
                Text(formatSize(size, kind: entry.type))
            }
            if entry.size != nil, lastSyncedAt != nil { dot }
            if let lastSyncedAt {
                Text(lastSyncedAt.relativeShort)
            }
            if let status, status == .synced {
                if entry.size != nil || lastSyncedAt != nil { dot }
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("已同步")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var dot: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private func statusPill(for status: Status) -> some View {
        HStack(spacing: 5) {
            statusIcon(for: status)
                .font(.caption2.weight(.semibold))
            Text(statusLabel(for: status))
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(statusTint(for: status))
        .padding(.vertical, 4)
        .padding(.horizontal, 9)
        .background(statusTint(for: status).opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func statusIcon(for status: Status) -> some View {
        switch status {
        case .syncing:    ProgressView().controlSize(.mini)
        case .synced:     Image(systemName: "checkmark")
        case .pending:    Image(systemName: "tray.and.arrow.down")
        case .offline:    Image(systemName: "wifi.exclamationmark")
        case .authFailed: Image(systemName: "lock.fill")
        }
    }

    private func statusLabel(for status: Status) -> LocalizedStringKey {
        switch status {
        case .syncing:    "同步中"
        case .synced:     "已同步"
        case .pending:    "待应用"
        case .offline:    "离线"
        case .authFailed: "认证失败"
        }
    }

    private func statusTint(for status: Status) -> Color {
        switch status {
        case .syncing:    .secondary
        case .synced:     .green
        case .pending:    .indigo
        case .offline:    .orange
        case .authFailed: .red
        }
    }

    private var saveButton: some View {
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

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("还没有同步过剪贴板")
            } icon: {
                Image(systemName: "doc.on.clipboard")
            }
        } description: {
            Text("复制任何内容会自动同步")
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private func bottomBarView(_ bar: BottomBar) -> some View {
        switch bar {
        case .saved(let url):
            BottomBarRow(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: String(localized: "已保存到 \(displayPath(for: url))")
            )
        case .pendingApply:
            BottomBarRow(
                icon: "tray.and.arrow.down.fill",
                tint: .indigo,
                title: String(localized: "服务器有新内容，未自动写入本机")
            )
        }
    }

    private func displayPath(for url: URL) -> String {
        url.pathComponents.suffix(2).joined(separator: "/")
    }
}

// MARK: - Bottom bar row

private struct BottomBarRow: View {
    let icon: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(tint.opacity(0.08))
        .clipShape(
            UnevenRoundedRectangle(
                cornerRadii: .init(bottomLeading: 22, bottomTrailing: 22),
                style: .continuous
            )
        )
    }
}

// MARK: - Toolbar issue model + detail sheet

/// An error that's worth a red bang in the toolbar. Carries enough copy
/// to render both the icon's accessibility label and the detail sheet
/// without HomeView needing to re-derive strings.
private enum HomeIssue: Equatable {
    case authFailed(detail: String?)
    case offline(message: String, detail: String?)
    case saveFailed(message: String, detail: String?)

    enum PrimaryAction {
        case goToSettings
        case retry
        case dismiss
    }

    var tint: Color {
        switch self {
        case .authFailed, .saveFailed: .red
        case .offline:                 .orange
        }
    }

    var symbolName: String {
        switch self {
        case .authFailed: "lock.fill"
        case .offline:    "wifi.exclamationmark"
        case .saveFailed: "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch self {
        case .authFailed: String(localized: "认证失败")
        case .offline:    String(localized: "无法连接服务器")
        case .saveFailed: String(localized: "保存失败")
        }
    }

    var message: String {
        switch self {
        case .authFailed:
            String(localized: "请检查用户名和密码是否正确。修改后会自动重新同步。")
        case .offline(let message, _):
            message
        case .saveFailed(let message, _):
            message
        }
    }

    var detail: String? {
        switch self {
        case .authFailed(let d), .offline(_, let d), .saveFailed(_, let d):
            d
        }
    }

    var primaryAction: PrimaryAction {
        switch self {
        case .authFailed: .goToSettings
        case .offline:    .retry
        case .saveFailed: .dismiss
        }
    }

    var primaryActionLabel: LocalizedStringKey {
        switch self {
        case .authFailed: "去设置"
        case .offline:    "立即重试"
        case .saveFailed: "好"
        }
    }
}

private struct IssueDetailSheet: View {
    let issue: HomeIssue
    let onPrimaryAction: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: issue.symbolName)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(issue.tint)
                .padding(.top, 24)

            VStack(spacing: 8) {
                Text(issue.title)
                    .font(.title3.weight(.semibold))
                Text(issue.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if let detail = issue.detail, !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 80)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 20)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button(action: onPrimaryAction) {
                    Text(issue.primaryActionLabel)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(issue.tint)

                Button("关闭") { dismiss() }
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
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

// MARK: - Helpers

private extension Date {
    /// "刚刚" inside ±5s, otherwise the system relative formatter. Without
    /// the floor `RelativeDateTimeFormatter` happily returns "0 秒后" for
    /// `lastSyncedAt == .now`, which reads as a bug.
    var relativeShort: String {
        let dt = timeIntervalSinceNow
        if abs(dt) < 5 { return String(localized: "刚刚") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: .now)
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

#Preview("Home — 已同步") {
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

#Preview("Home — 图片附件") {
    NavigationStack {
        HomeView(vm: previewVM(
            serverLatest: Mock.serverLatest,
            lastSyncedAt: Mock.serverLastSyncedAt,
            deviceText: nil
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
