import SwiftUI

struct ContentView: View {
    @Bindable var vm: AppViewModel

    @State private var selection: Int = Self.initialTab

    /// Path for the Settings tab's NavigationStack. Initial value lets a
    /// `UC_SETTINGS_ROUTE=servers` env hook deep-link into the Servers
    /// list (or `servers/edit/<idx>` to land on the editor) — needed
    /// because simctl can't synthesize taps for screenshot recipes.
    @State private var settingsPath: [SettingsRoute] = SettingsRoute.initialPath()

    @Environment(\.scenePhase) private var scenePhase

    private static var initialTab: Int {
        guard let i = ProcessInfo.processInfo.environment["UC_INIT_TAB"].flatMap(Int.init) else {
            return 0
        }
        return max(0, min(2, i))
    }

    var body: some View {
        if vm.servers.configs.isEmpty {
            SetupFlowView(vm: vm) {
                // No-op: ContentView re-renders to TabView once configs is non-empty.
            }
            .tint(.indigo)
        } else {
            mainTabs
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selection) {
            Tab("剪贴板", systemImage: "doc.on.clipboard.fill", value: 0) {
                NavigationStack {
                    HomeView(vm: vm, onGoToSettings: { selection = 2 })
                }
            }
            Tab("历史", systemImage: "clock.fill", value: 1) {
                NavigationStack {
                    HistoryView()
                }
            }
            Tab("设置", systemImage: "gearshape.fill", value: 2) {
                NavigationStack(path: $settingsPath) {
                    SettingsView(vm: vm, path: $settingsPath)
                }
            }
        }
        .tint(.indigo)
        .task {
            vm.engine.start()
            // simctl regression hooks — not feature flags. The engine
            // already handles push/apply automatically via the 1Hz loop;
            // these just kick off an immediate first tick so test recipes
            // don't have to wait the full cadence before screenshotting.
            // UC_AUTO_SAVE stays a direct call: saving to Documents is a
            // discrete user action, not part of the auto-sync loop.
            let env = ProcessInfo.processInfo.environment
            if env["UC_AUTO_PUSH"] == "1" || env["UC_AUTO_APPLY"] == "1" {
                vm.engine.forceTickNow()
            }
            if env["UC_AUTO_SAVE"] == "1" {
                await vm.saveServerAttachment()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Refresh SSID before the engine reads `effectiveActiveConfig`
                // so a Wi-Fi flip while the app was backgrounded surfaces
                // on the first foreground tick instead of one cycle later.
                vm.ssidProvider.refresh()
                vm.engine.start()
            case .background: vm.engine.stop()
            case .inactive:   break  // brief — Notification Center pull-down etc; keep ticking
            @unknown default: break
            }
        }
    }
}

#Preview {
    ContentView(vm: .preview())
}
