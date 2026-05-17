import Foundation
import CoreLocation
import Network
import NetworkExtension

/// Reads the current WiFi SSID via `NEHotspotNetwork.fetchCurrent` and
/// surfaces the Core Location authorization state required for it.
///
/// Gotchas worth knowing before touching this file:
///
/// - The supported read path is `NEHotspotNetwork.fetchCurrent`, not the
///   older `CNCopyCurrentNetworkInfo`. On iOS 26 the CaptiveNetwork
///   entry point (`CNCopySupportedInterfaces`) returns nil even when
///   the entitlement + Location auth are both present, which silently
///   maps to "未连接 WiFi" in the UI. `NEHotspotNetwork` keeps working.
/// - The call returns a useful SSID only when (a) the app holds the
///   `Access WiFi Information` entitlement
///   (`com.apple.developer.networking.wifi-info`), and (b) Location When
///   In Use authorization has been granted. Either missing → nil.
/// - Simulator: there's no Wi-Fi interface to query. We detect the
///   simulator via `targetEnvironment(simulator)` and surface
///   `.unavailable` so the UI hides the auth/SSID row. The
///   `UC_MOCK_CURRENT_SSID` env hook lets screenshot recipes pretend a
///   network is connected.
/// - Auth status: we use the instance-bound `authorizationStatus` (iOS 14+)
///   rather than the deprecated class-level accessor. The delegate's
///   `locationManagerDidChangeAuthorization(_:)` is the canonical entry
///   point — it fires once on first init and again whenever the user
///   changes the setting in system Settings.
///
/// This type is intentionally @MainActor + @Observable so SwiftUI views
/// can bind directly to `authState` / `currentSSID`. A single instance
/// lives on `AppViewModel`.
@MainActor
@Observable
final class CurrentSSIDProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum AuthState: Equatable, Sendable {
        case notDetermined
        case denied        // user said no, or Location services off, or restricted
        case authorized
        case unavailable   // simulator, missing entitlement, or pre-iOS-13 quirk
    }

    /// Current authorization state, kept in sync with the system via the
    /// `CLLocationManagerDelegate` callback.
    private(set) var authState: AuthState = .notDetermined

    /// Last-read normalized SSID (per §5.1 `normalizeSSID`). `nil` means
    /// "no Wi-Fi connection" or "couldn't read". The UI must not assume
    /// a non-nil value implies the user is authorized — `authState` is
    /// the source of truth for that.
    private(set) var currentSSID: String?

    @ObservationIgnored
    private let manager: CLLocationManager

    @ObservationIgnored
    private let mockSSID: String?

    @ObservationIgnored
    private let pathMonitor: NWPathMonitor

    @ObservationIgnored
    private let pathQueue = DispatchQueue(label: "app.uniclipboard.ssid-path", qos: .utility)

    /// Fires after `currentSSID` actually changes (not on every refresh).
    /// AppViewModel hooks this to drive engine state resets when a Wi-Fi
    /// flip changes the effective active server. Not part of the
    /// observable surface — purely an out-of-band hook.
    @ObservationIgnored
    var onSSIDChanged: ((_ newSSID: String?) -> Void)?

    override init() {
        self.manager = CLLocationManager()
        // `UC_MOCK_CURRENT_SSID` exists only so screenshot recipes can
        // exercise the "current network" UI in the simulator — simctl
        // can't fake a Wi-Fi connection and there's no real interface.
        self.mockSSID = ProcessInfo.processInfo.environment["UC_MOCK_CURRENT_SSID"]
        self.pathMonitor = NWPathMonitor()
        super.init()
        self.manager.delegate = self
        // Sync once synchronously so the very first read after init
        // reflects reality. The delegate will keep us up to date after.
        self.syncAuthState()
        if authState == .authorized || mockSSID != nil {
            refresh()
        }
        // NWPathMonitor catches Wi-Fi flips that CLLocationManager won't
        // notify on. The handler hops to MainActor before calling
        // `refresh()` to keep the @MainActor invariant.
        self.pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        self.pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    /// Prompt the user for Location When In Use authorization. Safe to
    /// call repeatedly — the system suppresses redundant prompts. After
    /// a successful grant the delegate fires and we'll refresh the SSID.
    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Re-read the current SSID. The read itself is async (NEHotspotNetwork.fetchCurrent
    /// is callback-based), but callers don't have to await — we kick off
    /// a `Task` and publish via `currentSSID`. Fires `onSSIDChanged` iff
    /// the resolved SSID actually changed.
    func refresh() {
        let before = currentSSID
        if let mockSSID {
            authState = .authorized
            let normalized = ServerConfig.normalizeSSID(mockSSID)
            if normalized != before {
                currentSSID = normalized
                onSSIDChanged?(currentSSID)
            }
            return
        }
        if authState != .authorized {
            if before != nil {
                currentSSID = nil
                onSSIDChanged?(nil)
            }
            return
        }
        Task { @MainActor in
            let new = await Self.readCurrentSSID()
            if new != self.currentSSID {
                self.currentSSID = new
                self.onSSIDChanged?(new)
            }
        }
    }

    /// Read the current Wi-Fi SSID via `NEHotspotNetwork.fetchCurrent`,
    /// normalized per §5.1.
    ///
    /// Why this and not `CNCopyCurrentNetworkInfo`: the latter was
    /// deprecated in iOS 14 and on iOS 26 its enumeration entry point
    /// (`CNCopySupportedInterfaces`) often returns `nil` outright — even
    /// when the entitlement + Location auth are both granted — which
    /// surfaces in the UI as a misleading "未连接 WiFi". `NEHotspotNetwork`
    /// is the supported path and works with the same `Access WiFi
    /// Information` entitlement + When-In-Use Location authorization.
    /// Returns `nil` when no Wi-Fi is connected or the system declines
    /// to surface the name (e.g. cellular only, hotspot in use, VPN
    /// rerouting interfering).
    private static func readCurrentSSID() async -> String? {
        let network = await withCheckedContinuation { (cont: CheckedContinuation<NEHotspotNetwork?, Never>) in
            // The completion-handler form exists on every supported iOS
            // version; the async form is iOS-16+. Using the bridge keeps
            // the wrapper readable and concurrency-friendly.
            NEHotspotNetwork.fetchCurrent { net in
                cont.resume(returning: net)
            }
        }
        guard let network else { return nil }
        return ServerConfig.normalizeSSID(network.ssid)
    }

    private func syncAuthState() {
        // `manager.authorizationStatus` is the iOS 14+ instance-bound
        // accessor. The class-level `CLLocationManager.authorizationStatus()`
        // was deprecated alongside; using the instance form avoids the
        // warning and also reads the per-app state correctly.
        let new: AuthState
        switch manager.authorizationStatus {
        case .notDetermined:
            new = .notDetermined
        case .denied, .restricted:
            new = .denied
        case .authorizedWhenInUse, .authorizedAlways:
            new = .authorized
        @unknown default:
            new = .denied
        }
        // Simulator can't read a real Wi-Fi interface — surface as
        // `.unavailable` so the UI hides the row entirely and the user
        // doesn't see a useless "授权" button. The `UC_MOCK_CURRENT_SSID`
        // env hook overrides this so screenshot recipes can still
        // exercise the populated state.
        #if targetEnvironment(simulator)
        if new == .authorized,
           ProcessInfo.processInfo.environment["UC_MOCK_CURRENT_SSID"] == nil {
            authState = .unavailable
            return
        }
        #endif
        authState = new
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        syncAuthState()
        if authState == .authorized {
            refresh()
        } else {
            let before = currentSSID
            currentSSID = nil
            if before != nil { onSSIDChanged?(nil) }
        }
    }
}
