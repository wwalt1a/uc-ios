import SwiftUI
import UIKit

/// Detail preview for one history row. Surfaced by tapping a row on the
/// Home list — gives the user a way to inspect the full contents (long
/// text body, full-resolution image, file metadata) without committing
/// to a "复制到本机" round-trip that would route through UIPasteboard
/// and burn an "Allow Paste" prompt.
///
/// Loading discipline:
/// - Inline text (no `hasData`) is shown immediately from `entry.text`.
/// - Long-text overflow (§3.4: `text` is `Kind.text` AND `hasData=true`)
///   and image payloads are fetched lazily on appear via §2.11.
/// - File / Group entries don't pull bytes — there's no meaningful
///   preview surface for an arbitrary binary, and §4.3 group rendering
///   is out of scope. The metadata card and quick-save action are the
///   whole UX.
struct ClipboardPreviewSheet: View {
    let item: ClipboardHistoryItem
    @Bindable var vm: AppViewModel

    @Environment(\.dismiss) private var dismiss

    /// Lazy-loaded payload bytes for image / long-text rows. `.idle` for
    /// rows that never need bytes (inline text, file, group); `.loading`
    /// while the §2.11 round-trip is in flight; `.loaded` / `.failed`
    /// after.
    @State private var payload: PayloadState = .idle

    private enum PayloadState {
        case idle
        case loading
        case loaded(Data)
        case failed(SyncError)
    }

    private var needsRemotePayload: Bool {
        guard item.entry.hasData else { return false }
        switch item.entry.type {
        case .text, .image:  return true
        case .file, .group:  return false
        }
    }

    /// Whether `vm.applyAttachment` / `vm.reapplyText` can target this
    /// row. Text is always copyable; image needs the bytes to be on the
    /// server addressable via §2.11 (hash present). File / Group can't
    /// land on UIPasteboard meaningfully so the action is hidden.
    private var canCopyToDevice: Bool {
        switch item.entry.type {
        case .text:           return true
        case .image:          return item.entry.hasData && (item.entry.hash?.isEmpty == false)
        case .file, .group:   return false
        }
    }

    /// Whether `vm.saveAttachment` can target this row — image / file
    /// with a hash. Live-latest (no hash) is the live card's territory,
    /// not the per-row history preview.
    private var canSaveToDocuments: Bool {
        guard item.entry.hasData,
              item.entry.type == .image || item.entry.type == .file,
              let hash = item.entry.hash, !hash.isEmpty
        else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    Divider()
                    content
                    metadataCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if canCopyToDevice || canSaveToDocuments {
                    actionBar
                }
            }
            .navigationTitle("预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            guard needsRemotePayload, case .idle = payload else { return }
            await load()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ClipboardKindBadge(kind: item.entry.type, size: .medium, showsLabel: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Image(systemName: item.direction == .pulled ? "arrow.down" : "arrow.up")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.direction == .pulled ? Color.blue : Color.accentColor)
                    Text(item.direction == .pulled ? "来自服务器" : "由本机推送")
                    Text("·").foregroundStyle(.tertiary)
                    Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var headerTitle: String {
        switch item.entry.type {
        case .text:
            return String(localized: "文本")
        case .image, .file, .group:
            // Mirror the home row: prefer dataName when it differs from
            // the label, so an image named `IMG_1234.jpg` stays
            // distinguishable from a generic "image.png" label.
            if let dataName = item.entry.dataName,
               !dataName.isEmpty {
                return dataName
            }
            return item.entry.text
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.entry.type {
        case .text:
            textContent
        case .image:
            imageContent
        case .file:
            fileContent
        case .group:
            fileContent
        }
    }

    // MARK: text

    @ViewBuilder
    private var textContent: some View {
        if !item.entry.hasData {
            // Short text — `entry.text` is the full content per §3.1.
            Text(item.entry.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        } else {
            // §3.4 long-text overflow — `entry.text` is just the first
            // 10240 chars; full body lives at `<dataName>`. Show whatever
            // we have, then swap to the full text once §2.11 returns.
            longTextContent
        }
    }

    @ViewBuilder
    private var longTextContent: some View {
        switch payload {
        case .idle, .loading:
            VStack(alignment: .leading, spacing: 12) {
                Text(item.entry.text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载完整内容…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )

        case .loaded(let bytes):
            let fullText = String(decoding: bytes, as: UTF8.self)
            Text(fullText)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

        case .failed(let err):
            VStack(alignment: .leading, spacing: 10) {
                Text(item.entry.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                errorBanner(err)
            }
            .padding(14)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }

    // MARK: image

    @ViewBuilder
    private var imageContent: some View {
        switch payload {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("正在加载图片…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )

        case .loaded(let bytes):
            if let image = UIImage(data: bytes) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5)
                    )
            } else {
                errorBanner(SyncError(kind: .decodingFailed, underlying: "UIImage failed to decode \(bytes.count) bytes"))
            }

        case .failed(let err):
            errorBanner(err)
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
    }

    // MARK: file / group

    @ViewBuilder
    private var fileContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: item.entry.type.symbolName)
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(item.entry.type.tint.gradient,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.entry.dataName ?? item.entry.text)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if let size = item.entry.size {
                        Text(formatFileSize(size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Text("文件内容无法在此预览。可保存到 Documents 后用文件 App 查看。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    // MARK: metadata card

    @ViewBuilder
    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            metadataRow(label: "类型", value: typeLabel)
            if let dataName = item.entry.dataName, !dataName.isEmpty {
                Divider()
                metadataRow(label: "名称", value: dataName, mono: true)
            }
            if let size = item.entry.size {
                Divider()
                metadataRow(label: "大小", value: sizeLabel(size))
            }
            if let hash = item.entry.hash, !hash.isEmpty {
                Divider()
                metadataRow(label: "校验值", value: shortHash(hash), mono: true)
            }
        }
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    @ViewBuilder
    private func metadataRow(label: LocalizedStringKey, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .footnote.monospaced() : .footnote)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: action bar

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 10) {
            if canCopyToDevice {
                Button {
                    Task { await copy() }
                } label: {
                    Label("复制到本机", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isApplying)
            }
            if canSaveToDocuments {
                Button {
                    Task { await save() }
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(vm.isSaving)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: helpers

    private func load() async {
        payload = .loading
        do {
            let bytes = try await vm.fetchPreviewBytes(for: item)
            payload = .loaded(bytes)
        } catch let e as SyncError {
            payload = .failed(e)
        } catch {
            payload = .failed(SyncError(kind: .networkUnreachable, underlying: "\(error)"))
        }
    }

    private func copy() async {
        if item.entry.type == .text {
            vm.reapplyText(item.entry.text)
            dismiss()
            return
        }
        await vm.applyAttachment(for: item)
        if vm.applyError == nil { dismiss() }
    }

    private func save() async {
        await vm.saveAttachment(for: item)
        if vm.saveError == nil { dismiss() }
    }

    @ViewBuilder
    private func errorBanner(_ err: SyncError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("加载失败")
                    .font(.footnote.weight(.semibold))
                Text(errorMessage(err))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("重试") { Task { await load() } }
                .font(.caption.weight(.semibold))
        }
    }

    private var typeLabel: String {
        switch item.entry.type {
        case .text:  String(localized: "文本")
        case .image: String(localized: "图片")
        case .file:  String(localized: "文件")
        case .group: String(localized: "归档")
        }
    }

    private func sizeLabel(_ size: Int) -> String {
        switch item.entry.type {
        case .text:
            return String(localized: "\(size) 字")
        case .image, .file, .group:
            return formatFileSize(size)
        }
    }

    private func formatFileSize(_ size: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(size))
    }

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 16 else { return hash }
        let prefix = hash.prefix(8)
        let suffix = hash.suffix(8)
        return "\(prefix)…\(suffix)"
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

#Preview("文本预览") {
    let vm = AppViewModel.preview()
    return Color.clear.sheet(isPresented: .constant(true)) {
        ClipboardPreviewSheet(
            item: ClipboardHistoryItem(
                entry: Clipboard.fromText("这是一段被复制到剪贴板的文本内容,可以多行,\n并支持选中复制。"),
                timestamp: .now,
                direction: .pulled
            ),
            vm: vm
        )
    }
}

#Preview("文件预览") {
    let vm = AppViewModel.preview()
    return Color.clear.sheet(isPresented: .constant(true)) {
        ClipboardPreviewSheet(
            item: ClipboardHistoryItem(
                entry: Clipboard(
                    type: .file,
                    hash: "ABCDEFGH12345678ABCDEFGH12345678ABCDEFGH12345678ABCDEFGH12345678",
                    text: "report.pdf",
                    hasData: true,
                    dataName: "report.pdf",
                    size: 245_000
                ),
                timestamp: .now.addingTimeInterval(-3600),
                direction: .pushed
            ),
            vm: vm
        )
    }
}
