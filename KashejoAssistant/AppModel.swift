import Foundation
import Combine
import WebKit
import UIKit
import UserNotifications
import ActivityKit
import BackgroundTasks

struct PostItem: Identifiable, Codable {
    var id = UUID()
    var body: String
    var images: [Data]
    var createdAt = Date()
    var scheduledAt: Date? = nil
}
struct HistoryItem: Identifiable, Codable {
    var id = UUID()
    var body: String
    var date = Date()
    var resultURL: String
    var imageCount: Int
}
private struct StoreData: Codable { var drafts: [PostItem]; var history: [HistoryItem] }
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return "不明なエラー" }
}

@MainActor
final class AppModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var webView: WKWebView
    @Published var drafts: [PostItem] = []
    @Published var history: [HistoryItem] = []
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
    @Published var queueProgress = "待機中"
    private var queueTask: Task<Void, Never>?
    private var liveActivity: Activity<KashejoQueueAttributes>?

    override init() {
        let d = UserDefaults.standard
        siteBaseURL = d.string(forKey: "siteBaseURL") ?? "https://kashejo.f5.si"
        accountID = d.string(forKey: "accountID") ?? "135"
        queueIntervalSeconds = d.object(forKey: "queueIntervalSeconds") as? Double ?? 15
        queueMaxCount = d.object(forKey: "queueMaxCount") as? Int ?? 10
        maxImageCount = d.object(forKey: "maxImageCount") as? Int ?? 8
        let config = WKWebViewConfiguration(); config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        loadStore()
        logs = d.stringArray(forKey: "diagnosticLogs") ?? []
        webView.load(URLRequest(url: normalizedBaseURL ?? URL(string: "https://kashejo.f5.si")!))
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        log("起動。WebKit標準セッションを使用")
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

    // Authentication is inferred only from visible Web UI markers. No /api/* endpoint is called.
    func checkSession() async {
        guard !isCheckingSession else { return }
        isCheckingSession = true; defer { isCheckingSession = false }
        guard webView.url?.host == normalizedBaseURL?.host else { status = "Kashejoページ待機中"; return }
        status = "Webログイン状態を確認中…"
        do {
            let js = """
            (() => {
              const text = (document.body?.innerText || '').toLowerCase();
              const loginForm = Array.from(document.forms).some(f => /login|sign.?in/i.test((f.action||'')+' '+(f.innerText||'')) || !!f.querySelector('input[type=password]'));
              const logoutLink = Array.from(document.querySelectorAll('a,button')).some(e => /logout|log out|ログアウト|サインアウト/i.test((e.innerText||'')+' '+(e.getAttribute('aria-label')||'')));
              const profileLink = Array.from(document.querySelectorAll('a')).some(a => /account|profile|設定|プロフィール|アカウント/i.test((a.innerText||'')+' '+(a.getAttribute('href')||'')));
              return {loginForm, logoutLink, profileLink, title:document.title, url:location.href};
            })()
            """
            let result = try await webView.callAsyncJavaScript("return " + js, arguments: [:], in: nil, contentWorld: .page)
            guard let d = result as? [String: Any] else { status = "確認不能"; return }
            if d["logoutLink"] as? Bool == true || d["profileLink"] as? Bool == true {
                status = "ログイン済み（Web画面から判定）"; lastError = nil
            } else if d["loginForm"] as? Bool == true {
                status = "未ログイン"; lastError = "Webタブでログインしてください。"
            } else { status = "判定不能（画面マーカーなし）"; lastError = "Kashejoのログイン後ページを表示して再確認してください。" }
            log("ログイン状態: \(status)")
        } catch { status = "確認エラー"; lastError = error.localizedDescription; log("ログイン確認エラー: \(error.localizedDescription)") }
    }

    // Uses the actual page form, its action and hidden CSRF field. No API route or spoofed identity.
    func post(_ item: PostItem) async -> Bool {
        guard !isSending else { return false }
        guard webView.url?.host == normalizedBaseURL?.host else { lastError = "WebタブでKashejoを開いてください"; return false }
        isSending = true; defer { isSending = false }
        lastError = nil; status = "Webフォーム送信中…"
        do {
            let args: [String: Any] = ["bodyText": item.body, "imageBase64": item.images.map { $0.base64EncodedString() }, "accountID": accountID]
            let js = """
            const postBody = bodyText;
            const imagesData = imageBase64;
            const account = String(accountID || '');
            const forms = Array.from(document.forms);
            const form = forms.find(f => f.querySelector('[name="csrf"]') && f.querySelector('[name="body"]'));
            if (!form) return {ok:false, stage:'form-not-found', status:0, error:'このページに投稿フォームがありません。WebタブでKashejoの通常の投稿画面を開いてから再実行してください。'};
            const bodyField = form.querySelector('[name="body"]');
            if (!bodyField) return {ok:false, stage:'body-missing', status:0, error:'投稿本文欄が見つかりません。'};
            const action = new URL(form.getAttribute('action') || location.href, location.href);
            if (action.origin !== location.origin) return {ok:false, stage:'origin-check', status:0, error:'投稿フォームの送信先が現在のサイトと異なるため中止しました。'};
            const fd = new FormData(form);
            fd.set('body', postBody);
            fd.delete('images');
            for (let i=0; i<imagesData.length; i++) {
              const raw = atob(imagesData[i]); const bytes = new Uint8Array(raw.length);
              for (let j=0; j<raw.length; j++) bytes[j] = raw.charCodeAt(j);
              fd.append('images', new File([bytes], `image-${i+1}.jpg`, {type:'image/jpeg'}));
              const altKey = `alt_${i}`;
              if (fd.has(altKey)) fd.set(altKey, ''); else fd.append(altKey, '');
            }
            const response = await fetch(action.href, {method:(form.method||'POST').toUpperCase(), body:fd, credentials:'same-origin', redirect:'follow'});
            const finalURL = response.url || action.href;
            const p = new URL(finalURL).pathname.split('/').filter(Boolean);
            const tail = p[p.length-1] || '';
            const successPath = p[p.length-2] === 'posts' && /^\\d+$/.test(tail);
            const html = successPath ? '' : (await response.text()).slice(0,700);
            return {ok:response.ok && successPath, stage:'web-form', status:response.status, url:finalURL, error:response.ok && successPath ? '' : (html || '投稿完了ページを確認できませんでした')};
            """
            let result = try await webView.callAsyncJavaScript(js, arguments: args, in: nil, contentWorld: .page)
            guard let d = result as? [String: Any] else { throw AppError.message("投稿応答の形式が不正です") }
            let code = d["status"] as? Int ?? 0
            log("Webフォーム結果: HTTP \(code), stage=\(d["stage"] as? String ?? "unknown")")
            guard d["ok"] as? Bool == true else { lastError = d["error"] as? String ?? "投稿に失敗しました"; status = "投稿失敗"; log(lastError!); return false }
            let raw = d["url"] as? String ?? ""
            let resolved = URL(string: raw, relativeTo: normalizedBaseURL)?.absoluteURL.absoluteString ?? raw
            history.insert(HistoryItem(body: item.body, resultURL: resolved, imageCount: item.images.count), at: 0)
            drafts.removeAll { $0.id == item.id }; persist(); status = "投稿成功"; log("投稿成功を履歴に保存")
            return true
        } catch { lastError = error.localizedDescription; status = "投稿失敗"; log("投稿例外: \(error.localizedDescription)"); return false }
    }

    func saveDraft(body: String, images: [Data], scheduledAt: Date?) {
        let item = PostItem(body: body, images: images, scheduledAt: scheduledAt); drafts.insert(item, at: 0); persist()
        if let date = scheduledAt { scheduleReminder(for: item, at: date) }
    }
    func deleteDraft(_ item: PostItem) { drafts.removeAll { $0.id == item.id }; UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [item.id.uuidString]); persist() }

    func startQueue() {
        guard queueTask == nil else { return }
        let batch = Array(drafts.prefix(max(1, min(queueMaxCount, 50))))
        guard !batch.isEmpty else { return }
        beginLiveActivity(total: batch.count)
        queueTask = Task {
            for (index, item) in batch.enumerated() {
                if Task.isCancelled { break }
                queueProgress = "投稿中 \(index+1)/\(batch.count)"
                await updateLiveActivity(completed: index, total: batch.count, status: queueProgress, nextAt: nil)
                if !(await post(item)) { queueProgress = "失敗：\(index+1)/\(batch.count)"; break }
                await updateLiveActivity(completed: index+1, total: batch.count, status: "完了 \(index+1)/\(batch.count)", nextAt: nil)
                if index < batch.count-1 {
                    let next = Date().addingTimeInterval(queueIntervalSeconds)
                    await updateLiveActivity(completed: index+1, total: batch.count, status: "次の投稿を待機中", nextAt: next)
                    try? await Task.sleep(for: .seconds(max(1, queueIntervalSeconds)))
                }
            }
            if !Task.isCancelled { queueProgress = "キュー完了" }
            await endLiveActivity(finalStatus: queueProgress)
            queueTask = nil
        }
    }
    func stopQueue() { queueTask?.cancel(); queueTask = nil; queueProgress = "停止"; Task { await endLiveActivity(finalStatus: "停止") } }
    func checkDuePosts() {
        let due = drafts.filter { ($0.scheduledAt ?? .distantFuture) <= Date() }
        guard !due.isEmpty, !isSending else { return }
        // WebKit cannot be relied on to execute while the app is suspended. Resume only when active.
        Task { for item in due { if !(await post(item)) { break } } }
    }
    private func beginLiveActivity(total: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { log("Live Activityは設定で無効") ; return }
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
        let c = UNMutableNotificationContent(); c.title = "Kashejoの予約投稿"; c.body = "アプリを開くと予約投稿を確認します。iOSの制約により自動実行は保証されません。"
        let dc = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute], from: date)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id.uuidString, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)))
        let request = BGAppRefreshTaskRequest(identifier: "jp.example.KashejoAssistant.queue-refresh"); request.earliestBeginDate = date
        try? BGTaskScheduler.shared.submit(request)
    }
    func log(_ message: String) { let line = "\(Date().formatted(date: .numeric, time: .standard))  \(message)"; logs.insert(line, at: 0); if logs.count > 300 { logs = Array(logs.prefix(300)) }; UserDefaults.standard.set(logs, forKey: "diagnosticLogs") }
    func clearLogs() { logs.removeAll(); UserDefaults.standard.removeObject(forKey: "diagnosticLogs") }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { log("WebView読込完了: \(webView.url?.host ?? "unknown")\(webView.url?.path ?? "")"); Task { await checkSession() } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { log("WebView読込失敗: \(error.localizedDescription)"); lastError = error.localizedDescription }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { log("WebView遷移失敗: \(error.localizedDescription)"); lastError = error.localizedDescription }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) { if let r = navigationResponse.response as? HTTPURLResponse { log("HTTP \(r.statusCode) \(r.url?.host ?? "")\(r.url?.path ?? "")") }; decisionHandler(.allow) }
    private var storeURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("kashejo-data.json") }
    private func loadStore() { guard let data = try? Data(contentsOf: storeURL), let store = try? JSONDecoder().decode(StoreData.self, from: data) else { return }; drafts = store.drafts; history = store.history }
    private func persist() { do { try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(StoreData(drafts: drafts, history: history)).write(to: storeURL, options: .atomic) } catch { lastError = "保存失敗: \(error.localizedDescription)"; log("ローカル保存失敗") } }
}
