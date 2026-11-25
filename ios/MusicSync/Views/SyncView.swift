import MusicSyncCore
import SwiftUI

struct SyncView: View {
    @Environment(ServerSettings.self) private var settings
    @Environment(SyncEngine.self) private var sync
    @Environment(LibraryStore.self) private var store
    @Environment(AudioPlayer.self) private var player
    @State private var showSetup = false
    @State private var showRemoveAll = false
    @State private var usedBytes: Int64 = 0

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                if settings.isConfigured { syncSection }
                librarySection
                helpSection
            }
            .navigationTitle("同期")
            .sheet(isPresented: $showSetup) { ServerSetupView() }
            .task(id: store.tracksById.count) { usedBytes = await Task.detached { Paths.usedBytes() }.value }
            .confirmationDialog(confirmTitle, isPresented: confirmBinding, titleVisibility: .visible) {
                Button("削除して同期", role: .destructive) { sync.start(confirmDeletions: true) }
                Button("キャンセル", role: .cancel) { sync.dismissResult() }
            } message: {
                Text("PC 側の音楽フォルダが正しく接続されているか確認してください。")
            }
            .confirmationDialog("この iPhone の音楽をすべて削除しますか？", isPresented: $showRemoveAll,
                                titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) {
                    player.stop()
                    store.removeAllMusic()
                }
            } message: {
                Text("PC の音楽は削除されません。プレイリストは残り、次回の同期で曲が戻ります。")
            }
        }
    }

    private var confirmTitle: String {
        if case .needsConfirmation(let n) = sync.phase { return "\(n) 曲を iPhone から削除します" }
        return ""
    }

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: { if case .needsConfirmation = sync.phase { return true } else { return false } },
            set: { if !$0, case .needsConfirmation = sync.phase { sync.dismissResult() } }
        )
    }

    private var serverSection: some View {
        Section("サーバー (PC)") {
            if settings.isConfigured {
                LabeledContent("名前", value: settings.serverName.isEmpty ? "—" : settings.serverName)
                LabeledContent("アドレス", value: settings.displayAddress)
                Button("サーバーを変更") { showSetup = true }.disabled(sync.isBusy)
            } else {
                Text("PC で「musicsync serve 音楽フォルダ」を実行し、表示されたアドレスとトークンを入力してください。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("サーバーを設定") { showSetup = true }
            }
        }
    }

    private var syncSection: some View {
        Section {
            switch sync.phase {
            case .connecting:
                HStack { ProgressView(); Text("接続中…").padding(.leading, 8) }
            case .syncing:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: sync.progress)
                    Text(sync.totalCount > 0
                         ? "\(sync.completedCount) / \(sync.totalCount) 曲  (\(Formatters.bytes(sync.completedBytes)) / \(Formatters.bytes(sync.totalBytes)))"
                         : "準備中…")
                        .font(.caption.monospacedDigit())
                    if !sync.currentTitle.isEmpty {
                        Text(sync.currentTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Button("中止", role: .destructive) { sync.cancel() }
            case .finished(let summary):
                Label(summary.text, systemImage: summary.failed > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(summary.failed > 0 ? .orange : .green)
                syncButton
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
                syncButton
            case .idle, .needsConfirmation:
                syncButton
            }
        } footer: {
            if let last = store.lastSync {
                Text("最終同期: \(last.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }

    private var syncButton: some View {
        Button {
            sync.start()
        } label: {
            Label("今すぐ同期", systemImage: "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity)
                .bold()
        }
        .disabled(sync.isBusy)
    }

    private var librarySection: some View {
        Section("この iPhone") {
            LabeledContent("曲", value: "\(store.tracksById.count) 曲")
            LabeledContent("アルバム", value: "\(store.albums.count)")
            LabeledContent("プレイリスト", value: "\(store.playlists.count)")
            LabeledContent("使用容量", value: Formatters.bytes(usedBytes))
            if !store.isEmpty {
                Button("この iPhone の音楽をすべて削除", role: .destructive) { showRemoveAll = true }
                    .disabled(sync.isBusy)
            }
        }
    }

    private var helpSection: some View {
        Section("ヒント") {
            Text("同期は差分のみ転送します。PC で追加・削除した曲、取得したアルバムアート、作成したプレイリストがまとめて反映されます。")
            Text("iPhone で作成・編集したプレイリストは PC にも自動で送られます。")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

struct ServerSetupView: View {
    @Environment(ServerSettings.self) private var settings
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var token = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.10:8765", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                    SecureField("トークン（10 文字）", text: $token)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("PC に表示されたアドレスとトークン")
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Text("接続して保存").bold()
                            Spacer()
                            if checking { ProgressView() }
                        }
                    }
                    .disabled(checking || address.isEmpty || token.isEmpty)
                }
                if settings.isConfigured {
                    Section {
                        Button("サーバー設定を削除", role: .destructive) {
                            settings.clear()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("サーバー設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            }
            .onAppear {
                if address.isEmpty { address = settings.displayAddress }
                if token.isEmpty { token = settings.token }
            }
        }
    }

    private func connect() async {
        error = nil
        checking = true
        defer { checking = false }
        do {
            let url = try ServerAddress.parse(address)
            let client = APIClient(baseURL: url, token: token)
            let info = try await client.ping()
            try await client.verifyToken()
            settings.save(baseURL: url, token: ServerAddress.normalizeToken(token), serverName: info.serverName)
            dismiss()
            sync.start()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
