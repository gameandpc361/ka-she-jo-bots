import Foundation
import Combine
import WebKit
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import ActivityKit
import BackgroundTasks

struct PostItem: Identifiable, Codable {
    var id = UUID()
    var body: String
    var images: [Data]
    var createdAt = Date()
    var scheduledAt: Date? = nil
    var folderID: UUID? = nil

    enum CodingKeys: String, CodingKey { case id, body, images, createdAt, scheduledAt, folderID }
    init(id: UUID = UUID(), body: String, images: [Data], createdAt: Date = Date(), scheduledAt: Date? = nil, folderID: UUID? = nil) {
        self.id = id; self.body = body; self.images = images; self.createdAt = createdAt; self.scheduledAt = scheduledAt; self.folderID = folderID
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        images = try c.decodeIfPresent([Data].self, forKey: .images) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        scheduledAt = try c.decodeIfPresent(Date.self, forKey: .scheduledAt)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
    }
}
struct QueueFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
}
struct HistoryItem: Identifiable, Codable {
    var id = UUID()
    var body: String
    var date = Date()
    var resultURL: String
    var imageCount: Int
}
private struct StoreData: Codable {
    var drafts: [PostItem]
    var history: [HistoryItem]
    var folders: [QueueFolder]
    init(drafts: [PostItem] = [], history: [HistoryItem] = [], folders: [QueueFolder] = []) { self.drafts = drafts; self.history = history; self.folders = folders }
    enum CodingKeys: String, CodingKey { case drafts, history, folders }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drafts = try c.decodeIfPresent([PostItem].self, forKey: .drafts) ?? []
        history = try c.decodeIfPresent([HistoryItem].self, forKey: .history) ?? []
        folders = try c.decodeIfPresent([QueueFolder].self, forKey: .folders) ?? []
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return "不明なエラー" }
}

@MainActor
final class AppModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var webView: WKWebView
    @Published var drafts: [PostItem] = []
    @Published var history: [HistoryItem] = []
    @Published var folders: [QueueFolder] = []
    @Published var selectedFolderID: UUID?
    @Published var status = "ログイン状態未確認"
    @Published var isSending = false
    @Published var lastError: String?
    @Published var logs: [String] = []
    @Published var activeTab = "web"
    @Published var isCheckingSession = false
    @Published var siteBaseURL: String { didSet { UserDefaults.standard.set(siteBaseURL, forKey: "siteBaseURL") } }
    @Published var accountID: String { didSet { UserDefaults.standard.set(accountID, forKey: "accountID") } }
    @Published var queueIntervalSeconds: Double { didSet { UserDefaults.standard.set(queueIntervalSeconds, forKey: "queueIntervalSeconds") } }
    @Published var queueMaxCount: Int { didSet { UserDefaults.standard.set(queueMaxCount, forKey: "queueMaxCount") } }
    @Published var maxImageCount: Int { didSet { UserDefaults.standard.set(maxImageCount, forKey: "maxImageCount") } }
    @Published var openHistoryInApp: Bool { didSet { UserDefaults.standard.set(openHistoryInApp, forKey: "openHistoryInApp") } }
    @Published var queueProgress = "待機中"
    private var queueTask: Task<Void, Never>?
    private var liveActivity: Activity<KashejoQueueAttributes>?

    override init() {
        let d = UserDefaults.standard
        siteBaseURL = d.string(forKey: "siteBaseURL") ?? "https://kashejo.f5.si"
        accountID = d.string(forKey: "accountID") ?? "135"
        queueIntervalSeconds = max(60, min(3600, d.object(forKey: "queueIntervalSeconds") as? Double ?? 60))
        queueMaxCount = d.object(forKey: "queueMaxCount") as? Int ?? 10
        maxImageCount = d.object(forKey: "maxImageCount") as? Int ?? 8
        openHistoryInApp = d.object(forKey: "openHistoryInApp") as? Bool ?? true
        let config = WKWebViewConfiguration(); config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        loadStore()
        logs = d.stringArray(forKey: "diagnosticLogs") ?? []
        webView.load(URLRequest(url: normalizedBaseURL ?? URL(string: "https://kashejo.f5.si")!))
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        log("起動。WKWebView標準セッションを使用")
    }

    var normalizedBaseURL: URL? {
        let raw = siteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(), ["https", "http"].contains(scheme), c.host != nil else { return nil }
        return c.url
    }
    func openHomePage() {
        guard let url = normalizedBaseURL else { lastError = "サイトURLが正しくありません"; return }
        activeTab = "web"; webView.load(URLRequest(url: url)); log("トップページを開く")
    }

    func checkSession() async {
        guard !isCheckingSession else { return }
        isCheckingSession = true; defer { isCheckingSession = false }
        guard webView.url?.host == normalizedBaseURL?.host else { status = "Kashejoページ待機中"; return }
        status = "Webログイン状態を確認中…"
        do {
            let js = """
            (() => {
              const loginForm = Array.from(document.forms).some(f => /login|sign.?in/i.test((f.action||'')+' '+(f.innerText||'')) || !!f.querySelector('input[type=password]'));
              const logoutLink = Array.from(document.querySelectorAll('a,button')).some(e => /logout|log out|ログアウト|サインアウト/i.test((e.innerText||'')+' '+(e.getAttribute('aria-label')||'')));
              const profileLink = Array.from(document.querySelectorAll('a')).some(a => /account|profile|設定|プロフィール|アカウント/i.test((a.innerText||'')+' '+(a.getAttribute('href')||'')));
              return {loginForm, logoutLink, profileLink, title:document.title, url:location.href};
            })()
            """
            let result = try await webView.callAsyncJavaScript("return " + js, arguments: [:], in: nil, contentWorld: .page)
            guard let d = result as? [String: Any] else { status = "確認不能"; return }
            if d["logoutLink"] as? Bool == true || d["profileLink"] as? Bool == true { status = "ログイン済み（Web画面から判定）"; lastError = nil }
            else if d["loginForm"] as? Bool == true { status = "未ログイン"; lastError = "Webタブでログインしてください。" }
            else { status = "判定不能（画面マーカーなし）"; lastError = "Kashejoのログイン後ページを表示して再確認してください。" }
            log("ログイン状態: \(status)")
        } catch { status = "確認エラー"; lastError = error.localizedDescription; log("ログイン確認エラー: \(error.localizedDescription)") }
    }

    private func imageType(_ data: Data) -> (mime: String, ext: String) {
        let b = [UInt8](data.prefix(16))
        if b.count >= 6, String(bytes: b[0..<6], encoding: .ascii)?.hasPrefix("GIF8") == true { return ("image/gif", "gif") }
        if b.count >= 8, Array(b[0..<8]) == [137,80,78,71,13,10,26,10] { return ("image/png", "png") }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return ("image/jpeg", "jpg") }
        if b.count >= 12, String(bytes: b[4..<8], encoding: .ascii) == "ftyp" { return ("image/heic", "heic") }
        if b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF", String(bytes: b[8..<12], encoding: .ascii) == "WEBP" { return ("image/webp", "webp") }
        return ("application/octet-stream", "bin")
    }

    func post(_ item: PostItem) async -> Bool {
        guard !isSending else { return false }
        guard webView.url?.host == normalizedBaseURL?.host else { lastError = "WebタブでKashejoを開いてください"; return false }
        isSending = true; defer { isSending = false }
        lastError = nil; status = "Webフォーム送信中…"
        do {
            let files: [[String: String]] = item.images.enumerated().map { i, data in
                let type = imageType(data)
                return ["base64": data.base64EncodedString(), "mime": type.mime, "filename": "kashejo-image-\(i+1).\(type.ext)"]
            }
            let args: [String: Any] = ["bodyText": item.body, "files": files]
            let js = """
            const forms = Array.from(document.forms);
            const form = forms.find(f => f.querySelector('[name="csrf"]') && f.querySelector('[name="body"]'));
            if (!form) return {ok:false, stage:'form-not-found', status:0, error:'このページに投稿フォームがありません。通常の投稿画面を開いてください。'};
            const action = new URL(form.getAttribute('action') || location.href, location.href);
            if (action.origin !== location.origin) return {ok:false, stage:'origin-check', status:0, error:'投稿フォームの送信先が異なるため中止しました。'};
            const fd = new FormData(form);
            fd.set('body', bodyText);
            fd.delete('images');
            for (const f of files) {
              const raw = atob(f.base64); const bytes = new Uint8Array(raw.length);
              for (let j=0; j<raw.length; j++) bytes[j] = raw.charCodeAt(j);
              fd.append('images', new File([bytes], f.filename, {type:f.mime}));
            }
            const method = (form.method || 'POST').toUpperCase();
            const started = performance.now();
            const response = await fetch(action.href, {method, body:fd, credentials:'same-origin', redirect:'follow'});
            const elapsed = Math.round(performance.now()-started);
            const finalURL = response.url || action.href;
            const p = new URL(finalURL).pathname.split('/').filter(Boolean);
            const tail = p[p.length-1] || '';
            const successPath = p[p.length-2] === 'posts' && /^\\d+$/.test(tail);
            const rawText = successPath ? '' : await response.clone().text();
            const safeText = rawText.replace(/(csrf|authenticity_token|password|cookie|authorization)[^\\n]{0,160}/ig, '$1=[REDACTED]').slice(0,1200);
            return {ok:response.ok && successPath, stage:'web-form', status:response.status, url:finalURL, elapsed, responseBytes:rawText.length, responsePreview:safeText, method, actionPath:new URL(action.href).pathname, fileCount:files.length, error:response.ok && successPath ? '' : (safeText || '投稿完了ページを確認できませんでした')};
            """
            let result = try await webView.callAsyncJavaScript(js, arguments: ["bodyText": item.body, "files": files], in: nil, contentWorld: .page)
            guard let d = result as? [String: Any] else { throw AppError.message("投稿応答の形式が不正です") }
            let code = d["status"] as? Int ?? 0
            log("送信詳細 method=\(d["method"] as? String ?? "POST") path=\(d["actionPath"] as? String ?? "?") HTTP=\(code) elapsed=\(d["elapsed"] ?? "?")ms images=\(d["fileCount"] ?? 0) responseBytes=\(d["responseBytes"] ?? 0)")
            if let preview = d["responsePreview"] as? String, !preview.isEmpty { log("応答プレビュー（先頭・機密語をマスク）: \(preview)") }
            guard d["ok"] as? Bool == true else { lastError = d["error"] as? String ?? "投稿に失敗しました"; status = "投稿失敗"; log("投稿失敗: \(lastError ?? "unknown")"); return false }
            let raw = d["url"] as? String ?? ""
            let resolved = URL(string: raw, relativeTo: normalizedBaseURL)?.absoluteURL.absoluteString ?? raw
            history.insert(HistoryItem(body: item.body, resultURL: resolved, imageCount: item.images.count), at: 0)
            drafts.removeAll { $0.id == item.id }; persist(); status = "投稿成功"; log("投稿成功。履歴に保存")
            return true
        } catch { lastError = error.localizedDescription; status = "投稿失敗"; log("投稿例外: \(error.localizedDescription)"); return false }
    }

    func saveDraft(body: String, images: [Data], scheduledAt: Date? = nil, folderID: UUID? = nil) {
        let item = PostItem(body: body, images: images, scheduledAt: scheduledAt, folderID: folderID ?? selectedFolderID)
        drafts.insert(item, at: 0); persist(); if let date = scheduledAt { scheduleReminder(for: item, at: date) }
        log("下書き保存 folder=\(item.folderID?.uuidString ?? "未分類") images=\(images.count)")
    }
    func duplicateDrafts(bodyTemplate: String, images: [Data], count: Int) {
        let safeCount = min(max(count, 1), 10)
        for _ in 0..<safeCount { saveDraft(body: expandRandomTokens(bodyTemplate), images: images, folderID: selectedFolderID) }
        log("下書きを\(safeCount)件作成（{random}展開済み）")
    }
    private func expandRandomTokens(_ input: String) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        return input.replacingOccurrences(of: "{random}", with: String((0..<8).compactMap { _ in alphabet.randomElement() }))
    }
    func createFolder(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let folder = QueueFolder(name: clean); folders.append(folder); selectedFolderID = folder.id; persist(); log("キューフォルダ作成: \(clean)")
    }
    func deleteDraft(_ item: PostItem) { drafts.removeAll { $0.id == item.id }; UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [item.id.uuidString]); persist() }
    func moveDrafts(_ ids: Set<UUID>, to folderID: UUID?) {
        for index in drafts.indices where ids.contains(drafts[index].id) { drafts[index].folderID = folderID }
        persist(); log("下書き\(ids.count)件をフォルダへ移動")
    }
    func drafts(in folder: UUID?) -> [PostItem] { drafts.filter { $0.folderID == folder } }

    func startQueue() {
        guard queueTask == nil else { return }
        let batch = Array(drafts(in: selectedFolderID).prefix(max(1, min(queueMaxCount, 10))))
        guard !batch.isEmpty else { queueProgress = "選択フォルダに下書きがありません"; return }
        beginLiveActivity(total: batch.count)
        queueTask = Task {
            for (index, item) in batch.enumerated() {
                if Task.isCancelled { break }
                queueProgress = "投稿中 \(index+1)/\(batch.count)"
                await updateLiveActivity(completed: index, total: batch.count, status: queueProgress, nextAt: nil)
                if !(await post(item)) { queueProgress = "失敗：\(index+1)/\(batch.count)"; break }
                await updateLiveActivity(completed: index+1, total: batch.count, status: "完了 \(index+1)/\(batch.count)", nextAt: nil)
                if index < batch.count-1 {
                    let interval = max(60, min(3600, queueIntervalSeconds))
                    let next = Date().addingTimeInterval(interval)
                    await updateLiveActivity(completed: index+1, total: batch.count, status: "次の投稿を待機中", nextAt: next)
                    do { try await Task.sleep(for: .seconds(interval)) } catch { break }
                }
            }
            if !Task.isCancelled && queueProgress.hasPrefix("投稿中") { queueProgress = "キュー完了" }
            await endLiveActivity(finalStatus: queueProgress); queueTask = nil
        }
    }
    func stopQueue() { queueTask?.cancel(); queueTask = nil; queueProgress = "停止"; Task { await endLiveActivity(finalStatus: "停止") }; log("キュー停止") }
    func checkDuePosts() {
        let due = drafts.filter { ($0.scheduledAt ?? .distantFuture) <= Date() }
        guard !due.isEmpty, !isSending else { return }
        log("予約期限到来: \(due.count)件。アプリ前面で処理を試行")
        Task { for item in due { if !(await post(item)) { break } } }
    }
    private func beginLiveActivity(total: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { log("Live Activityは設定で無効"); return }
        do { liveActivity = try Activity.request(attributes: KashejoQueueAttributes(title: "Kashejo 投稿キュー"), content: .init(state: .init(completed: 0, total: total, status: "準備中", nextAt: nil), staleDate: nil)) }
        catch { log("Live Activity開始失敗: \(error.localizedDescription)") }
    }
    private func updateLiveActivity(completed: Int, total: Int, status: String, nextAt: Date?) async {
        guard let activity = liveActivity else { return }
        await activity.update(.init(state: .init(completed: completed, total: total, status: status, nextAt: nextAt), staleDate: nil))
    }
    private func endLiveActivity(finalStatus: String) async {
        guard let activity = liveActivity else { return }
        await activity.end(.init(state: .init(completed: activity.content.state.completed, total: activity.content.state.total, status: finalStatus, nextAt: nil), staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(20)))
        liveActivity = nil
    }
    private func scheduleReminder(for item: PostItem, at date: Date) {
        guard date > Date() else { return }
        let c = UNMutableNotificationContent(); c.title = "Kashejoの予約投稿"; c.body = "アプリを開くと予約投稿を確認します。自動実行は保証されません。"
        let dc = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute], from: date)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id.uuidString, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)))
        let request = BGAppRefreshTaskRequest(identifier: "jp.example.KashejoAssistant.queue-refresh"); request.earliestBeginDate = date; try? BGTaskScheduler.shared.submit(request)
    }

    func log(_ message: String) {
        let safe = message.replacingOccurrences(of: #"(?i)(cookie|authorization|csrf|password|token)\s*[:=]\s*[^\s,;]+"#, with: "$1=[REDACTED]", options: .regularExpression)
        let line = "\(Date().formatted(date: .numeric, time: .standard))  \(safe)"
        logs.insert(line, at: 0); if logs.count > 1000 { logs = Array(logs.prefix(1000)) }; UserDefaults.standard.set(logs, forKey: "diagnosticLogs")
    }
    func clearLogs() { logs.removeAll(); UserDefaults.standard.removeObject(forKey: "diagnosticLogs") }
    func makeLogExport() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KashejoAssistant-Diagnostics-\(Int(Date().timeIntervalSince1970)).txt")
        let header = "Kashejo Assistant diagnostics\nGenerated: \(Date())\nNote: authentication secrets are intentionally excluded. WKWebView subresource traffic is not fully captured.\n\n"
        do { try (header + logs.reversed().joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8); log("ログを書き出し") ; return url } catch { lastError = error.localizedDescription; return nil }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { log("WebView読込完了: \(webView.url?.host ?? "unknown")\(webView.url?.path ?? "") title=\(webView.title ?? "")"); Task { await checkSession() } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { log("WebView読込失敗: \(error.localizedDescription)"); lastError = error.localizedDescription }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { log("WebView遷移失敗: \(error.localizedDescription)"); lastError = error.localizedDescription }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let r = navigationResponse.response as? HTTPURLResponse { log("Navigation HTTP \(r.statusCode) \(r.url?.host ?? "")\(r.url?.path ?? "") MIME=\(r.mimeType ?? "-") bytes=\(r.expectedContentLength)") }; decisionHandler(.allow)
    }
    private var storeURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("kashejo-data.json") }
    private func loadStore() { guard let data = try? Data(contentsOf: storeURL), let store = try? JSONDecoder().decode(StoreData.self, from: data) else { return }; drafts = store.drafts; history = store.history; folders = store.folders }
    private func persist() { do { try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(StoreData(drafts: drafts, history: history, folders: folders)).write(to: storeURL, options: .atomic) } catch { lastError = "保存失敗: \(error.localizedDescription)"; log("ローカル保存失敗") } }
}
