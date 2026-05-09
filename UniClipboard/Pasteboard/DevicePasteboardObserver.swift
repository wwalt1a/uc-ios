import Foundation
import UIKit
import Observation

/// Reads `UIPasteboard.general` and exposes the result as an observable
/// `Clipboard?`. App-target-only (UIKit dependency); not built by SwiftPM.
///
/// Re-reads on:
/// - init (for the cold-launch initial value)
/// - `UIPasteboard.changedNotification`
/// - `UIApplication.didBecomeActiveNotification` (foreground)
/// - explicit `read()` calls from the UI (refresh button / pull-to-refresh)
///
/// Text-only this cycle. Image / File / Group reads will be added with the
/// PUT cycle, where the bytes-preservation problem must be solved anyway.
///
/// DEBUG env hook: `UC_DEVICE_TEXT`
/// - unset           → real `UIPasteboard.general.string` reads
/// - empty string    → reports `nil` (drives empty-state UI)
/// - any other value → reports `Clipboard.fromText(value)`, never touches UIPasteboard
///
/// Reads on iOS 16+ paint the system "pasted from <App>" banner. Acceptable
/// for now; switching to `UIPasteControl` to suppress it is a separate UI
/// cycle.
@MainActor
@Observable
final class DevicePasteboardObserver {

    private(set) var current: Clipboard?

    @ObservationIgnored
    private let envMode: EnvMode

    @ObservationIgnored
    private var observers: [NSObjectProtocol] = []

    @ObservationIgnored
    private let notificationCenter: NotificationCenter

    init(
        notificationCenter: NotificationCenter = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.notificationCenter = notificationCenter
        self.envMode = EnvMode(environment: environment)
        read()
        subscribe()
    }

    /// Re-read the pasteboard (or env override). Idempotent; safe to call
    /// from notifications and explicit UI triggers.
    func read() {
        switch envMode {
        case .live:
            if let s = UIPasteboard.general.string, !s.isEmpty {
                current = Clipboard.fromText(s)
            } else {
                current = nil
            }
        case .forceNil:
            current = nil
        case .forceText(let s):
            current = Clipboard.fromText(s)
        }
    }

    private func subscribe() {
        observers.append(
            notificationCenter.addObserver(
                forName: UIPasteboard.changedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.read() }
            }
        )
        observers.append(
            notificationCenter.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.read() }
            }
        )
    }

    private enum EnvMode {
        case live
        case forceNil
        case forceText(String)

        init(environment: [String: String]) {
            switch environment["UC_DEVICE_TEXT"] {
            case .none:                       self = .live
            case .some(let s) where s.isEmpty: self = .forceNil
            case .some(let s):                 self = .forceText(s)
            }
        }
    }
}
