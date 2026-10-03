import Foundation
import Combine
import WebKit
import UIKit

enum PlanGatewayError: LocalizedError {
    case loginRequired, invalidResponse, server(Int)
    var errorDescription: String? {
        switch self {
        case .loginRequired: return "Войди в SanPlan, затем обнови будильники."
        case .invalidResponse: return "SanPlan вернул непонятный ответ. Существующие будильники сохранены."
        case .server(let status): return "Не удалось получить планы (\(status)). Повтори обновление."
        }
    }
}

// Native API requests never forward the private session to redirects or other hosts.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class PlanGateway: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let origin = URL(string: "https://sanplan-asanchess.vercel.app")!
    let webView: WKWebView
    private let redirectDelegate = NoRedirectDelegate()

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.06, green: 0.05, blue: 0.09, alpha: 1)
        webView.load(URLRequest(url: Self.origin))
    }

    func loadPlans() async throws -> [NativePlan] {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        let host = Self.origin.host!
        let scoped = cookies.filter {
            $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host &&
            ($0.expiresDate == nil || $0.expiresDate! > Date())
        }
        guard !scoped.isEmpty else { throw PlanGatewayError.loginRequired }
        var request = URLRequest(url: Self.origin.appendingPathComponent("api/plans"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in HTTPCookie.requestHeaderFields(with: scoped) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.host == host,
              http.url?.scheme == "https" else { throw PlanGatewayError.invalidResponse }
        if http.statusCode == 401 { throw PlanGatewayError.loginRequired }
        guard http.statusCode == 200 else { throw PlanGatewayError.server(http.statusCode) }
        guard data.count < 2_000_000 else { throw PlanGatewayError.invalidResponse }
        struct Envelope: Decodable { let plans: [NativePlan] }
        do { return try JSONDecoder().decode(Envelope.self, from: data).plans }
        catch { throw PlanGatewayError.invalidResponse }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https", let host = url.host else {
            decisionHandler(.cancel); return
        }
        // Google login is visible browser navigation, never a recipient of native API cookies.
        let allowed = host == Self.origin.host || host == "accounts.google.com" || host == "calendar.google.com"
        if allowed { decisionHandler(.allow) }
        else { decisionHandler(.cancel); UIApplication.shared.open(url) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           url.scheme == "https" { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.protocol == "https" && origin.host == Self.origin.host && frame.isMainFrame ? .prompt : .deny)
    }
}
