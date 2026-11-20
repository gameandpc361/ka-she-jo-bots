import Foundation
import Combine
import WebKit
import PhotosUI
import UIKit
import UserNotifications

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
private struct StoreData: Codable {
    var drafts: [PostItem]
    var history: [HistoryItem]
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return "不明なエラー"
    }
}

@MainActor
final class AppModel: ObservableObject, WKNavigationDelegate {
    @Published var webView: WKWebView
    @Published var drafts: [PostItem] = []
    @Published var history: [HistoryItem] = []
    @Published var status = "未ログイン"
    @Published var isSending = false
    @Published var lastError: String?
    @Published var logs: [String] = []
    @Published var activeTab = "web"
    @Published var isCheckingSession = false
    @Published var siteBaseURL: String {
        didSet { UserDefaults.standard.set(siteBaseURL, forKey: "siteBaseURL") }
    }
    @Published var accountID: String {
        didSet { UserDefaults.standard.set(accountID, forKey: "accountID") }
    }
    @Published var queueIntervalSeconds: Double {
        didSet { UserDefaults.standard.set(queueIntervalSeconds, forKey: "queueIntervalSeconds") }
    }
    @Published var queueMaxCount: Int {
        didSet { UserDefaults.standard.set(queueMaxCount, forKey: "queueMaxCount") }
    }
    @Published var maxImageCount: Int {
        didSet { UserDefaults.standard.set(maxImageCount, forKey: "maxImageCount") }
    }
    private var queueTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        siteBaseURL = defaults.string(forKey: "siteBaseURL") ?? "https://kashejo.f5.si"
        accountID = defaults.string(forKey: "accountID") ?? "135"
        queueIntervalSeconds = defaults.object(forKey: "queueIntervalSeconds") as? Double ?? 15
        queueMaxCount = defaults.object(forKey: "queueMaxCount") as? Int ?? 10
        maxImageCount = defaults.object(forKey: "maxImageCount") as? Int ?? 8
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        loadStore()
        logs = UserDefaults.standard.stringArray(forKey: "diagnosticLogs") ?? []
        log("アプリ起動。WebViewセッションを初期化")
        webView.load(URLRequest(url: normalizedBaseURL ?? URL(string: "https://kashejo.f5.si")!))
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    var normalizedBaseURL: URL? {
        let trimmed = siteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              components.host != nil else { return nil }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
    }

    func openHomePage() {
        guard let url = normalizedBaseURL else {
            lastError = "サイトURLが正しくありません。"
            log("トップページ表示失敗: URL不正")
            return
        }
        activeTab = "web"
        log("トップページを開く: \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    func checkSession() async {
        guard !isCheckingSession else { return }
        isCheckingSession = true
        defer { isCheckingSession = false }
        status = "ログイン確認中…"
        log("ログイン状態確認: GET /api/v1/me")
        do {
            guard webView.url?.host == normalizedBaseURL?.host else {
                status = "Kashejoページ待機中"
                lastError = "Kashejoのページに戻ってからログイン状態を確認してください。"
                log("ログイン確認を保留: 現在のWebViewはKashejoのホストではありません")
                return
            }
            let result = try await webView.callAsyncJavaScript("""
            const r = await fetch('/api/v1/me', {credentials:'same-origin', headers:{'Accept':'application/json'}});
            const t = await r.text();
            let parsed = null; try { parsed = JSON.parse(t); } catch (_) {}
            const authenticated = !!(parsed && !parsed.error && (parsed.user || parsed.id || parsed.handle || parsed.authenticated === true || parsed.me));
            return {status:r.status, ok:r.ok, authenticated, isJSON:!!parsed, body:parsed ? JSON.stringify(parsed).slice(0,1200) : t.slice(0,500), url:location.href};
            """, arguments: [:], in: nil, contentWorld: .page)
            guard let data = result as? [String: Any] else {
                status = "確認不能"
                lastError = "ログイン確認応答の形式が不正です。"
                log("ログイン確認失敗: 応答型が辞書ではない")
                return
            }
            let code = data["status"] as? Int ?? 0
            let body = data["body"] as? String ?? ""
            if code == 200 && (data["authenticated"] as? Bool == true) {
                status = "ログイン済み"
                lastError = nil
                log("ログイン確認成功: HTTP 200 / ユーザー情報あり")
            } else if code == 401 || code == 403 || (code == 200 && data["authenticated"] as? Bool == false) {
                status = "未ログイン"
                lastError = "KashejoのWebタブでログインしてください。"
                log("ログイン確認: HTTP \(code)。未認証")
            } else {
                status = "確認不能（HTTP \(code)）"
                lastError = "ログイン状態を判定できません。サイトを開き直して再確認してください。"
                log("ログイン確認: HTTP \(code)。JSON応答: \(data["isJSON"] as? Bool == true)")
            }
        } catch {
            status = "確認エラー"
            lastError = error.localizedDescription
            log("ログイン確認例外: \(error.localizedDescription)")
        }
    }

    func log(_ message: String) {
        let line = "\(Date().formatted(date: .numeric, time: .standard))  \(message)"
        logs.insert(line, at: 0)
        if logs.count > 300 { logs = Array(logs.prefix(300)) }
        UserDefaults.standard.set(logs, forKey: "diagnosticLogs")
    }

    func clearLogs() {
        logs.removeAll()
        UserDefaults.standard.removeObject(forKey: "diagnosticLogs")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("WebView読込完了: \(webView.url?.host ?? "unknown")\(webView.url?.path ?? "")")
        Task { await checkSession() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("WebView読込失敗: \(error.localizedDescription)")
        lastError = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("WebView遷移失敗: \(error.localizedDescription)")
        lastError = error.localizedDescription
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            log("HTTP応答: \(response.statusCode) \(response.url?.host ?? "")\(response.url?.path ?? "")")
        }
        decisionHandler(.allow)
    }

    func saveDraft(body: String, images: [Data], scheduledAt: Date?) {
        let item = PostItem(body: body, images: images, scheduledAt: scheduledAt)
        drafts.insert(item, at: 0)
        persist()
        if let date = scheduledAt { scheduleReminder(for: item, at: date) }
    }

    func deleteDraft(_ item: PostItem) {
        drafts.removeAll { $0.id == item.id }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [item.id.uuidString])
        persist()
    }

    func post(_ item: PostItem) async -> Bool {
        guard !isSending else { return false }
        isSending = true
        defer { isSending = false }
        lastError = nil
        status = "投稿準備中…"
        log("投稿開始: 本文\(item.body.count)文字 / 画像\(item.images.count)枚")
        do {
            // PromiseをevaluateJavaScriptへ返す旧実装はWKWebViewでunsupported typeになる。
            // callAsyncJavaScriptで非同期処理を待ち、Foundation互換の辞書を返す。
            let args: [String: Any] = ["body": item.body, "images": item.images.map { $0.base64EncodedString() }, "imageCount": item.images.count]
            let result = try await webView.callAsyncJavaScript("""
            const me = await fetch('/api/v1/me', {credentials:'same-origin', headers:{'Accept':'application/json'}});
            const meText = await me.text(); let meData = null; try { meData = JSON.parse(meText); } catch (_) {}
            const authenticated = !!(meData && !meData.error && (meData.user || meData.id || meData.handle || meData.authenticated === true || meData.me));
            if (me.status === 401 || me.status === 403 || (me.ok && !authenticated)) return {ok:false, stage:'auth', status:me.status, error:'ログイン状態を確認できません。WebタブでKashejoにログインし、ログイン確認を実行してください。'};
            if (!me.ok) return {ok:false, stage:'auth-check', status:me.status, error:'ログイン確認APIがHTTP '+me.status+'を返しました。'};
            if (imageCount > 0) {
              const forms = Array.from(document.forms);
              const form = forms.find(f => f.querySelector('[name="csrf"]') && f.querySelector('[name="body"]'));
              if (!form) return {ok:false, stage:'image-form', status:0, error:'画像投稿用フォームが現在のWebページにありません。Webタブで実際の投稿フォームを開いてください。画像投稿APIは未確認のため、画像を無視して投稿することはしません。'};
              const fd = new FormData(form); fd.set('body', body); fd.delete('images');
              for (let i=0; i<images.length; i++) {
                const raw = atob(images[i]); const bytes = new Uint8Array(raw.length);
                for (let j=0; j<raw.length; j++) bytes[j] = raw.charCodeAt(j);
                const file = new File([new Blob([bytes], {type:'image/jpeg'})], `photo-${i+1}.jpg`, {type:'image/jpeg'});
                fd.append('images', file);
                const altName = `alt_${i}`; if (fd.has(altName)) fd.set(altName, ''); else fd.append(altName, '');
              }
              const response = await fetch(form.getAttribute('action') || location.href, {method:'POST', body:fd, credentials:'same-origin', redirect:'follow'});
              const finalPath = new URL(response.url).pathname;
              const success = response.ok && /\/posts\/\d+/.test(finalPath);
              const responseText = success ? '' : (await response.text()).slice(0,500);
              return {ok:success, stage:'image-post', status:response.status, url:response.url, error:success ? '' : (responseText || '投稿完了URLを確認できませんでした')};
            }
            const response = await fetch('/api/v1/posts', {method:'POST', credentials:'same-origin', headers:{'Content-Type':'application/json','Accept':'application/json'}, body:JSON.stringify({body:body})});
            const text = await response.text();
            let parsed = null; try { parsed = JSON.parse(text); } catch (_) {}
            const postID = parsed && (parsed.id || (parsed.post && parsed.post.id));
            const success = response.ok && !!parsed && !parsed.error && !!postID;
            return {ok:success, stage:'text-post', status:response.status, url:(parsed && (parsed.url || (parsed.post && parsed.post.url))) || '', error:success ? '' : (parsed && parsed.error ? String(parsed.error) : (response.ok ? '投稿IDを含む成功応答を確認できませんでした' : text.slice(0,500)))};
            """, arguments: args, in: nil, contentWorld: .page)
            guard let object = result as? [String: Any] else {
                throw AppError.message("投稿応答の型が不正です。診断ログを確認してください。")
            }
            let stage = object["stage"] as? String ?? "unknown"
            let code = object["status"] as? Int ?? 0
            log("投稿応答: stage=\(stage), HTTP=\(code)")
            if object["ok"] as? Bool == true {
                let rawURL = object["url"] as? String ?? ""
                let resolvedURL = URL(string: rawURL, relativeTo: normalizedBaseURL)?.absoluteURL.absoluteString ?? rawURL
                history.insert(HistoryItem(body: item.body, resultURL: resolvedURL, imageCount: item.images.count), at: 0)
                drafts.removeAll { $0.id == item.id }
                persist()
                status = "投稿成功"
                log("投稿成功として記録。URL: \(resolvedURL)")
                return true
            }
            let message = object["error"] as? String ?? "投稿に失敗しました"
            lastError = message
            status = stage == "auth" ? "未ログイン" : "投稿失敗"
            log("投稿失敗: \(message)")
            return false
        } catch {
            lastError = error.localizedDescription
            status = "投稿失敗"
            log("投稿例外: \(error.localizedDescription)")
            return false
        }
    }

    func startQueue() {
        guard queueTask == nil else { return }
        let batch = Array(drafts.prefix(max(1, min(queueMaxCount, 50))))
        guard !batch.isEmpty else { return }
        queueTask = Task {
            for (index, item) in batch.enumerated() {
                if Task.isCancelled { break }
                if !(await post(item)) { break }
                if index < batch.count - 1 { try? await Task.sleep(for: .seconds(max(1, queueIntervalSeconds))) }
            }
            queueTask = nil
        }
    }
    func stopQueue() { queueTask?.cancel(); queueTask = nil }

    func checkDuePosts() {
        let due = drafts.filter { ($0.scheduledAt ?? .distantFuture) <= Date() }
        guard !due.isEmpty, !isSending else { return }
        Task {
            for item in due {
                if !(await post(item)) { break }
            }
        }
    }

    private func scheduleReminder(for item: PostItem, at date: Date) {
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Kashejoの予約投稿"
        content.body = "アプリを開くと、予約投稿を確認・実行します。"
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    private var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kashejo-data.json")
    }
    private func loadStore() {
        do {
            let data = try Data(contentsOf: storeURL)
            let store = try JSONDecoder().decode(StoreData.self, from: data)
            drafts = store.drafts
            history = store.history
        } catch { }
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(StoreData(drafts: drafts, history: history))
            try data.write(to: storeURL, options: .atomic)
        } catch { lastError = "保存失敗: \(error.localizedDescription)"; log("ローカル保存失敗: \(error.localizedDescription)") }
    }
}
