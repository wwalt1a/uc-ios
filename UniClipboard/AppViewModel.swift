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

    /// Write the active server's short-text clipboard to the device.
    /// Spec §2.4 (GET file) is out of scope this cycle, so long-text
    /// (`hasData=true`) and image/file/group entries are no-ops here.
    func applyServerToDevice() {
        guard let entry = serverLatest,
              entry.type == .text,
              !entry.hasData
        else { return }
        pasteboard.write(text: entry.text)
    }
}

extension AppViewModel {
    /// Publish the device clipboard to the active server. Spec §2.2 +
    /// §2.3 + §3.4 + §3.5. Text-only this cycle.
    /// - Returns silently if no active server, no device clipboard, or
    ///   already pushing.
    /// - Long text (>10240 chars) goes file-first per §3.5; failures in
    ///   the file PUT skip the metadata PUT so the server never sees a
    ///   metadata pointer to a missing file.
    /// - On success, optimistically updates `serverLatest` to the
    ///   metadata-only entry so the server card reflects reality without
    ///   a follow-up GET.
    func push() async {
        guard !isPushing else { return }
        guard let server = servers.activeConfig else { return }
        guard let device = deviceClipboard, device.type == .text else { return }
        isPushing = true
        defer { isPushing = false }
        let trustInsecure = appSettings.trustInsecureCert
        let (entry, payload) = Clipboard.publishText(device.text)
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: trustInsecure)
            if let payload, let dataName = entry.dataName {
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
