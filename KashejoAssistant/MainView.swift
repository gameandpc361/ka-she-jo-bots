import SwiftUI
import PhotosUI
import WebKit
import UniformTypeIdentifiers
import UIKit
import ImageIO

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var bodyText = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var imageData: [Data] = []
    @State private var showFilePicker = false
    @State private var draftDisplayMode = UserDefaults.standard.string(forKey: "draftDisplayMode") ?? "list"
    @State private var scheduleEnabled = false
    @State private var scheduleDate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @State private var notice: String?
    @State private var duplicateCount = 1
    @State private var selectedDraftIDs = Set<UUID>()
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var logExportURL: URL?
    @State private var isLoadingPhotos = false
    @State private var showNewAccount = false
    @State private var accountName = ""
    @State private var accountURL = "https://kashejo.f5.si"
    @State private var accountNumber = ""
    @State private var shareSettings = true
    @State private var shareDrafts = false
    @State private var showDeleteAccountConfirm = false
    @State private var accountToDelete: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        TabView(selection: $model.activeTab) {
            compose.tabItem { Label("投稿", systemImage: "square.and.pencil") }.tag("compose")
            draftsTab.tabItem { Label("下書き", systemImage: "doc.text") }.tag("drafts")
            historyTab.tabItem { Label("履歴", systemImage: "clock") }.tag("history")
            webTab.tabItem { Label("Web", systemImage: "safari") }.tag("web")
            logsTab.tabItem { Label("ログ", systemImage: "list.bullet.rectangle") }.tag("logs")
            settingsTab.tabItem { Label("設定", systemImage: "gear") }.tag("settings")
            moreTab.tabItem { Label("More", systemImage: "ellipsis.circle") }.tag("more")
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.checkDuePosts(); Task { await model.checkSession() } } }
        .alert("お知らせ", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK") { notice = nil } } message: { Text(notice ?? "") }
        .sheet(isPresented: $showNewFolder) {
            NavigationStack { Form { TextField("フォルダ名", text: $newFolderName) }
                .navigationTitle("キューフォルダ作成")
                .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("閉じる") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } } }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { showNewFolder = false } }; ToolbarItem(placement: .confirmationAction) { Button("作成") { model.createFolder(name: newFolderName, parentID: model.selectedFolderID); newFolderName = ""; showNewFolder = false } } }
            }.presentationDetents([.medium])
        }
        .sheet(isPresented: Binding(get: { logExportURL != nil }, set: { if !$0 { logExportURL = nil } })) { if let url = logExportURL { ShareSheetView(activityItems: [url]) } }
        .sheet(isPresented: $showNewAccount) {
            NavigationStack {
                Form {
                    TextField("表示名", text: $accountName)
                    TextField("サイトURL", text: $accountURL).textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("アカウントID（任意）", text: $accountNumber)
                    Toggle("既定アカウントの設定を共有", isOn: $shareSettings)
                    Toggle("下書き・履歴・フォルダを共有", isOn: $shareDrafts)
                    Text("ログインセッションはアカウントごとに分離します。共有設定を有効にしてもCookieやログイン状態は共有されません。") .font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("アカウント追加")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { showNewAccount = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("追加") { model.addAccount(name: accountName, siteURL: accountURL, accountID: accountNumber, shareSettings: shareSettings, shareDrafts: shareDrafts); accountName = ""; accountNumber = ""; showNewAccount = false } }
                }
            }.presentationDetents([.medium, .large])
        }
        .confirmationDialog("このアカウントを削除しますか？", isPresented: $showDeleteAccountConfirm, titleVisibility: .visible) {
            Button("削除", role: .destructive) { if let id = accountToDelete { model.deleteAccount(id) } }
            Button("キャンセル", role: .cancel) { }
        } message: { Text("アカウント設定を削除します。WebKitのサイトデータがOSから即時消去されるとは限りません。") }
    }

    private var compose: some View {
        NavigationStack {
            Form {
                Section("投稿本文") {
                    TextEditor(text: $bodyText).focused($focused).frame(minHeight: 120)
                    HStack { Text("{random} は8文字、{random:数字} は指定文字数の英数字に置換").font(.caption).foregroundStyle(.secondary); Spacer(); Button("キーボードを閉じる") { focused = false; UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }.font(.caption) }
                }
                Section("画像") {
                    HStack {
                        PhotosPicker(selection: $photos, maxSelectionCount: model.maxImageCount, matching: .images) { Label("写真", systemImage: "photo") }.disabled(imageData.count >= model.maxImageCount)
                        Spacer()
                        Button { showFilePicker = true } label: { Label("ファイル", systemImage: "folder") }.disabled(imageData.count >= model.maxImageCount)
                    }
                    Text("\(imageData.count)枚選択済み ・ 最大\(model.maxImageCount)枚").foregroundStyle(.secondary)
                    if !imageData.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(Array(imageData.enumerated()), id: \.offset) { index, data in
                                    VStack(alignment: .leading, spacing: 4) {
                                        AnimatedImagePreview(data: data).frame(width: 112, height: 100).clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(imageDescription(data)).font(.caption2).lineLimit(1)
                                        Button("削除") { imageData.remove(at: index) }.font(.caption).tint(.red)
                                    }
                                }
                            }
                        }
                        Button("画像をすべてクリア", role: .destructive) { photos = []; imageData = [] }
                    }
                    Text("GIFは元データを保持して送信します。10MiB超過などは警告のみで、アプリ側では除外しません。サーバー側の制限により拒否される場合があります。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("下書きの一括作成") {
                    Stepper("作成数: \(duplicateCount)件（最大10件）", value: $duplicateCount, in: 1...10)
                    Button("同じ画像・本文で下書きを\(duplicateCount)件作成") {
                        model.duplicateDrafts(bodyTemplate: bodyText, images: imageData, count: duplicateCount)
                        notice = "\(duplicateCount)件の下書きを作成しました。{random} は各下書きごとに異なる文字列になります。"
                    }
                }
                Section("予約") {
                    Toggle("予約通知を設定", isOn: $scheduleEnabled)
                    if scheduleEnabled { DatePicker("予定時刻", selection: $scheduleDate, in: Date()..., displayedComponents: [.date,.hourAndMinute]) }
                    Text("iOSの制約により、アプリが停止中のWebフォーム投稿は保証されません。").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("下書き保存") { model.saveDraft(body: bodyText, images: imageData, scheduledAt: scheduleEnabled ? scheduleDate : nil); clearComposer(); notice = "下書きを保存しました" }
                    Button { Task { let ok = await model.post(PostItem(body: bodyText, images: imageData)); notice = ok ? "投稿しました" : (model.lastError ?? "投稿失敗") } } label: { if model.isSending { ProgressView() } else { Label("Webフォームで投稿", systemImage: "paperplane.fill") } }.disabled(model.isSending || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Kashejo Assistant")
            .scrollDismissesKeyboard(.interactively)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("閉じる") { focused = false; UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } } }
            .onChange(of: photos) { _, selected in
                guard !selected.isEmpty, !isLoadingPhotos else { return }
                isLoadingPhotos = true
                Task { @MainActor in
                    var loaded: [Data] = []
                    for photo in selected.prefix(model.maxImageCount) {
                        if let data = try? await photo.loadTransferable(type: Data.self), CGImageSourceCreateWithData(data as CFData, nil) != nil { loaded.append(data) }
                    }
                    let remaining = max(0, model.maxImageCount - imageData.count)
                    imageData.append(contentsOf: loaded.prefix(remaining))
                    photos = []
                    isLoadingPhotos = false
                    showImageWarnings()
                    model.log("PhotosPicker読込完了: loaded=\(min(loaded.count, remaining)) total=\(imageData.count)")
                }
            }
        }
        .sheet(isPresented: $showFilePicker) {
            ImageDocumentPicker(maxSelection: max(0, model.maxImageCount - imageData.count)) { result in
                switch result {
                case .success(let files):
                    imageData.append(contentsOf: files.prefix(max(0, model.maxImageCount - imageData.count)))
                    model.log("UIDocumentPicker読込完了: \(files.count)件")
                    showImageWarnings()
                case .failure(let error):
                    model.log("UIDocumentPicker失敗: \(error.localizedDescription)")
                    notice = "ファイルを読み込めませんでした: \(error.localizedDescription)"
                }
            }
            .ignoresSafeArea()
        }

    }
    private func clearComposer() { bodyText = ""; imageData = []; photos = []; scheduleEnabled = false; focused = false }
    private func imageDescription(_ data: Data) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let type: String
        if data.starts(with: Array("GIF8".utf8)) { type = "GIF" }
        else if data.starts(with: [0x89,0x50,0x4E,0x47]) { type = "PNG" }
        else if data.starts(with: [0xFF,0xD8,0xFF]) { type = "JPEG" }
        else { type = "画像" }
        return "\(type)・\(size)"
    }
    private func showImageWarnings() {
        let large = imageData.filter { $0.count > 10 * 1024 * 1024 }.count
        if large > 0 { notice = "10MiBを超える画像が\(large)枚あります。警告のみで選択は維持しますが、Kashejo側で拒否される可能性があります。" }
        if imageData.count > model.maxImageCount { imageData = Array(imageData.prefix(model.maxImageCount)); notice = "最大枚数を超えたため、先頭\(model.maxImageCount)枚を保持しました。" }
    }

    private var webTab: some View {
        NavigationStack {
            WebLoginView(webView: model.webView).navigationTitle("Kashejo Web").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItemGroup(placement: .topBarTrailing) { Button { model.openHomePage() } label: { Image(systemName: "house") }; Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }; Button { Task { await model.checkSession() } } label: { Image(systemName: "person.crop.circle.badge.checkmark") } } }
                .safeAreaInset(edge: .bottom) { VStack(alignment: .leading, spacing: 4) { Text(model.status).font(.caption).lineLimit(1); Text(model.currentWebURLString).font(.caption2).lineLimit(2).textSelection(.enabled); HStack { Spacer(); Button("URLコピー") { UIPasteboard.general.string = model.currentWebURLString }; Button("確認") { Task { await model.checkSession() } } } }.padding().background(.bar) }
        }.onAppear { if model.webView.url == nil { model.openHomePage() } }
    }

    private var draftsTab: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("フォルダ階層", systemImage: "folder.tree").font(.headline)
                        Spacer()
                        Button { showNewFolder = true } label: { Label("新規", systemImage: "folder.badge.plus") }
                    }
                    Picker("表示フォルダ", selection: Binding(get: { model.selectedFolderID ?? UUID.zero }, set: { model.selectedFolderID = $0 == UUID.zero ? nil : $0 })) {
                        Text("未分類").tag(UUID.zero)
                        ForEach(model.folders) { folder in Text(model.folderPath(folder)).tag(folder.id) }
                    }
                    if let selected = model.selectedFolderID, model.folders.contains(where: { $0.id == selected }) {
                        Button("選択フォルダと配下を削除", role: .destructive) { model.deleteFolder(selected); selectedDraftIDs.removeAll() }
                    }
                    Text("選択中: \(model.selectedFolderID.flatMap { id in model.folders.first(where: {$0.id == id}).map { model.folderPath($0) } } ?? "未分類") ・下書き \(model.drafts(in: model.selectedFolderID).count)件")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("1. フォルダ") }

                Section {
                    HStack { VStack(alignment: .leading, spacing: 4) {
                        Text(model.queueProgress).font(.headline)
                        if let next = model.queueNextPostAt {
                            Text("次の投稿まで：\(model.queueRemainingSeconds / 60)分 \(model.queueRemainingSeconds % 60)秒")
                            Text("予定時刻：\(next.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        } else { Text("投稿間隔：\(Int(model.queueIntervalSeconds))秒").font(.caption).foregroundStyle(.secondary) }
                    }; Spacer(); if model.queueProgress.contains("投稿中") { ProgressView() } }
                    Button("このフォルダを順番に投稿") { model.startQueue() }
                    if !selectedDraftIDs.isEmpty { Button("選択した\(selectedDraftIDs.count)件を順番に投稿") { model.startQueue(draftIDs: selectedDraftIDs) } }
                    Button("キュー停止", role: .destructive) { model.stopQueue() }
                    NavigationLink { QueueLogView(model: model) } label: { Label("連続投稿キューのログ（\(model.queueLogs.count)件）", systemImage: "text.alignleft") }
                    Text("最大 \(model.queueMaxCount)件。投稿処理はアプリを前面に置いている間に実行します。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("2. 連続投稿キュー") }

                Section {
                    HStack {
                        Text("下書き（\(model.drafts(in: model.selectedFolderID).count)件）").font(.headline)
                        Spacer()
                        Picker("表示", selection: $draftDisplayMode) {
                            Text("リスト").tag("list")
                            Text("カード").tag("cards")
                        }.pickerStyle(.segmented).frame(width: 150)
                        .onChange(of: draftDisplayMode) { _, v in UserDefaults.standard.set(v, forKey: "draftDisplayMode") }
                    }
                    HStack {
                        Button(selectedDraftIDs.count == model.drafts(in: model.selectedFolderID).count && !model.drafts(in: model.selectedFolderID).isEmpty ? "すべて解除" : "すべて選択") {
                            let ids = Set(model.drafts(in: model.selectedFolderID).map(\.id))
                            if selectedDraftIDs == ids { selectedDraftIDs.subtract(ids) } else { selectedDraftIDs.formUnion(ids) }
                        }
                        if !selectedDraftIDs.isEmpty { Button("削除（\(selectedDraftIDs.count)）", role: .destructive) { model.deleteDrafts(selectedDraftIDs); selectedDraftIDs.removeAll() } }
                    }
                    if !selectedDraftIDs.isEmpty {
                        Button("選択した下書きをこのフォルダへ移動") { model.moveDrafts(selectedDraftIDs, to: model.selectedFolderID); selectedDraftIDs.removeAll() }
                    }
                    let items = model.drafts(in: model.selectedFolderID)
                    if items.isEmpty { ContentUnavailableView("下書きはありません", systemImage: "doc.text") }
                    ForEach(items) { item in
                        DraftRow(item: item, selected: selectedDraftIDs.contains(item.id), card: draftDisplayMode == "cards", onSelect: {
                            if selectedDraftIDs.contains(item.id) { selectedDraftIDs.remove(item.id) } else { selectedDraftIDs.insert(item.id) }
                        }, onPost: { Task { let ok = await model.post(item); notice = ok ? "投稿しました" : (model.lastError ?? "失敗") } }, onDelete: { model.deleteDraft(item) })
                    }
                } header: { Text("3. 下書き一覧") }
            }
            .navigationTitle("下書き・キュー")
        }
    }

    private var historyTab: some View {
        NavigationStack {
            List {
                if model.history.isEmpty { ContentUnavailableView("履歴はありません", systemImage: "clock") }
                ForEach(model.history) { h in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(h.body).lineLimit(3)
                        Text("\(h.date.formatted(date: .numeric, time: .shortened)) ・画像 \(h.imageCount)枚").font(.caption).foregroundStyle(.secondary)
                        HStack {
                        if let url = URL(string: h.resultURL) {
                            Button("投稿を開く") {
                                if model.openHistoryInApp { model.webView.load(URLRequest(url: url)); model.activeTab = "web" }
                                else { UIApplication.shared.open(url) }
                            }
                        }
                        Spacer()
                        Button("削除", role: .destructive) { model.deleteHistory(h.id) }
                        }
                    }.swipeActions { Button("削除", role: .destructive) { model.deleteHistory(h.id) } }
                }
                if !model.history.isEmpty { Button("履歴をすべて削除", role: .destructive) { model.deleteAllHistory() } }
            }.navigationTitle("投稿履歴")
        }
    }

    private var logsTab: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("状態", value: model.status)
                    LabeledContent("WebView", value: model.webView.url?.path ?? "未読込")
                    Button("ログイン確認") { Task { await model.checkSession() } }
                    Button("ログをコピー") { UIPasteboard.general.string = model.logs.reversed().joined(separator: "\n") }
                    Button("ログをエクスポート") { logExportURL = model.makeLogExport() }
                    Button("ログ消去", role: .destructive) { model.clearLogs() }
                }
                Section("診断ログ（最大1000行）") { ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
            }.navigationTitle("診断ログ")
        }
    }

    private var settingsTab: some View {
        NavigationStack {
            Form {
                Section("接続") {
                    TextField("サイトURL", text: $model.siteBaseURL).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    TextField("アカウントID", text: $model.accountID).keyboardType(.numberPad)
                    Button("Web画面からアカウントIDを自動取得") { Task { await model.detectAccountIDFromWebPage() } }
                    Text("APIは使用せず、現在のWebView内のURLとリンクからID候補を読み取ります。プロフィール/自分の投稿画面で実行してください。").font(.footnote).foregroundStyle(.secondary)
                    Button("トップページを開く") { model.openHomePage() }
                    LabeledContent("現在のWebView URL") { Text(model.currentWebURLString).font(.caption).textSelection(.enabled).multilineTextAlignment(.trailing) }
                    Button("現在のURLをコピー") { UIPasteboard.general.string = model.currentWebURLString }
                    Text("投稿はWebView内の実際のフォームを使用し、APIエンドポイントには送信しません。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("WebView / User-Agent") {
                    Text("現在のUser-Agent")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.webView.customUserAgent ?? "iOS標準（WKWebView既定）")
                        .font(.caption2).textSelection(.enabled)
                    TextField("カスタムUser-Agent（空欄で標準）", text: $model.customUserAgent, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("標準User-Agentに戻す") { model.customUserAgent = ""; model.webView.reload() }
                    Button("User-Agentを適用して再読み込み") { model.applyUserAgent(); model.webView.reload() }
                    Text("User-Agentの変更はWebサイトの表示や互換性に影響する場合があります。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("キュー") {
                    HStack {
                        Text("投稿間隔")
                        Spacer()
                        TextField("秒", value: Binding(get: { Int(model.queueIntervalSeconds) }, set: { model.queueIntervalSeconds = Double(min(max($0, 5), 3600)) }), format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100)
                        Text("秒")
                    }
                    Slider(value: $model.queueIntervalSeconds, in: 5...3600, step: 1)
                    HStack {
                        Text("1回の最大件数")
                        Spacer()
                        TextField("件", value: Binding(get: { model.queueMaxCount }, set: { model.queueMaxCount = min(max($0, 1), 50) }), format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100)
                        Text("件")
                    }
                    Slider(value: Binding(get: { Double(model.queueMaxCount) }, set: { model.queueMaxCount = Int($0) }), in: 1...50, step: 1)
                }
                Section("画像") {
                    HStack {
                        Text("最大枚数")
                        Spacer()
                        TextField("枚", value: Binding(get: { model.maxImageCount }, set: { model.maxImageCount = min(max($0, 1), 20) }), format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100)
                        Text("枚")
                    }
                    Slider(value: Binding(get: { Double(model.maxImageCount) }, set: { model.maxImageCount = Int($0) }), in: 1...20, step: 1)
                    Text("10MiB超過は警告のみ。GIF/PNG/JPEG等の元データをできるだけ保持します。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("履歴の開き方") {
                    Picker("投稿を開く", selection: $model.openHistoryInApp) { Text("アプリ内WebView").tag(true); Text("外部ブラウザ（iOSの既定）").tag(false) }
                    Text("外部ブラウザはiOSで設定されている既定のブラウザが開きます。ブラウザの選択変更はiOSの設定で行ってください。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("ログの範囲とプライバシー") {
                    Text("画面遷移、HTTPナビゲーション応答、フォーム送信のURL/メソッド/ステータス/所要時間/応答プレビューを記録します。Cookie・CSRF・パスワード等は記録対象から除外またはマスクします。").font(.footnote)
                    Text("WKWebViewの全サブリソース通信を完全に傍受・保存する機能ではありません。秘密情報を含む完全な通信ダンプは安全上提供しません。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("バックグラウンドとLive Activity") {
                    Text("Live Activityはキュー進捗表示です。表示自体が投稿処理を継続させるわけではありません。BGTaskSchedulerは実行時刻を保証せず、WebKitフォーム送信はアプリが前面にあるときに行います。").font(.footnote)
                }
                Section("状態") { Text(model.status); if let e = model.lastError { Text(e).foregroundStyle(.red) } }
            }.navigationTitle("設定")
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("閉じる") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } } }
        }
    }
    private var moreTab: some View {
        NavigationStack {
            Form {
                Section("アカウント / インスタンス") {
                    Picker("現在のアカウント", selection: Binding(get: { model.activeProfileID }, set: { model.switchAccount($0) })) {
                        ForEach(model.profiles) { profile in Text(profile.name + (profile.isDefault ? "（既定）" : "")).tag(profile.id) }
                    }
                    Button { showNewAccount = true } label: { Label("アカウントを追加", systemImage: "person.badge.plus") }
                    if let current = model.profiles.first(where: { $0.id == model.activeProfileID }), !current.isDefault {
                        Button("このアカウントを削除", role: .destructive) { accountToDelete = current.id; showDeleteAccountConfirm = true }
                    }
                    Text("アカウントごとにWebKitログイン領域を分離します。下書き・履歴・フォルダの共有は追加時に設定できます。") .font(.footnote).foregroundStyle(.secondary)
                }
                Section("情報") {
                    LabeledContent("アプリ", value: "Kashejo Assistant")
                    LabeledContent("バージョン", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未設定")
                    LabeledContent("ビルド", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未設定")
                    NavigationLink { SystemInfoView() } label: { Label("システム情報", systemImage: "cpu") }
                    Link(destination: URL(string: "https://github.com/gameandpc361/ka-she-jo-bots")!) { Label("GitHub リポジトリ", systemImage: "link") }
                }
            }
            .navigationTitle("More")
        }
    }
}

struct DraftRow: View {
    let item: PostItem; let selected: Bool; let card: Bool
    let onSelect: () -> Void; let onPost: () -> Void; let onDelete: () -> Void
    var body: some View {
        Group {
            if card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Button(action: onSelect) { Image(systemName: selected ? "checkmark.circle.fill" : "circle") }; Spacer(); Text(item.createdAt.formatted(date: .numeric, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Text(item.body.isEmpty ? "（本文なし）" : item.body).lineLimit(5)
                    if !item.images.isEmpty { ScrollView(.horizontal) { HStack { ForEach(Array(item.images.prefix(5).enumerated()), id: \.offset) { _, data in AnimatedImagePreview(data: data).frame(width: 100, height: 82).clipShape(RoundedRectangle(cornerRadius: 8)) } } } }
                    Text("画像 \(item.images.count)枚").font(.caption).foregroundStyle(.secondary)
                    HStack { Button("投稿", action: onPost).buttonStyle(.borderedProminent); Button("削除", role: .destructive, action: onDelete).buttonStyle(.bordered) }
                }.padding(10).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Button(action: onSelect) { Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.body.isEmpty ? "（本文なし）" : item.body).lineLimit(2)
                        Text("画像 \(item.images.count)枚 ・ \(item.createdAt.formatted(date: .numeric, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        HStack { Button("投稿", action: onPost); Button("削除", role: .destructive, action: onDelete) }.buttonStyle(.bordered).font(.caption)
                    }
                }
            }
        }
    }
}

struct QueueLogView: View {
    @ObservedObject var model: AppModel
    var body: some View { List { if model.queueLogs.isEmpty { ContentUnavailableView("キューログはありません", systemImage: "text.alignleft") }; ForEach(Array(model.queueLogs.enumerated()), id: \.offset) { _, line in Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }.navigationTitle("キューログ") }
}

struct ImageDocumentPicker: UIViewControllerRepresentable {
    let maxSelection: Int
    let completion: (Result<[Data], Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.allowsMultipleSelection = maxSelection > 1
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<[Data], Error>) -> Void
        init(completion: @escaping (Result<[Data], Error>) -> Void) { self.completion = completion }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(.success([])) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            do {
                var loaded: [Data] = []
                for url in urls {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    var coordinationError: NSError?
                    var readError: Error?
                    var data: Data?
                    let coordinator = NSFileCoordinator(filePresenter: nil)
                    coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { safeURL in
                        do { data = try Data(contentsOf: safeURL) } catch { readError = error }
                    }
                    if let coordinationError { throw coordinationError }
                    if let readError { throw readError }
                    guard let bytes = data, CGImageSourceCreateWithData(bytes as CFData, nil) != nil else { throw AppError.message("画像データとして読み取れないファイルがあります: \(url.lastPathComponent)") }
                    loaded.append(bytes)
                }
                completion(.success(loaded))
            } catch { completion(.failure(error)) }
        }
    }
}

struct WebLoginView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

struct AnimatedImagePreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(); view.contentMode = .scaleAspectFit; view.clipsToBounds = true; view.backgroundColor = UIColor.secondarySystemBackground; return view
    }
    func updateUIView(_ uiView: UIImageView, context: Context) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { uiView.image = UIImage(data: data); return }
        let count = min(CGImageSourceGetCount(source), 40)
        guard count > 1 else { uiView.image = UIImage(data: data); return }
        var frames: [UIImage] = []
        var duration: Double = 0
        for index in 0..<count {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += max(0.02, delay)
        }
        uiView.image = frames.count > 1 ? UIImage.animatedImage(with: frames, duration: max(duration, 0.1)) : UIImage(data: data)
    }
}

struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: activityItems, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

private extension UUID {
    static var zero: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
}
