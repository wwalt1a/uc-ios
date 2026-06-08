import SwiftUI
import UIKit

/// Fixed-size card for a two-column clipboard grid (Paste-app style).
/// Width is determined by the enclosing grid column; height is pinned to ~160pt.
struct ClipboardCard: View {
    let item: ClipboardHistoryItem
    let isLatest: Bool
    var thumbnailImage: UIImage? = nil
    var isLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            bodyContent
            Spacer(minLength: 0)
            bottomRow
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 180)
        .liquidGlassCard(cornerRadius: 14)
        .overlay {
            if isLoading {
                Color(.systemBackground).opacity(0.6)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        ProgressView()
                    }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text(item.entry.type.localizedLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(item.timestamp.cardRelativeShort)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyContent: some View {
        switch item.entry.type {
        case .text:
            Text(item.entry.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .image:
            if let thumbnail = thumbnailImage {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 80)
                    .clipped()
            } else {
                imagePlaceholder
            }

        case .file, .group:
            fileBody
        }
    }

    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(item.entry.type.tint.opacity(0.15))
            .frame(maxWidth: .infinity, maxHeight: 80)
            .overlay {
                Image(systemName: "photo.fill")
                    .font(.title2)
                    .foregroundStyle(item.entry.type.tint.opacity(0.6))
            }
    }

    private var fileBody: some View {
        VStack(spacing: 6) {
            Image(systemName: item.entry.type.symbolName)
                .font(.largeTitle)
                .foregroundStyle(item.entry.type.tint)
            Text(item.entry.dataName ?? item.entry.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom

    private var bottomRow: some View {
        HStack(spacing: 4) {
            Image(systemName: item.direction == .pulled ? "arrow.down" : "arrow.up")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if isLatest {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Relative time helper (card-specific)

private extension Date {
    /// "刚刚" inside +/-5s, otherwise the system relative formatter with short style.
    /// Mirrors `HomeView`'s `relativeShort` but kept private to this file to
    /// avoid coupling to the list view's helper.
    var cardRelativeShort: String {
        let dt = timeIntervalSinceNow
        if abs(dt) < 5 { return String(localized: "刚刚") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: .now)
    }
}

// MARK: - Previews

#Preview("Text card") {
    let item = ClipboardHistoryItem(
        entry: Clipboard(
            type: .text,
            hash: "AABB",
            text: "ssh alice@dev.home.lan -p 2222\nsome more content here to test multiline",
            hasData: false,
            size: 60
        ),
        timestamp: .now.addingTimeInterval(-45),
        direction: .pushed
    )
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ClipboardCard(item: item, isLatest: true)
        ClipboardCard(item: item, isLatest: false)
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("Image card") {
    let item = ClipboardHistoryItem(
        entry: Clipboard(
            type: .image,
            hash: "CCDD",
            text: "photo_2026.png",
            hasData: true,
            dataName: "photo_2026.png",
            size: 184_320
        ),
        timestamp: .now.addingTimeInterval(-3600),
        direction: .pulled
    )
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ClipboardCard(item: item, isLatest: false, thumbnailImage: nil)
        ClipboardCard(item: item, isLatest: true, thumbnailImage: UIImage(systemName: "photo.artframe"))
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("File card") {
    let item = ClipboardHistoryItem(
        entry: Clipboard(
            type: .file,
            hash: "EEFF",
            text: "report.pdf",
            hasData: true,
            dataName: "report.pdf",
            size: 1_048_576
        ),
        timestamp: .now.addingTimeInterval(-2 * 86400),
        direction: .pulled
    )
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ClipboardCard(item: item, isLatest: false)
        ClipboardCard(item: item, isLatest: false, isLoading: true)
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("Group card") {
    let item = ClipboardHistoryItem(
        entry: Clipboard(
            type: .group,
            hash: "1122",
            text: "screenshots.zip",
            hasData: true,
            dataName: "screenshots.zip",
            size: 5_242_880
        ),
        timestamp: .now.addingTimeInterval(-4 * 86400),
        direction: .pushed
    )
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ClipboardCard(item: item, isLatest: true)
        ClipboardCard(item: item, isLatest: false)
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
