import Foundation
import Observation

/// Drives the auto-sync state machine. Cycle 9 product surface — replaces
/// the manual "推送" / "应用到本机" buttons with a 1Hz foreground tick that
/// converges both sides automatically.
///
/// State machine per `tick()`:
///
/// 1. `GET /SyncClipboard.json` (§2.1) for server metadata.
/// 2. If `server.hash != lastSyncedContentHash`, the server has new content:
///    - If we already fetched bytes for this hash and are waiting for the
///      user to flip the auto-apply toggle (`stagedServerHash == server.hash`),
///      no-op. Otherwise download, verify, and stage `vm.serverLatest`.
///    - If `appSettings.autoApplyServerChanges` is on, write to
///      `UIPasteboard.general` via `pasteboard.write`, advance
///      `lastSyncedContentHash` to the server hash, drop the staged hash.
///    - If off, set `state = .hasNewUnwritten`, keep the staged hash so
///      subsequent ticks don't re-download.
/// 3. Otherwise (server unchanged), check `vm.deviceClipboard.hash` against
///    `lastSyncedContentHash`. The observer is the source of truth — it
///    auto-reads on `UIPasteboard.changedNotification` and
///    `didBecomeActiveNotification`, so by the time the engine ticks, the
///    cached `current` reflects whatever the user just copied. If hashes
///    differ, the engine pushes via `vm.push()` (which itself does a
///    fresh `pasteboard.snapshot()` for bytes).
/// 4. On success, advance `lastSyncedContentHash` to the new content hash.
///
/// Conflict resolution is server-wins. When both sides changed inside the
/// same tick the server is processed first; on the next tick the device
/// pasteboard now matches the server (we just wrote it) and the hash dedup
/// short-circuits push, so we don't echo the server's content back to it.
///
/// Errors:
/// - `.authFailed` (401) → `state = .authFailed`, the loop pauses entirely.
///   Resume by calling `start()` again after the user fixes credentials.
/// - `.networkUnreachable` / `.timeout` / others → `state = .offlineRetrying`
///   and the next tick fires after `offlineBackoffSeconds` instead of the
///   normal cadence.
/// - `.notFound` (404) on server GET is the documented "empty server"
///   state and is treated as success — fall through to the push side.
@MainActor
@Observable
final class SyncEngine {
    enum State: Equatable {
        case idle
        case succeeded
        case hasNewUnwritten
        case offlineRetrying
        case authFailed
        /// Apply/Push of the same hash flipped too many times inside the
        /// `SyncLoopGuard` window — the loop is suspended until the user
        /// acknowledges via `acknowledgeLoopDetection()`. Set anywhere we
        /// advance `lastAppliedContentHash` / `lastPushedContentHash` and
        /// `loopGuard.tripped()` returns true.
        case loopDetected
    }

    private(set) var state: State = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: SyncError?

    /// Server entry that was fetched but not written to UIPasteboard
    /// because `appSettings.autoApplyServerChanges == false`. UI can show
    /// it highlighted/expanded. `nil` when nothing is staged.
    private(set) var stagedEntry: Clipboard?

    /// True while a user-explicit tick (pull-to-refresh, toolbar refresh
    /// button) is in flight. Routine 1Hz ticks DO NOT flip this — the
    /// connector and toolbar reflect the last stable result state so users
    /// see "已同步" most of the time instead of a flickering "同步中…"
    /// every second.
    private(set) var isExplicitlyRefreshing: Bool = false

    @ObservationIgnored
    private weak var viewModel: AppViewModel?

    @ObservationIgnored
    private let store: SettingsStore

    @ObservationIgnored
    private var lastSyncedContentHash: String?

    /// The hash we most recently *wrote to UIPasteboard* via apply. Tracked
    /// separately from `lastSyncedContentHash` so the push gate has a
    /// second line of defense: even if some downstream layer (basename
    /// canonicalization, iOS pasteboard re-encoding) reports the device
    /// hash slightly differently from the server hash we just applied,
    /// `maybePush` won't push the freshly-applied content back. Cleared
    /// (along with `lastSyncedContentHash`) when the active server flips.
    @ObservationIgnored
    private var lastAppliedContentHash: String?

    /// Cycle detector. Records every apply / push and trips when the same
    /// hash flips direction too many times — see `SyncLoopGuard` for the
    /// state machine.
    @ObservationIgnored
    private var loopGuard = SyncLoopGuard()

    /// Hash we already downloaded but didn't write. Used to dedup the bytes
    /// fetch when auto-apply is off and the server hash hasn't changed.
    @ObservationIgnored
    private var stagedServerHash: String?

    @ObservationIgnored
    private var loopTask: Task<Void, Never>?

    @ObservationIgnored
    private var isTicking: Bool = false

    /// Normal foreground cadence. Public for tests / debug overrides; not a
    /// user setting.
    @ObservationIgnored
    var normalCadenceSeconds: Double = 1.0

    /// Backoff applied when a tick errors out for network reasons.
    @ObservationIgnored
    var offlineBackoffSeconds: Double = 5.0

    /// Minimum gap between successive §2.7 `POST /api/history/query`
    /// rounds. The live-clipboard tick runs every 1s, but the history
    /// API is a heavier (paginated) operation and changes rarely outside
    /// of explicit user activity — 30s captures cross-device edits
    /// quickly enough without hammering the server. Public for tests
    /// that want to compress it to zero.
    @ObservationIgnored
    var historySyncInterval: Double = 30.0

    /// Safety bound on the inner pagination loop. The empty-array
    /// sentinel is the documented end-of-list, so this only ever fires
    /// on a misbehaving server.
    @ObservationIgnored
    var historySyncMaxPages: Int = 50

    /// When the last successful (or attempted) `runHistorySyncIfDue` ran.
    /// nil triggers an immediate first sync on the next tick.
    @ObservationIgnored
    private var lastHistorySyncAt: Date?

    init(viewModel: AppViewModel, store: SettingsStore) {
        self.viewModel = viewModel
        self.store = store
        self.lastSyncedContentHash = store.loadLastSyncedHash()
    }

    /// Begin the polling loop. Idempotent — calling while already running
    /// is a no-op. Call from `scenePhase == .active`. Resets `.authFailed`
    /// on the assumption that the caller is retrying after a credential
    /// fix. Does NOT reset `.loopDetected` — that one requires explicit
    /// user acknowledgment via `acknowledgeLoopDetection()`, otherwise the
    /// next scene-phase flip would silently re-enter the loop.
    func start() {
        guard loopTask == nil else { return }
        if state == .authFailed { state = .idle }
        if state == .loopDetected { return }
        loopTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                let interval = self.cadenceSeconds()
                if interval.isInfinite { break }
                let nanos = UInt64(max(0.05, interval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    /// Cancel the polling loop. Call from `scenePhase == .background` and
    /// before tearing down the engine.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Run a tick now, ignoring the normal cadence and any offline backoff.
    /// Marked as an explicit refresh — UI shows a spinner until it
    /// completes. Used by the toolbar refresh button.
    func forceTickNow() {
        Task { @MainActor in await self.tick(explicit: true) }
    }

    /// Awaitable explicit tick — use from `.refreshable` so the SwiftUI
    /// pull-to-refresh control keeps its native spinner up until the
    /// tick actually finishes (rather than flashing for a frame).
    func explicitRefresh() async {
        await tick(explicit: true)
    }

    /// Called by the UI when the user manually applies a staged server
    /// entry (e.g. taps "应用" on the home-screen banner). Advances
    /// `lastSyncedContentHash` to the staged hash and clears the staged
    /// state so the next tick exits `.hasNewUnwritten` instead of
    /// re-observing the same server hash and re-staging it forever.
    /// No-op when nothing is staged.
    func markStagedApplied() {
        guard let hash = stagedServerHash else { return }
        advanceSynced(to: hash)
        lastAppliedContentHash = hash.uppercased()
        stagedServerHash = nil
        stagedEntry = nil
        state = .succeeded
        lastSyncedAt = .now
        lastError = nil
    }

    /// User-side dismissal of the loop-detected banner. Wipes the cycle
    /// detector's buffer so the next legitimate sync doesn't re-trip
    /// instantly, drops back to `.idle`, and restarts the loop. Safe to
    /// call when the state isn't `.loopDetected` — clears the buffer and
    /// restarts as a defensive no-op.
    func acknowledgeLoopDetection() {
        loopGuard.reset()
        state = .idle
        lastError = nil
        start()
    }

    /// Clear runtime state without touching persisted hash. Useful when the
    /// user switches active server — the new server has its own content
    /// timeline.
    func resetRuntimeState() {
        stagedServerHash = nil
        stagedEntry = nil
        lastAppliedContentHash = nil
        loopGuard.reset()
        lastError = nil
        state = .idle
        // Force the next tick to hit /api/history/query immediately —
        // the new server's `lastModified` watermark is unrelated to the
        // old one's, so we have to refetch from scratch (the caller
        // clears `vm.historyWatermark` separately).
        lastHistorySyncAt = nil
    }

    /// Called by `AppViewModel.servers.didSet`. Decides whether to clear
    /// per-server state and / or restart a paused (.authFailed) loop.
    /// Compares effective (SSID-resolved) configs because an SSID-list
    /// edit on a non-active server can flip the effective active without
    /// touching `activeConfigId`.
    func handleServersChange(from old: ServerConfigList, to new: ServerConfigList) {
        let ssid = viewModel?.ssidProvider.currentSSID
        let oldEffectiveId = old.resolveActiveConfig(currentSsid: ssid)?.id
        let newEffectiveId = new.resolveActiveConfig(currentSsid: ssid)?.id
        if oldEffectiveId != newEffectiveId {
            // Different server entirely — content timeline differs, drop hash.
            // `resetRuntimeState` also clears `.loopDetected`, so we then need
            // to restart the loop unconditionally (it was stopped when the
            // breaker tripped).
            resetRuntimeState()
            lastSyncedContentHash = nil
            store.saveLastSyncedHash(nil)
            // §2.7 watermark is per-server too — clear it so the next
            // tick pulls the new server's full history page by page.
            viewModel?.historyWatermark = nil
            start()
        }
        if state == .authFailed {
            // The user almost certainly just edited credentials. Restart and
            // see whether the new ones work; if not we'll land back in
            // .authFailed within one tick.
            start()
        }
    }

    /// Called when the effective active server changed due to a Wi-Fi
    /// flip (not a config edit). Drops per-server runtime state and
    /// forces an immediate tick so the new server's clipboard surfaces
    /// without waiting for the 1Hz cadence.
    func handleEffectiveActiveChange() {
        // §5.3: switching servers is a content-timeline change. Drop the
        // staged + last-synced hashes so the new server's first entry
        // isn't mistaken for a duplicate.
        resetRuntimeState()
        lastSyncedContentHash = nil
        store.saveLastSyncedHash(nil)
        // §2.7 watermark is per-server. Also clear it so the new server's
        // first history pull is unfiltered.
        viewModel?.historyWatermark = nil
        // Restart the loop unconditionally — `resetRuntimeState` already
        // cleared `.loopDetected`, and `start()` is a no-op if the loop is
        // already running. `forceTickNow` alone wouldn't be enough: when
        // the breaker had tripped the loopTask is nil, so we need start()
        // to revive the cadence.
        if state == .authFailed {
            start()
        } else {
            start()
            forceTickNow()
        }
    }

    private func cadenceSeconds() -> Double {
        switch state {
        case .authFailed:       return .infinity
        case .loopDetected:     return .infinity
        case .offlineRetrying:  return offlineBackoffSeconds
        default:                return normalCadenceSeconds
        }
    }

    private func tick(explicit: Bool = false) async {
        guard !isTicking else { return }
        isTicking = true
        if explicit { isExplicitlyRefreshing = true }
        defer {
            isTicking = false
            if explicit { isExplicitlyRefreshing = false }
        }
        guard let vm = viewModel,
              let server = vm.effectiveActiveConfig else {
            state = .idle
            return
        }
        if state == .authFailed || state == .loopDetected { return }
        // Cross-process re-sync: the Share Extension writes
        // `lastSyncedContentHash` directly into the App Group when it
        // finishes a push (see CLAUDE.md "Share Extension write
        // coordination"). Without re-reading here, the engine's in-memory
        // copy from `init` is stale and the next tick would re-apply the
        // just-shared entry back onto the device — the exact ping-pong
        // that the coordination key was meant to prevent.
        let persisted = store.loadLastSyncedHash()
        if !hashesEqual(persisted, lastSyncedContentHash) {
            lastSyncedContentHash = persisted?.uppercased()
        }
        // Note: routine 1Hz ticks don't transition to a "syncing"
        // intermediate state — the visible `state` stays at its last
        // stable value, so the connector strip doesn't flicker every
        // second between "同步中…" and "已同步". Explicit refreshes
        // surface their progress via `isExplicitlyRefreshing` instead.
        do {
            let client = try SyncClipboardClient(
                server: server,
                trustInsecureCert: vm.appSettings.trustInsecureCert
            )
            // Pull side first (server-wins).
            let serverEntryOrNil: Clipboard?
            do {
                serverEntryOrNil = try await client.getClipboard()
            } catch let e as SyncError where e.kind == .notFound {
                // Empty server — leave serverLatest as-is, fall through.
                serverEntryOrNil = nil
            }
            if let serverEntry = serverEntryOrNil,
               !hashesEqual(serverEntry.hash, lastSyncedContentHash) {
                try await processServerNew(serverEntry, client: client, vm: vm)
            } else {
                // Push side.
                try await maybePush(client: client, vm: vm, server: server)
            }
            // Best-effort incremental history sync (§2.7), throttled to
            // `historySyncInterval`. Internal failures don't escalate to
            // engine state — history is a strict superset of the live
            // clipboard, and the live tick above is the user-visible
            // sync signal.
            await runHistorySyncIfDue(client: client, vm: vm)
        } catch let e as SyncError where e.kind == .authFailed {
            state = .authFailed
            lastError = e
            stop()
        } catch let e as SyncError {
            state = .offlineRetrying
            lastError = e
        } catch {
            state = .offlineRetrying
            lastError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    private func processServerNew(
        _ entry: Clipboard,
        client: SyncClipboardClient,
        vm: AppViewModel
    ) async throws {
        // Dedup: if we already fetched this hash and the user just hasn't
        // flipped auto-apply yet, skip the bytes round-trip.
        let alreadyStaged = stagedServerHash.map { hashesEqual($0, entry.hash) } ?? false
        if !alreadyStaged {
            vm.serverLatest = entry
            // First time we see this server entry — log it on the Home
            // list as a pulled event. The staged branch above is a
            // re-observation of the same hash, so we'd otherwise double
            // log every tick the user leaves auto-apply off.
            vm.appendHistory(entry: entry, direction: .pulled)
        }
        if vm.appSettings.autoApplyServerChanges {
            // Reuse vm.applyServerToDevice — it handles text-short / text-long /
            // image branches and pasteboard.write. It reads vm.serverLatest, so
            // make sure the latest is set above.
            await vm.applyServerToDevice()
            if let err = vm.applyError {
                throw err
            }
            advanceSynced(to: entry.hash)
            lastAppliedContentHash = entry.hash?.uppercased()
            stagedServerHash = nil
            stagedEntry = nil
            state = .succeeded
            lastSyncedAt = .now
            lastError = nil
            loopGuard.record(.pulled, hash: entry.hash)
            if loopGuard.tripped() { tripLoopBreaker() }
        } else {
            // Stage but don't write. Update stagedServerHash to dedup next
            // tick. lastSyncedContentHash stays where it was — until the
            // user toggles auto-apply on or copies something new locally,
            // we're "stuck" on hasNewUnwritten by design.
            stagedServerHash = entry.hash
            stagedEntry = entry
            state = .hasNewUnwritten
            lastSyncedAt = .now
            lastError = nil
        }
    }

    private func maybePush(
        client: SyncClipboardClient,
        vm: AppViewModel,
        server: ServerConfig
    ) async throws {
        guard let device = vm.deviceClipboard else {
            // Observer hasn't surfaced anything yet (cold start, env-hook
            // returned nil, etc). Nothing to push.
            state = .succeeded
            lastSyncedAt = .now
            lastError = nil
            return
        }
        if hashesEqual(device.hash, lastSyncedContentHash) {
            // Already synced.
            state = .succeeded
            lastSyncedAt = .now
            lastError = nil
            return
        }
        if hashesEqual(device.hash, lastAppliedContentHash) {
            // Defense (B): the freshly-applied entry IS what's on the
            // pasteboard right now — but observer.current's hash might
            // disagree with `lastSyncedContentHash` because of basename
            // canonicalization (e.g., server's dataName="photo.heif" got
            // re-snapshotted as the priority-list canonical "image.heic",
            // changing the §4.2 basename-bound hash). Treat this as
            // already synced and DON'T push the device version back; doing
            // so would echo the server's content back to the server under
            // a different basename and start the apply↔push pong.
            state = .succeeded
            lastSyncedAt = .now
            lastError = nil
            return
        }
        // `vm.push()` early-returns silently if the pasteboard snapshot
        // is nil or has an unpushable type — in that case nothing
        // network-side happened, but `vm.serverLatest` is still the
        // last-known good entry. Use `lastPushedAt` advancing as the
        // canonical "a real push round-tripped" signal so we don't
        // double-log the live entry as `.pushed`.
        let prePushedAt = vm.lastPushedAt
        await vm.push()
        if let err = vm.pushError {
            throw err
        }
        if vm.lastPushedAt != prePushedAt, let pushed = vm.serverLatest {
            advanceSynced(to: pushed.hash)
            vm.appendHistory(entry: pushed, direction: .pushed)
            loopGuard.record(.pushed, hash: pushed.hash)
            if loopGuard.tripped() { tripLoopBreaker() }
            // Mirror the Share Extension's donation so iOS Sharing
            // Suggestions ranks this server higher even when the user
            // never explicitly invokes the share sheet — auto-sync
            // counts as "sent to this server" too. Fire-and-forget so
            // the next tick isn't blocked on IPC.
            Task { await ShareIntentDonation.donateSend(to: server, clipboard: pushed) }
        }
        // No serverLatest after push = silent skip (no active config / no
        // pushable snapshot / type unsupported). Don't advance hash, but
        // succeeded state lets the loop continue.
        state = .succeeded
        lastSyncedAt = .now
        lastError = nil
    }

    private func advanceSynced(to hash: String?) {
        // A nil/empty hash means the entry is unverifiable (hashMatches treats
        // it as a pass per §4.4). We can still mark it "synced for the moment"
        // but can't dedup future ticks — leave lastSyncedContentHash alone so
        // the next tick re-evaluates. Rare in practice (well-formed servers
        // always emit hash).
        guard let hash, !hash.isEmpty else { return }
        let normalized = hash.uppercased()
        lastSyncedContentHash = normalized
        store.saveLastSyncedHash(normalized)
    }

    /// Pull the §2.7 history pages incrementally and merge into
    /// `vm.history`. Best-effort: any failure is swallowed and the next
    /// due window will retry. Throttled by `historySyncInterval`.
    private func runHistorySyncIfDue(client: SyncClipboardClient, vm: AppViewModel) async {
        if let last = lastHistorySyncAt,
           Date().timeIntervalSince(last) < historySyncInterval {
            return
        }
        // Always advance the throttle, even on failure — otherwise a
        // server that 500s on /api/history/query would have every 1Hz
        // tick spam-retry the endpoint.
        defer { lastHistorySyncAt = .now }

        let watermark = vm.historyWatermark
        var maxModified: Date = watermark ?? .distantPast
        var page = 1
        while page <= historySyncMaxPages {
            let records: [HistoryRecord]
            do {
                records = try await client.queryHistory(
                    HistoryQuery(page: page, modifiedAfter: watermark)
                )
            } catch {
                // Best-effort. Swallow — the engine's `state` and
                // `lastError` remain tied to the live-clipboard path.
                return
            }
            if records.isEmpty { break }
            for record in records {
                vm.mergeHistoryRecord(record)
                if let lm = record.lastModified, lm > maxModified {
                    maxModified = lm
                }
            }
            page += 1
        }
        if maxModified > (watermark ?? .distantPast) {
            vm.historyWatermark = maxModified
        }
    }

    /// Park the engine in `.loopDetected` and stop the polling loop.
    /// Idempotent — re-entering the trip path while already tripped is a
    /// no-op. Recovery is `acknowledgeLoopDetection()` from the UI.
    private func tripLoopBreaker() {
        guard state != .loopDetected else { return }
        state = .loopDetected
        lastError = SyncError(
            kind: .networkUnreachable,
            underlying: "auto-sync loop detected — same content alternated apply/push too many times"
        )
        stop()
    }

    private func hashesEqual(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let l?, let r?): return l.uppercased() == r.uppercased()
        default: return false
        }
    }
}
