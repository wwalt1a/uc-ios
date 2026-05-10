import Foundation
import Observation

/// Owns the app's persisted state and writes mutations back to disk
/// automatically. Sits between the views and `SettingsStore`.
///
/// Lives in the app layer (not in the SwiftPM `Models` target) because
/// `@Observable` and `@MainActor` are SwiftUI-shaped concerns; the model
/// types it carries (`ServerConfigList`, `AppSettings`) are the
/// Foundation-only ones from `Models/`.
@MainActor
@Observable
final class AppViewModel {
    var servers: ServerConfigList {
        didSet { store.saveServers(servers) }
    }

    var appSettings: AppSettings {
        didSet { store.saveAppSettings(appSettings) }
    }

    /// Last clipboard fetched from the active server. Runtime state, not
    /// persisted — spec §5.5 doesn't list a key for it and stale data on
    /// cold launch would mislead.
    var serverLatest: Clipboard?

    /// When `serverLatest` was last refreshed (success or 404). Reset on
    /// every `refresh()` outcome so the UI's "5 minutes ago" label tracks
    /// reality.
    var lastSyncedAt: Date?

    /// Last error from `refresh()`. Cleared on success.
    var refreshError: SyncError?

    /// Whether a refresh is in flight.
    var isRefreshing: Bool = false

    /// When the device clipboard was last successfully pushed to the
    /// active server. Runtime state — not persisted. Cleared on push
    /// failure so the UI doesn't show a misleading "上次推送 5 秒前"
    /// next to a fresh error banner.
    var lastPushedAt: Date?

    /// Last error from `push()`. Cleared on success.
    var pushError: SyncError?

    /// Whether a push is in flight.
    var isPushing: Bool = false

    /// Whether `applyServerToDevice()` is in flight (long-text path only;
    /// short text completes synchronously and never sets this).
    var isApplying: Bool = false

    /// Last error from `applyServerToDevice()`. Cleared on success.
    var applyError: SyncError?

    /// Whether `saveServerAttachment()` is in flight.
    var isSaving: Bool = false

    /// Last error from `saveServerAttachment()`. Cleared on success.
    var saveError: SyncError?

    /// File URL of the most-recent successful `saveServerAttachment()`.
    /// Cleared on the next refresh or save attempt so the UI's
    /// "已保存到 …" caption doesn't outlive its relevance.
    var lastSavedFileURL: URL?

    /// Current device pasteboard snapshot. Computed; the observer is the
    /// source of truth and `@Observable` propagates its `current` reads
    /// through this accessor automatically.
    var deviceClipboard: Clipboard? { pasteboard.current }

    @ObservationIgnored
    private let store: SettingsStore

    @ObservationIgnored
    private let pasteboard: DevicePasteboardObserver

    /// - Parameters:
    ///   - store: persistence backend; default uses `UserDefaults.standard`.
    ///   - forceFreshServers: when true, ignore stored servers and start
    ///     with an empty list (drives the SetupFlow). Defaults to reading
    ///     `UC_FRESH=1` from the environment so screenshot recipes work.
    ///   - pasteboard: device pasteboard observer; default reads
    ///     `UIPasteboard.general` (or honors `UC_DEVICE_TEXT` env hook).
    init(
        store: SettingsStore = SettingsStore(),
        forceFreshServers: Bool = ProcessInfo.processInfo.environment["UC_FRESH"] == "1",
        pasteboard: DevicePasteboardObserver? = nil
    ) {
        // `DevicePasteboardObserver` is `@MainActor`, so its default value
        // must be constructed inside the init body — default-argument
        // expressions are evaluated in a nonisolated context.
        self.store = store
        self.pasteboard = pasteboard ?? DevicePasteboardObserver()
        self.servers = forceFreshServers ? ServerConfigList() : store.loadServers()
        self.appSettings = store.loadAppSettings()
    }

    /// Re-read the device pasteboard. Triggered by toolbar refresh and
    /// pull-to-refresh; foreground / pasteboard-changed notifications
    /// re-read automatically.
    func readPasteboard() { pasteboard.read() }

    /// Write the active server's clipboard to the device. Text: short
    /// path writes from metadata `text`; long path downloads §2.4 payload,
    /// §4.1-verifies via bytes hash, decodes UTF-8, writes. Image:
    /// downloads payload, §4.2-verifies (basename + bytes), writes the
    /// raw bytes under the matching UTI. File/Group are no-ops — file
    /// bytes have no meaningful UIPasteboard target, group needs §4.3.
    func applyServerToDevice() async {
        guard let entry = serverLatest else { return }
        switch entry.type {
        case .text:
            if !entry.hasData {
                pasteboard.write(text: entry.text)
                applyError = nil
                return
            }
            guard !isApplying else { return }
            guard let server = servers.activeConfig, let dataName = entry.dataName else { return }
            isApplying = true
            defer { isApplying = false }
            do {
                let client = try SyncClipboardClient(server: server, trustInsecureCert: appSettings.trustInsecureCert)
                let bytes = try await client.getFile(name: dataName)
                try Self.verify(bytes: bytes, against: entry)
                let text = String(decoding: bytes, as: UTF8.self)
                pasteboard.write(text: text)
                applyError = nil
            } catch let e as SyncError {
                applyError = e
            } catch {
                applyError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
            }
        case .image:
            guard entry.hasData,
                  let dataName = entry.dataName,
                  let server = servers.activeConfig
            else { return }
            guard !isApplying else { return }
            isApplying = true
            defer { isApplying = false }
            do {
                let client = try SyncClipboardClient(server: server, trustInsecureCert: appSettings.trustInsecureCert)
                let bytes = try await client.getFile(name: dataName)
                try Self.verify(bytes: bytes, against: entry)
                pasteboard.write(data: bytes, uti: Self.utiForDataName(dataName), originalName: dataName)
                applyError = nil
            } catch let e as SyncError {
                applyError = e
            } catch {
                applyError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
            }
        case .file, .group:
            return
        }
    }

    /// Download an image or file server entry's payload and write it to
    /// `Documents/<sanitized downloadRelativePath>/<dataName>`. Group
    /// entries are out of scope this cycle (§4.3 ZIP-traversal hash is
    /// its own slice). Overwrites on collision — matches Files-app
    /// behavior.
    func saveServerAttachment() async {
        guard !isSaving else { return }
        guard let entry = serverLatest,
              entry.hasData,
              entry.type == .image || entry.type == .file,
              let dataName = entry.dataName,
              let server = servers.activeConfig
        else { return }
        isSaving = true
        defer { isSaving = false }
        lastSavedFileURL = nil
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: appSettings.trustInsecureCert)
            let bytes = try await client.getFile(name: dataName)
            try Self.verify(bytes: bytes, against: entry)
            let url = try Self.targetURL(for: dataName, relative: appSettings.downloadRelativePath)
            try bytes.write(to: url, options: .atomic)
            lastSavedFileURL = url
            saveError = nil
        } catch let e as SyncError {
            saveError = e
        } catch {
            saveError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    /// §4.4 verify, branching on the entry's type because the hash
    /// algorithm differs: §4.1 (raw SHA256 over UTF-8 bytes) for text;
    /// §4.2 (basename-bound) for image/file. Group is unimplemented and
    /// the caller (saveServerAttachment) gates it out before reaching
    /// here. Null/whitespace `entry.hash` short-circuits to a pass via
    /// `hashMatches` semantics.
    private static func verify(bytes: Data, against entry: Clipboard) throws {
        let actual: String
        switch entry.type {
        case .text:
            actual = Clipboard.computeBytesHash(bytes)
        case .image, .file:
            guard let name = entry.dataName else {
                throw SyncError(kind: .hashMismatch, underlying: "missing dataName for \(entry.type)")
            }
            actual = Clipboard.computeFileHash(name: name, bytes: bytes)
        case .group:
            return
        }
        guard Clipboard.hashMatches(expected: entry.hash, actual: actual) else {
            throw SyncError(kind: .hashMismatch)
        }
    }

    /// Map a payload filename to the UTI used when writing the bytes back
    /// to UIPasteboard during apply-image. Mirror of the read-side UTI
    /// table on `DevicePasteboardObserver`.
    private static func utiForDataName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png":          return "public.png"
        case "heic", "heif": return "public.heic"
        case "jpg", "jpeg":  return "public.jpeg"
        case "gif":          return "com.compuserve.gif"
        default:             return "public.data"
        }
    }

    private static func targetURL(for dataName: String, relative: String) throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Sanitize against container escape and weird input. Drops `..`,
        // `.`, and empty segments; strips leading/trailing slashes by virtue
        // of the split. Trailing-slash and leading-slash users still get
        // their intended subdir.
        let sanitized = relative
            .split(separator: "/")
            .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
            .map(String.init)
        var dir = docs
        for segment in sanitized {
            dir.appendPathComponent(segment, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(dataName, isDirectory: false)
    }
}

extension AppViewModel {
    /// Publish the device clipboard to the active server. Spec §2.2 +
    /// §2.3 + §3.4 + §3.5. Text and image; file/group are no-ops (file
    /// from UIPasteboard isn't meaningful on iOS, group needs §4.3).
    /// - Returns silently if no active server, no device clipboard, or
    ///   already pushing.
    /// - Reads the pasteboard fresh via `snapshot()` rather than the
    ///   cached `current`, so a copy-then-push race produces the
    ///   semantically-current clipboard not a stale one.
    /// - Payload-bearing entries go file-first per §3.5; failures in the
    ///   file PUT skip the metadata PUT so the server never sees a
    ///   metadata pointer to a missing file.
    /// - On success, optimistically updates `serverLatest` to the
    ///   metadata-only entry so the server card reflects reality without
    ///   a follow-up GET.
    func push() async {
        guard !isPushing else { return }
        guard let server = servers.activeConfig else { return }
        guard let snapshot = pasteboard.snapshot(),
              snapshot.clipboard.type == .text || snapshot.clipboard.type == .image
        else { return }
        isPushing = true
        defer { isPushing = false }
        let trustInsecure = appSettings.trustInsecureCert
        let entry = snapshot.clipboard
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: trustInsecure)
            if let payload = snapshot.payload, let dataName = entry.dataName {
                try await client.putFile(name: dataName, body: payload)
            }
            try await client.putClipboard(entry)
            serverLatest = entry
            lastSyncedAt = .now
            lastPushedAt = .now
            pushError = nil
            refreshError = nil
        } catch let e as SyncError {
            pushError = e
        } catch {
            pushError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    /// Pull the active server's latest clipboard. Spec §2.1.
    /// - 404 is the documented empty state — clears `serverLatest`,
    ///   updates `lastSyncedAt`, leaves `refreshError` nil.
    /// - Other errors keep the previous `serverLatest` (stale > blank)
    ///   and surface via `refreshError`.
    /// - No active config → spec §5.2 forbids the call; returns silently.
    func refresh() async {
        guard let server = servers.activeConfig else { return }
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // The "已保存到 …" caption is bound to the last save attempt, not
        // the server-side state. A refresh changes what's on screen, so the
        // caption no longer matches the entry above it — clear it.
        lastSavedFileURL = nil
        let trustInsecure = appSettings.trustInsecureCert
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: trustInsecure)
            let clip = try await client.getClipboard()
            serverLatest = clip
            lastSyncedAt = .now
            refreshError = nil
        } catch let e as SyncError where e.kind == .notFound {
            serverLatest = nil
            lastSyncedAt = .now
            refreshError = nil
        } catch let e as SyncError {
            refreshError = e
        } catch {
            refreshError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    /// Builds a VM bound to an isolated `UserDefaults` suite — for use in
    /// `#Preview` blocks so previews don't read or write `.standard`.
    /// `deviceText: nil` keeps the device pasteboard empty in the preview;
    /// pass a string to seed `vm.deviceClipboard` without touching the
    /// real `UIPasteboard.general`.
    static func preview(
        servers: ServerConfigList = Mock.servers,
        appSettings: AppSettings = AppSettings(
            manualUploadDialogShown: true,
            downloadRelativePath: "SyncClipboard/Inbox",
            ignoredVersion: "0.3.2"
        ),
        deviceText: String? = nil
    ) -> AppViewModel {
        let suite = UserDefaults(suiteName: "AppViewModel.preview-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: suite)
        store.saveServers(servers)
        store.saveAppSettings(appSettings)
        let pasteboardEnv: [String: String] = ["UC_DEVICE_TEXT": deviceText ?? ""]
        let pasteboard = DevicePasteboardObserver(environment: pasteboardEnv)
        return AppViewModel(store: store, forceFreshServers: false, pasteboard: pasteboard)
    }
}
