import Foundation
import Combine
import WebKit
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import ActivityKit
import BackgroundTasks
import ImageIO
import CoreGraphics

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
    var parentID: UUID? = nil
    var createdAt = Date()
}

struct AccountProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var siteBaseURL: String
    var accountID: String
    var webStoreID: UUID = UUID()
    var queueIntervalSeconds: Double = 60
    var queueMaxCount: Int = 10
    var maxImageCount: Int = 8
    var openHistoryInApp: Bool = true
    var isDefault: Bool = false
    var shareSettingsWithDefault: Bool = false
    var shareDraftsWithDefault: Bool = false

    static func makeDefault() -> AccountProfile {
        AccountProfile(name: "デフォルト", siteBaseURL: "https://kashejo.f5.si", accountID: "135", isDefault: true)
    }
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
enum ImageMetadataRandomizer {
    enum MetadataError: LocalizedError {
        case invalidImage
        case unsupportedFormat
        case destinationCreationFailed
        case finalizationFailed
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "画像データを認識できません"
            case .unsupportedFormat: return "この画像形式のメタデータ付加には対応していません"
            case .destinationCreationFailed: return "画像のメタデータ書き込み先を作成できません"
            case .finalizationFailed: return "メタデータを書き込めませんでした"
            }
        }
    }

    static func addComment(_ comment: String, to data: Data) throws -> Data {
        guard !comment.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { throw MetadataError.invalidImage }
        let typeName = type as String

        // GIFはファイル末尾のTrailer直前にComment Extensionを挿入する。
        // 画像フレーム・圧縮データ・アニメーション時間を再エンコードせず、そのまま維持する。
        if typeName.lowercased().contains("gif") {
            return try addGIFComment(comment, to: data)
        }

        let supported = ["public.jpeg", "public.png", "public.heic", "public.heif", "public.tiff"]
        guard supported.contains(typeName) else { throw MetadataError.unsupportedFormat }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw MetadataError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, frameCount, nil) else {
            throw MetadataError.destinationCreationFailed
        }

        let sourceProperties = (CGImageSourceCopyProperties(source, nil) as? [String: Any]) ?? [:]
        var properties = sourceProperties
        if typeName == "public.png" {
            var png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any] ?? [:]
            png[kCGImagePropertyPNGDescription as String] = comment
            properties[kCGImagePropertyPNGDictionary as String] = png
        } else {
            var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            exif[kCGImagePropertyExifUserComment as String] = comment
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        // 画質劣化を抑え、全フレームを元の順番で保持する。
        properties[kCGImageDestinationLossyCompressionQuality as String] = 1.0
        for index in 0..<frameCount {
            CGImageDestinationAddImageFromSource(destination, source, index, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw MetadataError.finalizationFailed }
        return output as Data
    }

    private static func addGIFComment(_ comment: String, to data: Data) throws -> Data {
        guard data.count >= 14,
              let header = String(data: data.prefix(6), encoding: .ascii),
              header == "GIF87a" || header == "GIF89a",
              data.last == 0x3B else { throw MetadataError.invalidImage }
        let bytes = Array(comment.utf8)
        var extensionBytes = Data([0x21, 0xFE])
        var offset = 0
        while offset < bytes.count {
            let length = min(255, bytes.count - offset)
            extensionBytes.append(UInt8(length))
            extensionBytes.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        }
        extensionBytes.append(0x00)
        var result = Data(data.dropLast())
        result.append(extensionBytes)
        result.append(0x3B)
        return result
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return "不明なエラー" }
}

@MainActor
final class AppModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var webView: WKWebView
    @Published var profiles: [AccountProfile] = []
    @Published var activeProfileID: UUID
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
    @Published var siteBaseURL: String { didSet { UserDefaults.standard.set(siteBaseURL, forKey: "siteBaseURL"); syncActiveProfile() } }
    @Published var accountID: String { didSet { UserDefaults.standard.set(accountID, forKey: "accountID"); syncActiveProfile() } }
    @Published var queueIntervalSeconds: Double { didSet { UserDefaults.standard.set(queueIntervalSeconds, forKey: "queueIntervalSeconds"); syncActiveProfile() } }
    @Published var queueMaxCount: Int { didSet { UserDefaults.standard.set(queueMaxCount, forKey: "queueMaxCount"); syncActiveProfile() } }
    @Published var maxImageCount: Int { didSet { UserDefaults.standard.set(maxImageCount, forKey: "maxImageCount"); syncActiveProfile() } }
    @Published var openHistoryInApp: Bool { didSet { UserDefaults.standard.set(openHistoryInApp, forKey: "openHistoryInApp"); syncActiveProfile() } }
    @Published var queueProgress = "待機中"
    @Published var queueNextPostAt: Date?
    @Published var queueRemainingSeconds: Int = 0
    @Published var queueLogs: [String] = []
    @Published var customUserAgent: String = UserDefaults.standard.string(forKey: "customUserAgent") ?? "" { didSet { UserDefaults.standard.set(customUserAgent, forKey: "customUserAgent"); applyUserAgent() } }
    @Published var currentUserAgent: String = "Webページ読み込み後に取得します"
    @Published var imageMetadataRandomEnabled: Bool = UserDefaults.standard.bool(forKey: "imageMetadataRandomEnabled") {
        didSet { UserDefaults.standard.set(imageMetadataRandomEnabled, forKey: "imageMetadataRandomEnabled") }
    }
    @Published var imageMetadataRandomTemplate: String = UserDefaults.standard.string(forKey: "imageMetadataRandomTemplate") ?? "{random:16}" {
        didSet { UserDefaults.standard.set(imageMetadataRandomTemplate, forKey: "imageMetadataRandomTemplate") }
    }
    private var queueTask: Task<Void, Never>?
    private var liveActivity: Activity<KashejoQueueAttributes>?
    private var suppressProfileSync = false

    override init() {
        let d = UserDefaults.standard
        let decodedProfiles = (d.data(forKey: "accountProfiles")).flatMap { try? JSONDecoder().decode([AccountProfile].self, from: $0) } ?? []
        var initialProfiles = decodedProfiles
        if initialProfiles.isEmpty {
            var legacyDefault = AccountProfile.makeDefault()
            legacyDefault.siteBaseURL = d.string(forKey: "siteBaseURL") ?? legacyDefault.siteBaseURL
            legacyDefault.accountID = d.string(forKey: "accountID") ?? legacyDefault.accountID
            legacyDefault.queueIntervalSeconds = d.object(forKey: "queueIntervalSeconds") as? Double ?? legacyDefault.queueIntervalSeconds
            legacyDefault.queueMaxCount = d.object(forKey: "queueMaxCount") as? Int ?? legacyDefault.queueMaxCount
            legacyDefault.maxImageCount = d.object(forKey: "maxImageCount") as? Int ?? legacyDefault.maxImageCount
            legacyDefault.openHistoryInApp = d.object(forKey: "openHistoryInApp") as? Bool ?? legacyDefault.openHistoryInApp
            initialProfiles = [legacyDefault]
        }
        if !initialProfiles.contains(where: \.isDefault) { initialProfiles.insert(.makeDefault(), at: 0) }
        profiles = initialProfiles
        let requestedID = d.string(forKey: "activeProfileID").flatMap(UUID.init(uuidString:))
        let initialProfile = initialProfiles.first(where: { $0.id == requestedID }) ?? initialProfiles.first(where: \.isDefault)!
        activeProfileID = initialProfile.id
        let settingsProfile = initialProfile.shareSettingsWithDefault ? (initialProfiles.first(where: \.isDefault) ?? initialProfile) : initialProfile
        siteBaseURL = settingsProfile.siteBaseURL
        accountID = settingsProfile.accountID
        queueIntervalSeconds = max(5, min(3600, settingsProfile.queueIntervalSeconds))
        queueMaxCount = max(1, min(50, settingsProfile.queueMaxCount))
        maxImageCount = max(1, min(20, settingsProfile.maxImageCount))
        openHistoryInApp = settingsProfile.openHistoryInApp
        webView = Self.makeWebView(for: initialProfile)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        applyUserAgent()
        persistProfiles()
        loadStore()
        logs = d.stringArray(forKey: "diagnosticLogs") ?? []
        queueLogs = d.stringArray(forKey: "queueLogs") ?? []
        webView.load(URLRequest(url: normalizedBaseURL ?? URL(string: "https://kashejo.f5.si")!))
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        log("起動。WKWebView標準セッションを使用")
    }

    private static func makeWebView(for profile: AccountProfile) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if profile.isDefault { configuration.websiteDataStore = .default() }
        else if #available(iOS 17.0, *) { configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.webStoreID) }
        else { configuration.websiteDataStore = .default() }
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "accountProfiles") }
        UserDefaults.standard.set(activeProfileID.uuidString, forKey: "activeProfileID")
    }

    private func syncActiveProfile() {
        guard !suppressProfileSync, let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        profiles[index].siteBaseURL = siteBaseURL
        profiles[index].accountID = accountID
        profiles[index].queueIntervalSeconds = queueIntervalSeconds
        profiles[index].queueMaxCount = queueMaxCount
        profiles[index].maxImageCount = maxImageCount
        profiles[index].openHistoryInApp = openHistoryInApp
        if profiles[index].shareSettingsWithDefault, let defaultIndex = profiles.firstIndex(where: \.isDefault), defaultIndex != index {
            profiles[defaultIndex].queueIntervalSeconds = queueIntervalSeconds
            profiles[defaultIndex].queueMaxCount = queueMaxCount
            profiles[defaultIndex].maxImageCount = maxImageCount
            profiles[defaultIndex].openHistoryInApp = openHistoryInApp
        }
        persistProfiles()
    }

    func addAccount(name: String, siteURL: String, accountID: String, shareSettings: Bool, shareDrafts: Bool) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let url = URL(string: siteURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { lastError = "アカウント名またはサイトURLが不正です"; return }
        let base = profiles.first(where: \.isDefault) ?? profiles[0]
        let profile = AccountProfile(name: clean, siteBaseURL: siteURL, accountID: accountID, queueIntervalSeconds: shareSettings ? base.queueIntervalSeconds : queueIntervalSeconds, queueMaxCount: shareSettings ? base.queueMaxCount : queueMaxCount, maxImageCount: shareSettings ? base.maxImageCount : maxImageCount, openHistoryInApp: shareSettings ? base.openHistoryInApp : openHistoryInApp, shareSettingsWithDefault: shareSettings, shareDraftsWithDefault: shareDrafts)
        profiles.append(profile); persistProfiles(); log("アカウント追加: \(clean)")
    }

    func switchAccount(_ id: UUID) {
        guard id != activeProfileID, let profile = profiles.first(where: { $0.id == id }) else { return }
        stopQueue(); persist()
        suppressProfileSync = true
        activeProfileID = id
        let settings = profile.shareSettingsWithDefault ? (profiles.first(where: \.isDefault) ?? profile) : profile
        siteBaseURL = profile.siteBaseURL; accountID = profile.accountID
        queueIntervalSeconds = settings.queueIntervalSeconds; queueMaxCount = settings.queueMaxCount
        maxImageCount = settings.maxImageCount; openHistoryInApp = settings.openHistoryInApp
        let nextWebView = Self.makeWebView(for: profile)
        nextWebView.navigationDelegate = self; nextWebView.allowsBackForwardNavigationGestures = true
        webView = nextWebView; applyUserAgent()
        suppressProfileSync = false
        persistProfiles(); loadStore()
        if let url = normalizedBaseURL { webView.load(URLRequest(url: url)) }
        status = "アカウント切替: \(profile.name)"; log("アカウント切替: \(profile.name)")
    }

    func deleteAccount(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }), !profile.isDefault else { return }
        if activeProfileID == id { switchAccount(profiles.first(where: \.isDefault)!.id) }
        if #available(iOS 17.0, *) {
            WKWebsiteDataStore.remove(forIdentifier: profile.webStoreID) { [weak self] error in
                Task { @MainActor in self?.log(error == nil ? "WebKitデータ領域を削除: \(profile.name)" : "WebKitデータ領域削除失敗: \(error!.localizedDescription)") }
            }
        }
        profiles.removeAll { $0.id == id }; persistProfiles(); log("アカウント設定を削除: \(profile.name)")
    }

    func folderPath(_ folder: QueueFolder) -> String {
        var names = [folder.name]; var parent = folder.parentID; var visited = Set<UUID>()
        while let id = parent, !visited.contains(id), let item = folders.first(where: { $0.id == id }) { visited.insert(id); names.insert(item.name, at: 0); parent = item.parentID }
        return names.joined(separator: " / ")
    }

    func applyUserAgent() {
        let value = customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        webView.customUserAgent = value.isEmpty ? nil : value
        currentUserAgent = value.isEmpty ? "標準User-Agentを取得中…" : value
        log(value.isEmpty ? "User-Agent: iOS標準を使用" : "User-Agent: カスタム設定を適用")
        refreshCurrentUserAgent()
    }

    /// WKWebViewが実際にページへ送っているUser-AgentをJavaScript側から取得する。
    func refreshCurrentUserAgent() {
        guard webView.url != nil else {
            currentUserAgent = customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Webページ読み込み後に取得します" : customUserAgent
            return
        }
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let value = result as? String, !value.isEmpty {
                    self.currentUserAgent = value
                } else if let error {
                    self.currentUserAgent = "取得失敗: \(error.localizedDescription)"
                } else {
                    self.currentUserAgent = self.webView.customUserAgent ?? "取得できませんでした"
                }
            }
        }
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
            // Catch errors inside JavaScript so WKWebView returns the actual stage/message.
            let js = #"""
            try {
              const forms = Array.from(document.forms);
              const form = forms.find(f => f.querySelector('[name="csrf"]') && f.querySelector('[name="body"]'));
              if (!form) return {ok:false, stage:'form-not-found', status:0, error:'このページに投稿フォームがありません。Kashejoの通常投稿画面を開いてください。'};
              const action = new URL(form.getAttribute('action') || location.href, location.href);
              if (action.origin !== location.origin) return {ok:false, stage:'origin-check', status:0, error:'投稿フォームの送信先が異なるため中止しました。'};
              const method = (form.method || 'POST').toUpperCase();
              if (method !== 'POST') return {ok:false, stage:'method-check', status:0, error:'投稿フォームがPOSTではありません: '+method};
              const fd = new FormData(form);
              fd.set('body', bodyText);
              fd.delete('images');
              for (const f of files) {
                const raw = atob(f.base64); const bytes = new Uint8Array(raw.length);
                for (let j=0; j<raw.length; j++) bytes[j] = raw.charCodeAt(j);
                fd.append('images', new File([bytes], f.filename, {type:f.mime}));
              }
              const started = performance.now();
              const response = await fetch(action.href, {method:'POST', body:fd, credentials:'same-origin', redirect:'follow'});
              const elapsed = Math.round(performance.now()-started);
              const finalURL = response.url || action.href;
              const path = new URL(finalURL).pathname;
              const successPath = /\/posts\/\d+\/?$/.test(path);
              const rawText = successPath ? '' : await response.clone().text();
              const safeText = rawText.replace(/(csrf|authenticity_token|password|cookie|authorization)[^\n]{0,160}/ig, '$1=[REDACTED]').slice(0,1600);
              return {ok:response.ok && successPath, stage:'web-form-fetch', status:response.status, url:finalURL, elapsed, responseBytes:rawText.length, responsePreview:safeText, method, actionPath:new URL(action.href).pathname, fileCount:files.length, error:response.ok && successPath ? '' : (safeText || 'HTTP '+response.status+'。投稿完了ページを確認できませんでした')};
            } catch (e) {
              return {ok:false, stage:'javascript-catch', status:0, error:String(e && e.message || e), stack:String(e && e.stack || '').slice(0,1200), pageURL:location.href};
            }
            """#
            let result = try await webView.callAsyncJavaScript(js, arguments: ["bodyText": item.body, "files": files], in: nil, contentWorld: .page)
            guard let d = result as? [String: Any] else { throw AppError.message("投稿応答の形式が不正です。WebViewのURLと投稿フォームを確認してください。") }
            let code = d["status"] as? Int ?? 0
            let stage = d["stage"] as? String ?? "unknown"
            log("送信詳細 stage=\(stage) method=\(d["method"] as? String ?? "-") path=\(d["actionPath"] as? String ?? "?") HTTP=\(code) elapsed=\(d["elapsed"] ?? "?")ms images=\(d["fileCount"] ?? 0)")
            if let stack = d["stack"] as? String, !stack.isEmpty { log("JavaScript stack: \(stack)") }
            if let preview = d["responsePreview"] as? String, !preview.isEmpty { log("応答プレビュー（先頭・機密語をマスク）: \(preview)") }
            guard d["ok"] as? Bool == true else { lastError = d["error"] as? String ?? "投稿に失敗しました"; status = "投稿失敗"; log("投稿失敗: \(lastError ?? "unknown")"); return false }
            let raw = d["url"] as? String ?? ""
            let resolved = URL(string: raw, relativeTo: normalizedBaseURL)?.absoluteURL.absoluteString ?? raw
            history.insert(HistoryItem(body: item.body, resultURL: resolved, imageCount: item.images.count), at: 0)
            drafts.removeAll { $0.id == item.id }; persist(); status = "投稿成功"; log("投稿成功。履歴に保存")
            return true
        } catch {
            lastError = error.localizedDescription; status = "投稿失敗"; log("投稿例外: \(error.localizedDescription)"); return false
        }
    }

    var currentWebURLString: String { webView.url?.absoluteString ?? "未読込" }

    func detectAccountIDFromWebPage() async {
        guard webView.url?.host == normalizedBaseURL?.host else { lastError = "先にKashejoのWeb画面を開いてください"; return }
        let js = #"""
        (() => {
          const found = new Set();
          const add = value => {
            if (!value) return;
            try {
              const u = new URL(value, location.href);
              const paths = u.pathname.split('/').filter(Boolean);
              for (let i=0; i<paths.length-1; i++) if (paths[i] === 'a' && /^\d+$/.test(paths[i+1])) found.add(paths[i+1]);
              for (let i=0; i<paths.length-1; i++) if (/^(account|accounts|user|users|profile|profiles)$/.test(paths[i]) && /^\d+$/.test(paths[i+1])) found.add(paths[i+1]);
            } catch (_) {}
          };
          add(location.href);
          if (found.size === 1) return {ids:Array.from(found), url:location.href, title:document.title, source:'current-url'};
          document.querySelectorAll('a[href], form[action]').forEach(e => add(e.href || e.action));
          return {ids:Array.from(found), url:location.href, title:document.title, source:'page-links'};
        })()
        """#
        do {
            let result = try await webView.callAsyncJavaScript("return " + js, arguments: [:], in: nil, contentWorld: .page)
            let dict = result as? [String: Any]
            let ids = dict?["ids"] as? [String] ?? []
            if ids.count == 1, let id = ids.first { accountID = id; lastError = nil; log("アカウントIDをWeb画面から取得: \(id)") }
            else if ids.count > 1 { lastError = "複数のID候補が見つかりました: \(ids.joined(separator: ", "))。プロフィール画面を開いて再取得してください。"; log("アカウントID候補が複数: \(ids.joined(separator: ","))") }
            else { lastError = "現在の画面からアカウントIDを特定できません。プロフィールまたは自分の投稿画面を開いてください。"; log("アカウントID取得失敗: DOM内にID候補なし") }
        } catch { lastError = "ID取得エラー: \(error.localizedDescription)"; log("アカウントID取得エラー: \(error.localizedDescription)") }
    }

    func saveDraft(body: String, images: [Data], scheduledAt: Date? = nil, folderID: UUID? = nil) {
        let preparedImages = prepareDraftImages(images)
        let item = PostItem(body: body, images: preparedImages, scheduledAt: scheduledAt, folderID: folderID ?? selectedFolderID)
        drafts.insert(item, at: 0); persist(); if let date = scheduledAt { scheduleReminder(for: item, at: date) }
        log("下書き保存 folder=\(item.folderID?.uuidString ?? "未分類") images=\(preparedImages.count)")
    }
    func duplicateDrafts(bodyTemplate: String, images: [Data], count: Int) {
        let safeCount = min(max(count, 1), 10)
        for _ in 0..<safeCount {
            let expandedBody = expandRandomTokens(bodyTemplate)
            saveDraft(body: expandedBody, images: images, folderID: selectedFolderID)
        }
        log("下書きを\(safeCount)件作成（本文・画像メタデータのランダム文字列を個別生成）")
    }

    private func prepareDraftImages(_ images: [Data]) -> [Data] {
        guard imageMetadataRandomEnabled else { return images }
        let template = imageMetadataRandomTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { log("画像メタデータ付加をスキップ: テンプレートが空です"); return images }
        return images.enumerated().map { index, data in
            let value = expandRandomTokens(template)
            do {
                let output = try ImageMetadataRandomizer.addComment(value, to: data)
                log("画像メタデータ付加成功: \(index + 1)枚目")
                return output
            } catch {
                log("画像メタデータ付加失敗: \(index + 1)枚目 / \(error.localizedDescription)。元画像を保存")
                return data
            }
        }
    }
    private func expandRandomTokens(_ input: String) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        let pattern = #"\{random(?::(\d+))?\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length)).reversed()
        var output = input
        for match in matches {
            let length = match.range(at: 1).location == NSNotFound ? 8 : min(128, max(1, Int(ns.substring(with: match.range(at: 1))) ?? 8))
            let token = String((0..<length).compactMap { _ in alphabet.randomElement() })
            if let range = Range(match.range, in: output) { output.replaceSubrange(range, with: token) }
        }
        return output
    }
    func createFolder(name: String, parentID: UUID? = nil) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let folder = QueueFolder(name: clean, parentID: parentID); folders.append(folder); selectedFolderID = folder.id; persist(); log("キューフォルダ作成: \(folderPath(folder))")
    }
    func deleteFolder(_ id: UUID) {
        let descendants = Set(folders.filter { $0.parentID == id }.map(\.id))
        var all = descendants; var changed = true
        while changed { let next = Set(folders.filter { $0.parentID.map(all.contains) == true }.map(\.id)); changed = !next.isSubset(of: all); all.formUnion(next) }
        all.insert(id)
        for index in drafts.indices where drafts[index].folderID.map(all.contains) == true { drafts[index].folderID = nil }
        folders.removeAll { all.contains($0.id) }; if selectedFolderID.map(all.contains) == true { selectedFolderID = nil }; persist(); log("フォルダと配下を削除: \(all.count)個。下書きは未分類へ移動")
    }
    func deleteDraft(_ item: PostItem) { drafts.removeAll { $0.id == item.id }; UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [item.id.uuidString]); persist() }
    func deleteDrafts(_ ids: Set<UUID>) { drafts.removeAll { ids.contains($0.id) }; for id in ids { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString]) }; persist(); log("下書き一括削除: \(ids.count)件") }
    func deleteHistory(_ id: UUID) { history.removeAll { $0.id == id }; persist(); log("履歴削除") }
    func deleteAllHistory() { history.removeAll(); persist(); log("履歴を全削除") }
    func moveDrafts(_ ids: Set<UUID>, to folderID: UUID?) {
        for index in drafts.indices where ids.contains(drafts[index].id) { drafts[index].folderID = folderID }
        persist(); log("下書き\(ids.count)件をフォルダへ移動")
    }
    func drafts(in folder: UUID?) -> [PostItem] { drafts.filter { $0.folderID == folder } }

    private func queueLog(_ message: String) {
        let safeMessage = message.replacingOccurrences(of: #"(?i)(cookie|authorization|csrf|password|token)\s*[:=]\s*[^\s,;]+"#, with: "$1=[REDACTED]", options: .regularExpression)
        let line = "\(Date().formatted(date: .numeric, time: .standard))  \(safeMessage)"
        queueLogs.insert(line, at: 0)
        if queueLogs.count > 500 { queueLogs = Array(queueLogs.prefix(500)) }
        UserDefaults.standard.set(queueLogs, forKey: "queueLogs")
        log("QUEUE: \(message)")
    }

    func startQueue(draftIDs: Set<UUID>? = nil) {
        guard queueTask == nil else { return }
        let source: [PostItem]
        if let draftIDs, !draftIDs.isEmpty { source = drafts.filter { draftIDs.contains($0.id) } }
        else { source = drafts(in: selectedFolderID) }
        let batch = Array(source.prefix(max(1, min(queueMaxCount, 50))))
        guard !batch.isEmpty else { queueProgress = "投稿対象の下書きがありません"; queueLog(queueProgress); return }
        queueLog("キュー開始: \(batch.count)件 / 間隔 \(Int(queueIntervalSeconds))秒")
        beginLiveActivity(total: batch.count)
        queueTask = Task {
            for (index, item) in batch.enumerated() {
                if Task.isCancelled { break }
                queueNextPostAt = nil; queueRemainingSeconds = 0
                queueProgress = "投稿中 \(index+1)/\(batch.count)"
                queueLog("投稿開始 \(index+1)/\(batch.count) ・画像 \(item.images.count)枚")
                await updateLiveActivity(completed: index, total: batch.count, status: queueProgress, nextAt: nil)
                if !(await post(item)) {
                    queueProgress = "失敗：\(index+1)/\(batch.count)"
                    queueLog("投稿失敗 \(index+1)/\(batch.count): \(lastError ?? "詳細不明")")
                    break
                }
                queueLog("投稿成功 \(index+1)/\(batch.count)")
                await updateLiveActivity(completed: index+1, total: batch.count, status: "完了 \(index+1)/\(batch.count)", nextAt: nil)
                if index < batch.count-1 {
                    let interval = max(5, min(3600, queueIntervalSeconds))
                    let next = Date().addingTimeInterval(interval)
                    queueNextPostAt = next; queueProgress = "次の投稿を待機中"
                    await updateLiveActivity(completed: index+1, total: batch.count, status: queueProgress, nextAt: next)
                    queueLog("次の投稿まで \(Int(interval))秒")
                    for remaining in stride(from: Int(interval), through: 1, by: -1) {
                        if Task.isCancelled { break }
                        queueRemainingSeconds = remaining
                        do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    }
                    queueRemainingSeconds = 0; queueNextPostAt = nil
                    if Task.isCancelled { break }
                }
            }
            if Task.isCancelled { queueProgress = "停止"; queueLog("キュー停止") }
            else if queueProgress.hasPrefix("投稿中") || queueProgress == "次の投稿を待機中" { queueProgress = "キュー完了"; queueLog("キュー完了") }
            await endLiveActivity(finalStatus: queueProgress)
            queueTask = nil; queueNextPostAt = nil; queueRemainingSeconds = 0
        }
    }
    func stopQueue() {
        queueTask?.cancel(); queueTask = nil; queueNextPostAt = nil; queueRemainingSeconds = 0
        queueProgress = "停止"; queueLog("キュー停止要求")
        Task { await endLiveActivity(finalStatus: "停止") }
    }
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
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("WebView読込完了: \(webView.url?.host ?? "unknown")\(webView.url?.path ?? "") title=\(webView.title ?? "")")
        refreshCurrentUserAgent()
        Task { await checkSession() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { log("WebView読込失敗: \(error.localizedDescription)"); lastError = error.localizedDescription }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { log("WebView遷移失敗: \(error.localizedDescription)"); lastError = error.localizedDescription }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let r = navigationResponse.response as? HTTPURLResponse { log("Navigation HTTP \(r.statusCode) \(r.url?.host ?? "")\(r.url?.path ?? "") MIME=\(r.mimeType ?? "-") bytes=\(r.expectedContentLength)") }; decisionHandler(.allow)
    }
    private var storeURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let profile = profiles.first(where: { $0.id == activeProfileID })
        let owner = profile?.shareDraftsWithDefault == true ? (profiles.first(where: \.isDefault)?.id ?? activeProfileID) : activeProfileID
        return root.appendingPathComponent("KashejoProfiles", isDirectory: true).appendingPathComponent(owner.uuidString, isDirectory: true).appendingPathComponent("kashejo-data.json")
    }
    private func loadStore() {
        drafts = []; history = []; folders = []
        var source = storeURL
        if !FileManager.default.fileExists(atPath: source.path), profiles.first(where: { $0.id == activeProfileID })?.isDefault == true {
            let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("kashejo-data.json")
            if FileManager.default.fileExists(atPath: legacy.path) { source = legacy }
        }
        guard let data = try? Data(contentsOf: source), let store = try? JSONDecoder().decode(StoreData.self, from: data) else { return }
        drafts = store.drafts; history = store.history; folders = store.folders
        if source != storeURL { persist(); log("旧バージョンの下書き・履歴を移行") }
    }
    private func persist() { do { try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(StoreData(drafts: drafts, history: history, folders: folders)).write(to: storeURL, options: .atomic) } catch { lastError = "保存失敗: \(error.localizedDescription)"; log("ローカル保存失敗") } }
}
