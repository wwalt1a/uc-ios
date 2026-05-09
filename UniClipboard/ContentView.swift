import SwiftUI

struct ContentView: View {
    private let store: SettingsStore

    @State private var servers: ServerConfigList
    @State private var appSettings: AppSettings
    @State private var selection: Int

    init(store: SettingsStore = SettingsStore()) {
        self.store = store

        let bootServers: ServerConfigList =
            ProcessInfo.processInfo.environment["UC_FRESH"] == "1"
            ? ServerConfigList()
            : store.loadServers()

        _servers = State(initialValue: bootServers)
        _appSettings = State(initialValue: store.loadAppSettings())
        _selection = State(initialValue: Self.initialTab)
    }

    private static var initialTab: Int {
        guard let i = ProcessInfo.processInfo.environment["UC_INIT_TAB"].flatMap(Int.init) else {
            return 0
        }
        return max(0, min(2, i))
    }

    var body: some View {
        rootContent
            .onChange(of: servers) { _, newValue in
                store.saveServers(newValue)
            }
            .onChange(of: appSettings) { _, newValue in
                store.saveAppSettings(newValue)
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if servers.configs.isEmpty {
            SetupFlowView(servers: $servers) {
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
                    HomeView(
                        servers: $servers,
                        serverLatest: Mock.serverLatest,
                        serverLastSyncedAt: Mock.serverLastSyncedAt,
                        deviceClipboard: Mock.deviceClipboard
                    )
                }
            }
            Tab("历史", systemImage: "clock.fill", value: 1) {
                NavigationStack {
                    HistoryView()
                }
            }
            Tab("设置", systemImage: "gearshape.fill", value: 2) {
                NavigationStack {
                    SettingsView(servers: $servers, appSettings: $appSettings)
                }
            }
        }
        .tint(.indigo)
    }
}

#Preview {
    ContentView()
}
