import SwiftUI
import UIKit

/// Home tab — two-column grid of clipboard history cards (Paste-app style).
///
/// Replaces the earlier List-based layout with a `LazyVGrid` that shows
/// `ClipboardCard` cells. Supports search, multi-select, long-press preview
/// overlay, and a bottom toolbar for search / server picker / sync.
struct HomeView: View {
    @Bindable var vm: AppViewModel

    /// Injected by `ContentView` so the error-detail sheet's "去设置" CTA
    /// can flip the TabView selection without HomeView knowing about it.
    var onGoToSettings: () -> Void = {}

    // MARK: - State

    @State private var showingErrorSheet: Bool =
        ProcessInfo.processInfo.environment["UC_OPEN_ISSUE_SHEET"] == "1"
    @State private var pinnedItemId: UUID?
    @State private var loadingItemIds: Set<UUID> = []
    @State private var thumbnailCache: [UUID: UIImage] = [:]
    @State private var urlMetadataCache: [UUID: URLCardMetadata] = [:]
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var filterTypes: Set<ClipboardDisplayKind> = []
    @State private var filterDate: SearchDateFilter = .all
    @State private var showingFilterSheet: Bool = false
    @State private var isSelectMode: Bool = false
    @State private var selectedIds: Set<UUID> = []
    @State private var showingServerPicker: Bool =
        ProcessInfo.processInfo.environment["UC_OPEN_SWITCHER"] == "1"

    // MARK: - Derived

    private var engineState: SyncEngine.State { vm.engine.state }
    private var isExplicitlyRefreshing: Bool { vm.engine.isExplicitlyRefreshing }

    private var showPasteHint: Bool {
        vm.appSettings.autoPushDeviceChanges && !vm.appSettings.pastePermissionHintDismissed
    }

    /// History rendered in the grid, sorted newest-first. When a card is
    /// pinned (just tapped-to-copy), that item is promoted to position 0
    /// regardless of its timestamp so the user sees the visual feedback.
    private var sortedHistory: [ClipboardHistoryItem] {
        var items = vm.history.sorted { $0.timestamp > $1.timestamp }
        if let pinId = pinnedItemId,
           let idx = items.firstIndex(where: { $0.id == pinId }), idx > 0 {
            let pinned = items.remove(at: idx)
            items.insert(pinned, at: 0)
        }
        return items
    }

    private var latestId: UUID? {
        vm.history.sorted { $0.timestamp > $1.timestamp }.first?.id
    }

    private var hasActiveFilters: Bool {
        !filterTypes.isEmpty || filterDate != .all
    }

    /// Items displayed in the grid, filtered by search text + type + date.
    private var displayedHistory: [ClipboardHistoryItem] {
        var items = sortedHistory

        if isSearching {
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                items = items.filter {
                    $0.entry.text.lowercased().contains(query)
                    || ($0.entry.dataName?.lowercased().contains(query) ?? false)
                }
            }
            if !filterTypes.isEmpty {
                items = items.filter { filterTypes.contains($0.entry.displayKind) }
            }
            items = filterDate.apply(to: items)
        }

        return items
    }

    private let twoFlexibleColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    // MARK: - Body

    var body: some View {
        gridOrEmpty
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    customTopBar
                    if showPasteHint {
                        PastePermissionBanner(
                            onOpenSettings: { openAppSettings() },
                            onDismiss: { vm.appSettings.pastePermissionHintDismissed = true }
                        )
                    }
                }
            }
            .animation(.snappy, value: showPasteHint)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
            }
            .refreshable {
                await vm.engine.explicitRefresh()
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingServerPicker) {
                ServerSwitcherSheet(
                    vm: vm,
                    onSelect: { id in
                        vm.setActiveServer(id)
                        showingServerPicker = false
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingErrorSheet) {
                if let issue = currentIssue {
                    IssueDetailSheet(
                        issue: issue,
                        onPrimaryAction: {
                            showingErrorSheet = false
                            switch issue.primaryAction {
                            case .goToSettings:    onGoToSettings()
                            case .retry:           vm.engine.forceTickNow()
                            case .acknowledgeLoop: vm.engine.acknowledgeLoopDetection()
                            case .dismiss:         break
                            }
                        }
                    )
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                }
            }
    }

    // MARK: - Top Bar

    private var customTopBar: some View {
        HStack(spacing: 12) {
            // Left: server status (read-only)
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text(verbatim: vm.activeServer?.displayLabel ?? String(localized: "未配置"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Error badge (if any)
            if let issue = currentIssue {
                Button {
                    showingErrorSheet = true
                } label: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(issue.tint)
                        .frame(width: 52, height: 52)
                }
                .accessibilityLabel(Text(issue.title))
            }

            // "选择" / "完成" capsule
            Button {
                if isSelectMode {
                    exitSelectMode()
                } else {
                    isSelectMode = true
                    selectedIds = []
                }
            } label: {
                Text(isSelectMode ? "完成" : "选择")
                    .font(.subheadline.weight(.medium))
                    .frame(height: 52)
                    .padding(.horizontal, 20)
                    .liquidGlassCapsule()
            }

            // "⋯" menu circle
            Menu {
                Button {
                    onGoToSettings()
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                Button {
                } label: {
                    Label("帮助", systemImage: "questionmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .liquidGlassCircle()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Grid or Empty

    @ViewBuilder
    private var gridOrEmpty: some View {
        if sortedHistory.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("还没有同步过剪贴板")
                } icon: {
                    Image(systemName: "doc.on.clipboard")
                }
            } description: {
                Text("服务器的新内容会自动出现在这里；本机内容点下方按钮推送")
            } actions: {
                PasteButton(supportedContentTypes: PastedItemExtractor.supportedContentTypes) { providers in
                    Task { await vm.pushPastedProviders(providers) }
                }
                .tint(.accentColor)
                .accessibilityLabel(Text("推送本机剪贴板到服务器"))
            }
        } else {
            ScrollView(.vertical) {
                LazyVGrid(columns: twoFlexibleColumns, spacing: 12) {
                    ForEach(displayedHistory) { item in
                        cardCell(for: item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .animation(.snappy, value: pinnedItemId)
            .task { preloadThumbnails() }
            // Watch the array itself, not just its count: a push completion
            // flips the head row's direction IN PLACE (same-hash dedup), and
            // that's exactly the moment a previously-failed thumbnail load
            // (it raced the PUT) becomes satisfiable from the local cache.
            .onChange(of: vm.history) { _, _ in preloadThumbnails() }
        }
    }

    // MARK: - Search Bottom Bar

    private var searchBottomBar: some View {
        VStack(spacing: 8) {
            // Filter tags row (when filters are active)
            if hasActiveFilters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(filterTypes), id: \.self) { kind in
                            filterTag(label: kind.localizedLabelString) {
                                filterTypes.remove(kind)
                            }
                        }
                        if filterDate != .all {
                            filterTag(label: filterDate.label) {
                                filterDate = .all
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // Search input row
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    TextField(String(localized: "搜索剪贴板"), text: $searchText)
                        .font(.subheadline)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 52)
                .padding(.horizontal, 12)
                .liquidGlassCapsule()

                Button {
                    showingFilterSheet = true
                } label: {
                    Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.title2)
                        .foregroundStyle(hasActiveFilters ? Color.accentColor : .primary)
                        .frame(width: 52, height: 52)
                        .liquidGlassCircle()
                }

                Button {
                    withAnimation(.snappy) {
                        isSearching = false
                        searchText = ""
                        filterTypes = []
                        filterDate = .all
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                        .liquidGlassCircle()
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showingFilterSheet) {
            SearchFilterSheet(
                selectedTypes: $filterTypes,
                selectedDate: $filterDate
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func filterTag(label: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .foregroundStyle(Color.accentColor)
    }

    // MARK: - Card Cell

    @ViewBuilder
    private func cardCell(for item: ClipboardHistoryItem) -> some View {
        let isSelected = isSelectMode && selectedIds.contains(item.id)

        ClipboardCard(
            item: item,
            isLatest: item.id == latestId,
            thumbnailImage: thumbnailCache[item.id],
            urlMetadata: urlMetadataCache[item.id],
            isLoading: loadingItemIds.contains(item.id)
        )
        .overlay {
            if isSelectMode {
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 2)
                    }
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 28))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            if isSelectMode {
                toggleSelection(item.id)
            } else {
                handleTapToCopy(item)
            }
        }
        .contextMenu {
            contextMenuItems(for: item)
        } preview: {
            CardPreviewView(item: item, vm: vm)
        }
        .task {
            await loadThumbnailIfNeeded(for: item)
            await loadURLMetadataIfNeeded(for: item)
        }
        .animation(.snappy, value: isSelectMode)
        .animation(.snappy, value: isSelected)
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        if isSelectMode {
            selectModeBottomBar
        } else if isSearching {
            searchBottomBar
        } else {
            HomeBottomToolbar(
                serverLabel: vm.activeServer?.displayLabel ?? String(localized: "未配置"),
                isAutoSwitched: vm.activeServer?.id != vm.servers.activeConfig?.id,
                isSyncing: isExplicitlyRefreshing,
                onSearch: {
                    withAnimation(.snappy) {
                        isSearching = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isSearchFocused = true
                    }
                },
                onServerPicker: {
                    showingServerPicker = true
                },
                onSync: {
                    handleSync()
                }
            )
        }
    }

    private var selectModeBottomBar: some View {
        HStack(spacing: 24) {
            Spacer()

            Button {
                batchCopy()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .liquidGlassCircle()
            }
            .disabled(selectedIds.isEmpty)

            Button {
                // Pin — placeholder for future pinboard feature
            } label: {
                Image(systemName: "pin")
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .liquidGlassCircle()
            }
            .disabled(selectedIds.isEmpty)

            Button {
                batchShare()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .liquidGlassCircle()
            }
            .disabled(selectedIds.isEmpty)

            Button {
                batchDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .frame(width: 52, height: 52)
                    .liquidGlassCircle()
            }
            .disabled(selectedIds.isEmpty)

            Spacer()
        }
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func handleTapToCopy(_ item: ClipboardHistoryItem) {
        switch item.entry.displayKind {
        case .text, .url:
            vm.reapplyHistoryItem(item)
            withAnimation(.snappy) {
                pinnedItemId = item.id
            }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            schedulePinReset()
            Task { await vm.pushHistoryEntryToServer(item) }

        case .image:
            guard item.entry.hasData else { return }
            loadingItemIds.insert(item.id)
            Task {
                await vm.applyAttachment(for: item)
                loadingItemIds.remove(item.id)
                guard vm.applyError == nil else { return }
                vm.reapplyHistoryItem(item)
                withAnimation(.snappy) {
                    pinnedItemId = item.id
                }
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                schedulePinReset()
                await vm.pushHistoryEntryToServer(item)
            }

        case .file, .group:
            // reapplyHistoryItem copies the filename as text through the
            // observer (adopted write) — no raw UIPasteboard write here.
            vm.reapplyHistoryItem(item)
            withAnimation(.snappy) {
                pinnedItemId = item.id
            }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            schedulePinReset()
            Task { await vm.pushHistoryEntryToServer(item) }
        }
    }

    private func handleCopyFromOverlay(_ item: ClipboardHistoryItem) {
        switch item.entry.displayKind {
        case .text, .url:
            vm.reapplyHistoryItem(item)
            Task { await vm.pushHistoryEntryToServer(item) }
        case .image:
            if item.entry.hasData {
                Task {
                    await vm.applyAttachment(for: item)
                    guard vm.applyError == nil else { return }
                    vm.reapplyHistoryItem(item)
                    await vm.pushHistoryEntryToServer(item)
                }
            }
        case .file, .group:
            vm.reapplyHistoryItem(item)
            Task { await vm.pushHistoryEntryToServer(item) }
        }
    }

    private func schedulePinReset() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) {
                pinnedItemId = nil
            }
        }
    }

    private func handleSync() {
        vm.engine.forceTickNow()
    }

    @ViewBuilder
    private func contextMenuItems(for item: ClipboardHistoryItem) -> some View {
        Button {
            handleCopyFromOverlay(item)
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }

        switch item.entry.displayKind {
        case .text:
            Button {
                UIPasteboard.general.string = item.entry.text
            } label: {
                Label("复制为纯文本", systemImage: "doc.plaintext")
            }
        case .url:
            if let url = item.entry.parsedURL {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("在浏览器中打开", systemImage: "safari")
                }
            }
            Button {
                UIPasteboard.general.string = item.entry.text
            } label: {
                Label("复制为纯文本", systemImage: "doc.plaintext")
            }
        case .image:
            Button {
                Task { await vm.saveAttachment(for: item) }
            } label: {
                Label("保存图片", systemImage: "square.and.arrow.down")
            }
        case .file, .group:
            Button {
                Task { await vm.saveAttachment(for: item) }
            } label: {
                Label("保存到 Documents", systemImage: "folder")
            }
        }

        Button {
            shareItem(item)
        } label: {
            Label("分享", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button {
            isSelectMode = true
            selectedIds = [item.id]
        } label: {
            Label("选择", systemImage: "checkmark.circle")
        }

        Button(role: .destructive) {
            vm.removeHistoryItem(id: item.id)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func preloadThumbnails() {
        for item in vm.history {
            guard item.entry.type == .image,
                  item.entry.hasData,
                  thumbnailCache[item.id] == nil,
                  let hash = item.entry.hash, !hash.isEmpty
            else { continue }
            if let cached = ImageThumbnailCache.shared.cached(forHash: hash) {
                thumbnailCache[item.id] = cached
                continue
            }
            Task { await loadThumbnailIfNeeded(for: item) }
        }
    }

    private func loadThumbnailIfNeeded(for item: ClipboardHistoryItem) async {
        guard item.entry.type == .image,
              item.entry.hasData,
              thumbnailCache[item.id] == nil,
              let hash = item.entry.hash, !hash.isEmpty
        else { return }

        let thumb = await ImageThumbnailCache.shared.fetch(forHash: hash) {
            try await vm.fetchPreviewBytes(for: item)
        }
        if let thumb {
            thumbnailCache[item.id] = thumb
        }
    }

    private func loadURLMetadataIfNeeded(for item: ClipboardHistoryItem) async {
        guard item.entry.displayKind == .url,
              urlMetadataCache[item.id] == nil,
              let url = item.entry.parsedURL
        else { return }
        let metadata = await URLMetadataCache.shared.fetch(for: url)
        urlMetadataCache[item.id] = metadata
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func selectAll() {
        if selectedIds.count == displayedHistory.count {
            selectedIds = []
        } else {
            selectedIds = Set(displayedHistory.map(\.id))
        }
    }

    private func batchCopy() {
        let items = displayedHistory.filter { selectedIds.contains($0.id) }
        let texts = items.map(\.entry.text).joined(separator: "\n")
        UIPasteboard.general.string = texts
        exitSelectMode()
    }

    private func batchShare() {
        let items = displayedHistory.filter { selectedIds.contains($0.id) }
        let texts = items.map(\.entry.text)
        guard !texts.isEmpty else { return }
        let content: [Any] = [texts.joined(separator: "\n")]
        let activityVC = UIActivityViewController(activityItems: content, applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = windowScene.windows.first?.rootViewController {
            var topVC = root
            while let presented = topVC.presentedViewController { topVC = presented }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            activityVC.popoverPresentationController?.sourceRect = CGRect(
                x: topVC.view.bounds.midX, y: topVC.view.bounds.maxY - 100, width: 0, height: 0
            )
            topVC.present(activityVC, animated: true)
        }
        exitSelectMode()
    }

    private func batchDelete() {
        for id in selectedIds {
            vm.removeHistoryItem(id: id)
        }
        exitSelectMode()
    }

    private func exitSelectMode() {
        isSelectMode = false
        selectedIds = []
    }

    private func shareItem(_ item: ClipboardHistoryItem) {
        var shareContent: [Any] = []
        switch item.entry.displayKind {
        case .text:
            shareContent = [item.entry.text]
        case .url:
            if let url = item.entry.parsedURL {
                shareContent = [url]
            } else {
                shareContent = [item.entry.text]
            }
        case .image:
            if let cached = thumbnailCache[item.id] {
                shareContent = [cached]
            } else {
                shareContent = [item.entry.text]
            }
        case .file, .group:
            shareContent = [item.entry.dataName ?? item.entry.text]
        }
        guard !shareContent.isEmpty else { return }
        let activityVC = UIActivityViewController(activityItems: shareContent, applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = windowScene.windows.first?.rootViewController {
            // Find the topmost presented controller
            var topVC = root
            while let presented = topVC.presentedViewController { topVC = presented }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            activityVC.popoverPresentationController?.sourceRect = CGRect(
                x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0
            )
            topVC.present(activityVC, animated: true)
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Error handling

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
            return .offline(message: String(localized: "离线 \u{00B7} 重试中"), detail: nil)
        case .loopDetected:
            return .loopDetected(detail: vm.engine.lastError?.underlying)
        case .idle, .succeeded, .hasNewUnwritten:
            return nil
        }
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

// MARK: - Paste Permission Banner

/// Home hint nudging the user to set "从其他 App 粘贴" to "允许" once they've turned
/// on fully-automatic push -- otherwise iOS prompts "允许粘贴" on every engine
/// read. Dismissible; the choice persists via `pastePermissionHintDismissed`.
private struct PastePermissionBanner: View {
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("已开启自动推送")
                    .font(.footnote.weight(.semibold))
                Text("把「从其他 App 粘贴」设为「允许」可避免反复弹窗,让同步静默进行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开设置", action: onOpenSettings)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
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
    case loopDetected(detail: String?)

    enum PrimaryAction {
        case goToSettings
        case retry
        case acknowledgeLoop
        case dismiss
    }

    var tint: Color {
        switch self {
        case .authFailed, .saveFailed:    .red
        case .offline, .loopDetected:     .orange
        }
    }

    var symbolName: String {
        switch self {
        case .authFailed:    "lock.fill"
        case .offline:       "wifi.exclamationmark"
        case .saveFailed:    "exclamationmark.triangle.fill"
        case .loopDetected:  "arrow.triangle.2.circlepath"
        }
    }

    var title: String {
        switch self {
        case .authFailed:    String(localized: "认证失败")
        case .offline:       String(localized: "无法连接服务器")
        case .saveFailed:    String(localized: "保存失败")
        case .loopDetected:  String(localized: "自动同步已暂停")
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
        case .loopDetected:
            String(localized: "检测到同一份剪贴板内容在本机和服务器之间反复同步。点「重新启用」继续，或检查另一端的客户端是否也在自动同步同一份内容。")
        }
    }

    var detail: String? {
        switch self {
        case .authFailed(let d), .offline(_, let d), .saveFailed(_, let d), .loopDetected(let d):
            d
        }
    }

    var primaryAction: PrimaryAction {
        switch self {
        case .authFailed:    .goToSettings
        case .offline:       .retry
        case .saveFailed:    .dismiss
        case .loopDetected:  .acknowledgeLoop
        }
    }

    var primaryActionLabel: LocalizedStringKey {
        switch self {
        case .authFailed:    "去设置"
        case .offline:       "立即重试"
        case .saveFailed:    "好"
        case .loopDetected:  "重新启用"
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

            VStack(spacing: 12) {
                Button(action: onPrimaryAction) {
                    Text(issue.primaryActionLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(height: 48)
                        .padding(.horizontal, 32)
                        .background(issue.tint, in: Capsule(style: .continuous))
                }

                Button {
                    dismiss()
                } label: {
                    Text("关闭")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Server Switcher Sheet

private struct ServerSwitcherSheet: View {
    @Bindable var vm: AppViewModel
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var addDraft: ServerDraft?

    private var activeId: String? { vm.activeServer?.id }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(vm.servers.configs) { server in
                        Button {
                            onSelect(server.id)
                        } label: {
                            ServerSwitcherRow(
                                server: server,
                                isActive: server.id == activeId
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
            }
            .listStyle(.insetGrouped)
            .navigationTitle("服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let existingNames = Set(vm.servers.configs.compactMap(\.name))
                        addDraft = ServerDraft(existingNames: existingNames)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $addDraft) { draft in
                AddServerSheet(
                    draft: draft,
                    trustInsecureCert: Binding(
                        get: { vm.appSettings.trustInsecureCert },
                        set: { vm.appSettings.trustInsecureCert = $0 }
                    ),
                    ssidProvider: vm.ssidProvider,
                    onCancel: { addDraft = nil },
                    onSave: { saved in
                        commitDraft(saved)
                        addDraft = nil
                    }
                )
            }
        }
    }

    private func commitDraft(_ draft: ServerDraft) {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = ServerConfig(
            id: UUID().uuidString.lowercased(),
            name: trimmedName.isEmpty ? nil : trimmedName,
            url: draft.url.trimmingCharacters(in: .whitespacesAndNewlines),
            username: draft.username,
            password: draft.password,
            autoSwitchWifiNames: draft.ssids,
            autoSwitchStrategy: draft.strategy
        )
        var list = vm.servers
        list.configs.append(server)
        if list.activeConfigId == nil || list.configs.count == 1 {
            list.activeConfigId = server.id
        }
        vm.servers = list
    }
}

private struct ServerSwitcherRow: View {
    let server: ServerConfig
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isActive ? Color.green : Color.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(server.displayLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(server.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                AutoSwitchConditionBadge(
                    strategy: server.autoSwitchStrategy,
                    wifiNames: server.autoSwitchWifiNames
                )
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Search Filter

private enum SearchDateFilter: Hashable {
    case all, today, yesterday, pastWeek

    var label: String {
        switch self {
        case .all:       String(localized: "全部")
        case .today:     String(localized: "今天")
        case .yesterday: String(localized: "昨天")
        case .pastWeek:  String(localized: "7 天内")
        }
    }

    func apply(to items: [ClipboardHistoryItem]) -> [ClipboardHistoryItem] {
        let cal = Calendar.current
        switch self {
        case .all:       return items
        case .today:     return items.filter { cal.isDateInToday($0.timestamp) }
        case .yesterday: return items.filter { cal.isDateInYesterday($0.timestamp) }
        case .pastWeek:
            guard let sevenAgo = cal.date(byAdding: .day, value: -7, to: .now) else { return items }
            return items.filter { $0.timestamp >= sevenAgo }
        }
    }

    static let allOptions: [SearchDateFilter] = [.all, .today, .yesterday, .pastWeek]
}

private struct SearchFilterSheet: View {
    @Binding var selectedTypes: Set<ClipboardDisplayKind>
    @Binding var selectedDate: SearchDateFilter

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("类型") {
                    ForEach(ClipboardDisplayKind.allCases, id: \.self) { kind in
                        Button {
                            if selectedTypes.contains(kind) {
                                selectedTypes.remove(kind)
                            } else {
                                selectedTypes.insert(kind)
                            }
                        } label: {
                            HStack {
                                Image(systemName: kind.symbolName)
                                    .foregroundStyle(kind.tint)
                                    .frame(width: 24)
                                Text(kind.localizedLabelString)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedTypes.contains(kind) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }

                Section("日期") {
                    ForEach(SearchDateFilter.allOptions, id: \.self) { option in
                        Button {
                            selectedDate = option
                        } label: {
                            HStack {
                                Text(option.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedDate == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("筛选条件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }
}

// MARK: - Helpers

private extension Date {
    /// "刚刚" inside +/-5s, otherwise the system relative formatter.
    var relativeShort: String {
        let dt = timeIntervalSinceNow
        if abs(dt) < 5 { return String(localized: "刚刚") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: .now)
    }
}

private func formatSize(_ size: Int, kind: ClipboardDisplayKind) -> String {
    switch kind {
    case .text, .url:
        return String(localized: "\(size) 字")
    case .image, .file, .group:
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

// MARK: - Context Menu Preview

/// Custom preview shown by the native `.contextMenu(preview:)`. The system
/// animates the zoom-from-source transition; this view just supplies content.
/// Async-loaded images/long-text are fetched lazily in `.task`.
private struct CardPreviewView: View {
    let item: ClipboardHistoryItem
    @Bindable var vm: AppViewModel

    @State private var loadedImage: UIImage?
    @State private var loadedText: String?
    @State private var loadedOGImage: UIImage?
    @State private var loadedURLTitle: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            switch item.entry.displayKind {
            case .text:
                ScrollView {
                    Text(loadedText ?? item.entry.text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }

            case .url:
                VStack(alignment: .leading, spacing: 12) {
                    if let ogImage = loadedOGImage {
                        Image(uiImage: ogImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                    if let title = loadedURLTitle, !title.isEmpty {
                        Text(title)
                            .font(.headline)
                    }
                    Text(item.entry.text)
                        .font(.callout)
                        .foregroundStyle(.blue)
                }
                .padding(16)

            case .image:
                if let image = loadedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

            case .file, .group:
                VStack(spacing: 12) {
                    Image(systemName: item.entry.displayKind.symbolName)
                        .font(.system(size: 48))
                        .foregroundStyle(item.entry.displayKind.tint)
                    Text(item.entry.dataName ?? item.entry.text)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let size = item.entry.size {
                        let f = ByteCountFormatter()
                        Text(f.string(fromByteCount: Int64(size)))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
        }
        .frame(minHeight: 300)
        .frame(width: UIScreen.main.bounds.width - 32)
        .task {
            await loadContent()
        }
    }

    private func loadContent() async {
        switch item.entry.displayKind {
        case .text where item.entry.hasData:
            isLoading = true
            if let bytes = try? await vm.fetchPreviewBytes(for: item) {
                loadedText = String(decoding: bytes, as: UTF8.self)
            }
            isLoading = false

        case .url:
            isLoading = true
            if let url = item.entry.parsedURL {
                let meta = await URLMetadataCache.shared.fetch(for: url)
                loadedOGImage = meta.ogImage
                loadedURLTitle = meta.title
            }
            isLoading = false

        case .image where item.entry.hasData:
            isLoading = true
            if let bytes = try? await vm.fetchPreviewBytes(for: item) {
                loadedImage = UIImage(data: bytes)
            }
            isLoading = false

        default:
            break
        }
    }
}

// MARK: - Preview

private func previewVM(history: [ClipboardHistoryItem]? = nil) -> AppViewModel {
    let vm = AppViewModel.preview()
    if let history { vm.history = history }
    return vm
}

#Preview("Home — 网格") {
    NavigationStack {
        HomeView(vm: previewVM())
    }
}

#Preview("Home — 空状态") {
    NavigationStack {
        HomeView(vm: previewVM(history: []))
    }
}
