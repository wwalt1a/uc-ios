import SwiftUI

struct SettingsView: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        List {
            Section("同步") {
                NavigationLink {
                    ServersListView(servers: $vm.servers)
                } label: {
                    HStack {
                        Label("服务器列表", systemImage: "server.rack")
                        Spacer()
                        Text("\(vm.servers.configs.count) 个")
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $vm.appSettings.trustInsecureCert) {
                    Label("允许不安全证书", systemImage: "lock.open")
                }
            }

            Section {
                Toggle(isOn: $vm.appSettings.autoApplyServerChanges) {
                    Label("自动写入本机剪贴板", systemImage: "doc.on.clipboard")
                }
            } header: {
                Text("行为")
            } footer: {
                Text("开启后，服务器有新内容时会立即覆盖本机剪贴板；关闭则只在主页高亮提示，不修改剪贴板。")
                    .font(.caption)
            }

            Section {
                Toggle(isOn: $vm.appSettings.autoCheckUpdate) {
                    Label("启动时检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                NavigationLink {
                    Form {
                        TextField("下载子目录", text: $vm.appSettings.downloadRelativePath)
                            .textInputAutocapitalization(.never)
                    }
                    .navigationTitle("下载路径")
                } label: {
                    HStack {
                        Label("下载路径", systemImage: "folder")
                        Spacer()
                        Text(vm.appSettings.downloadRelativePath.isEmpty ? "默认" : vm.appSettings.downloadRelativePath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Section("诊断") {
                NavigationLink {
                    LogsPlaceholderView()
                } label: {
                    Label("日志", systemImage: "doc.text.magnifyingglass")
                }
                NavigationLink {
                    AboutView(appSettings: $vm.appSettings)
                } label: {
                    Label("关于", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("设置")
    }
}

// MARK: - Servers list

private struct ServersListView: View {
    @Binding var servers: ServerConfigList

    var body: some View {
        List {
            Section {
                ForEach($servers.configs) { $server in
                    NavigationLink {
                        ServerEditView(
                            server: $server,
                            existingNames: existingNames(excludingId: server.id)
                        )
                    } label: {
                        ServerRow(
                            server: server,
                            isActive: server.id == servers.activeConfigId
                        )
                    }
                    .swipeActions {
                        if server.id != servers.activeConfigId {
                            Button {
                                servers.activeConfigId = server.id
                            } label: {
                                Label("设为活动", systemImage: "checkmark.circle")
                            }
                            .tint(.green)
                        }
                    }
                }
            } footer: {
                Text("自动切换：连接到匹配 SSID 时自动切换到该服务器。")
                    .font(.caption)
            }

            Section {
                Button {
                    // add new server flow
                } label: {
                    Label("添加服务器", systemImage: "plus.circle.fill")
                }
                Button {
                    // import flow
                } label: {
                    Label("从文件导入", systemImage: "square.and.arrow.down")
                }
            }
        }
        .navigationTitle("服务器列表")
    }

    private func existingNames(excludingId: String) -> Set<String> {
        Set(servers.configs.lazy.filter { $0.id != excludingId }.compactMap(\.name))
    }
}

private struct ServerRow: View {
    let server: ServerConfig
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: isActive ? "checkmark" : "server.rack")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isActive ? Color.green : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayLabel)
                    .font(.callout.weight(.semibold))
                Text(server.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !server.autoSwitchWifiNames.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "wifi")
                            .font(.caption2)
                        Text(server.autoSwitchWifiNames.joined(separator: ", "))
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Server edit

private struct ServerEditView: View {
    @Binding var server: ServerConfig
    let existingNames: Set<String>

    /// Local edit buffer for the name so we can normalize on commit
    /// (trim → empty becomes nil, conflicts get a numeric suffix nudge).
    @State private var nameDraft: String = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("便于辨识的名称", text: $nameDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        nameDraft = ServerNameGenerator.generate(avoiding: existingNames)
                    } label: {
                        Image(systemName: "shuffle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("换一个名称")
                }
            } header: {
                Text("名称")
            } footer: {
                Text("将显示在剪贴板顶栏。留空会用服务器地址替代。")
            }

            Section("连接") {
                LabeledContent("URL", value: server.url)
                LabeledContent {
                    Text(server.username)
                } label: {
                    Text("用户名")
                }
                LabeledContent {
                    Text(String(repeating: "•", count: server.password.count))
                } label: {
                    Text("密码")
                }
            }

            Section("自动切换") {
                if server.autoSwitchWifiNames.isEmpty {
                    Text("无").foregroundStyle(.secondary)
                } else {
                    ForEach(server.autoSwitchWifiNames, id: \.self) { ssid in
                        Label(ssid, systemImage: "wifi")
                    }
                }
            }

            Section {
                Button("测试连接") {}
            }
        }
        .navigationTitle(server.displayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            nameDraft = server.name ?? ""
        }
        .onChange(of: nameDraft) { _, _ in
            // Commit on every keystroke — onDisappear is unreliable when
            // SwiftUI rebuilds the navigation stack mid-edit.
            let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            server.name = trimmed.isEmpty ? nil : trimmed
        }
    }
}

private struct LogsPlaceholderView: View {
    var body: some View {
        List {
            ForEach(0..<8) { i in
                HStack {
                    Text("INFO")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(.green)
                        .frame(width: 44, alignment: .leading)
                    Text("Pulled clipboard from server (\(i * 7 + 12) min ago)")
                        .font(.caption.monospaced())
                        .lineLimit(2)
                }
            }
        }
        .navigationTitle("日志")
    }
}

private struct AboutView: View {
    @Binding var appSettings: AppSettings
    var body: some View {
        List {
            Section {
                LabeledContent("版本", value: "UniClipboard 1.0 (1)")
                LabeledContent("协议", value: "兼容 SyncClipboard v1")
            }
            if let v = appSettings.ignoredVersion {
                Section("忽略的版本") {
                    HStack {
                        Text(v)
                        Spacer()
                        Button("清除") { appSettings.ignoredVersion = nil }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("关于")
    }
}

#Preview {
    NavigationStack {
        SettingsView(vm: .preview())
    }
    .tint(.indigo)
}
