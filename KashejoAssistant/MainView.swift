import SwiftUI
import PhotosUI
import WebKit

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var bodyText = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var imageData: [Data] = []
    @State private var scheduleEnabled = false
    @State private var scheduleDate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @State private var notice: String?
    @FocusState private var focused: Bool

    var body: some View {
        TabView(selection: $model.activeTab) {
            compose.tabItem { Label("投稿", systemImage: "square.and.pencil") }.tag("compose")
            draftsTab.tabItem { Label("下書き", systemImage: "doc.text") }.tag("drafts")
            historyTab.tabItem { Label("履歴", systemImage: "clock") }.tag("history")
            webTab.tabItem { Label("Web", systemImage: "safari") }.tag("web")
            logsTab.tabItem { Label("ログ", systemImage: "list.bullet.rectangle") }.tag("logs")
            settingsTab.tabItem { Label("設定", systemImage: "gear") }.tag("settings")
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.checkDuePosts(); Task { await model.checkSession() } } }
        .alert("お知らせ", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK") { notice = nil } } message: { Text(notice ?? "") }
    }
    private var compose: some View {
        NavigationStack {
            Form {
                Section("投稿本文") { TextEditor(text: $bodyText).focused($focused).frame(minHeight: 120) }
                Section("画像") {
                    PhotosPicker(selection: $photos, maxSelectionCount: model.maxImageCount, matching: .images) { Label("写真を最大\(model.maxImageCount)枚選択", systemImage: "photo") }
                    Text("\(imageData.count)枚選択済み").foregroundStyle(.secondary)
                    if !imageData.isEmpty { Button("画像をクリア", role: .destructive) { photos = []; imageData = [] } }
                }
                Section("予約") {
                    Toggle("予約する", isOn: $scheduleEnabled)
                    if scheduleEnabled { DatePicker("投稿予定", selection: $scheduleDate, in: Date()..., displayedComponents: [.date,.hourAndMinute]) }
                    Text("予約時刻にアプリが実行可能な状態であれば処理を試みます。バックグラウンド実行は保証されません。").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("下書き保存") { model.saveDraft(body: bodyText, images: imageData, scheduledAt: scheduleEnabled ? scheduleDate : nil); clearComposer(); notice = "下書きを保存しました" }
                    Button { Task { let ok = await model.post(PostItem(body: bodyText, images: imageData)); notice = ok ? "投稿しました" : (model.lastError ?? "投稿失敗") } } label: { if model.isSending { ProgressView() } else { Label("Webフォームで投稿", systemImage: "paperplane.fill") } }.disabled(model.isSending || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Kashejo Assistant")
            .scrollDismissesKeyboard(.interactively)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("キーボードを閉じる") { focused = false } } }
            .task(id: photos) { var loaded: [Data] = []; for photo in photos { if let d = try? await photo.loadTransferable(type: Data.self), let image = UIImage(data: d), let jpeg = image.jpegData(compressionQuality: 0.8) { loaded.append(jpeg) } }; imageData = loaded }
        }
    }
    private func clearComposer() { bodyText = ""; imageData = []; photos = []; scheduleEnabled = false; focused = false }
    private var webTab: some View {
        NavigationStack {
            WebLoginView(webView: model.webView).navigationTitle("Kashejo Web").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItemGroup(placement: .topBarTrailing) { Button { model.openHomePage() } label: { Image(systemName: "house") }; Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }; Button { Task { await model.checkSession() } } label: { Image(systemName: "person.crop.circle.badge.checkmark") } } }
                .safeAreaInset(edge: .bottom) { HStack { Text(model.status).font(.caption).lineLimit(1); Spacer(); Button("確認") { Task { await model.checkSession() } } }.padding().background(.bar) }
        }.onAppear { if model.webView.url == nil { model.openHomePage() } }
    }
    private var draftsTab: some View {
        NavigationStack {
            List {
                if model.drafts.isEmpty { ContentUnavailableView("下書きはありません", systemImage: "doc.text") }
                ForEach(model.drafts) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.body).lineLimit(3)
                        Text("画像 \(item.images.count)枚 ・ \(item.scheduledAt?.formatted(date: .numeric, time: .shortened) ?? "未予約")").font(.caption).foregroundStyle(.secondary)
                        HStack { Button("投稿") { Task { let ok = await model.post(item); notice = ok ? "投稿しました" : (model.lastError ?? "失敗") } }; Button("削除", role: .destructive) { model.deleteDraft(item) } }.buttonStyle(.bordered)
                    }
                }
                Section("連続投稿") {
                    Text(model.queueProgress).font(.caption)
                    Button("下書きを順番に投稿") { model.startQueue() }
                    Button("キュー停止", role: .destructive) { model.stopQueue() }
                }
            }.navigationTitle("下書き・キュー")
        }
    }
    private var historyTab: some View {
        NavigationStack { List { if model.history.isEmpty { ContentUnavailableView("履歴はありません", systemImage: "clock") }; ForEach(model.history) { h in VStack(alignment: .leading, spacing: 5) { Text(h.body).lineLimit(3); Text("\(h.date.formatted(date: .numeric, time: .shortened)) ・画像 \(h.imageCount)枚").font(.caption).foregroundStyle(.secondary); if let url = URL(string: h.resultURL) { Link("投稿を開く", destination: url) } } } }.navigationTitle("投稿履歴") }
    }
    private var logsTab: some View {
        NavigationStack { List { Section { LabeledContent("状態", value: model.status); LabeledContent("WebView", value: model.webView.url?.path ?? "未読込"); Button("ログイン確認") { Task { await model.checkSession() } }; Button("ログをコピー") { UIPasteboard.general.string = model.logs.reversed().joined(separator: "\n") }; Button("ログ消去", role: .destructive) { model.clearLogs() } }; Section("診断ログ") { ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } } }.navigationTitle("診断ログ") }
    }
    private var settingsTab: some View {
        NavigationStack { Form {
            Section("接続") { TextField("サイトURL", text: $model.siteBaseURL).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled(); TextField("アカウントID（表示/確認用）", text: $model.accountID).keyboardType(.numberPad); Button("トップページを開く") { model.openHomePage() }; Text("投稿先はページ内の実際のフォームactionを使用します。アカウントIDから投稿URLを組み立てません。").font(.footnote).foregroundStyle(.secondary) }
            Section("キュー") { LabeledContent("間隔", value: "\(Int(model.queueIntervalSeconds))秒"); Slider(value: $model.queueIntervalSeconds, in: 5...300, step: 5); LabeledContent("最大件数", value: "\(model.queueMaxCount)件"); Slider(value: Binding(get: { Double(model.queueMaxCount) }, set: { model.queueMaxCount = Int($0) }), in: 1...50, step: 1) }
            Section("画像") { LabeledContent("最大枚数", value: "\(model.maxImageCount)枚"); Slider(value: Binding(get: { Double(model.maxImageCount) }, set: { model.maxImageCount = Int($0) }), in: 1...20, step: 1) }
            Section("バックグラウンドとLive Activity") { Text("Live Activityはキュー進捗を表示します。表示自体が投稿処理を継続させるわけではありません。iOSのBGTaskSchedulerは実行時刻を保証せず、WebKitフォーム送信はアプリが前面にあるときに行います。").font(.footnote) }
            Section("状態") { Text(model.status); if let e = model.lastError { Text(e).foregroundStyle(.red) } }
        }.navigationTitle("設定") }
    }
}
struct WebLoginView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
