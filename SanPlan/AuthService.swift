import Foundation
import SwiftUI
import CryptoKit
import AuthenticationServices

public enum AuthCallbackResult: Equatable {
    case code(String)
    case cancelled
    case calendarConnected
    case invalid
}

public enum PKCEHelper {
    /// 48 random bytes give exactly 64 base64url characters, with no modulo bias.
    public static func makeVerifier() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<48).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    public static func makeChallenge(verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func parseCallback(_ url: URL) -> AuthCallbackResult {
        guard let scheme = url.scheme?.lowercased(), scheme == "arna" else {
            return .invalid
        }

        guard url.host?.lowercased() == "auth",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .invalid
        }

        // A repeated parameter must not crash the app, so the first value wins.
        let queryItems = components.queryItems ?? []
        let params = Dictionary(queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })

        if let error = params["error"], error == "cancelled" {
            return .cancelled
        }

        if let result = params["result"], result == "calendar" {
            return .calendarConnected
        }

        if let code = params["code"], !code.isEmpty {
            return .code(code)
        }

        return .invalid
    }
}

public final class AuthenticationPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    public static let shared = AuthenticationPresentationContextProvider()

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            for scene in scenes {
                if let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                    return window
                }
            }
            return ASPresentationAnchor()
        }
    }
}

@MainActor
public final class AuthService: ObservableObject {
    public enum Phase: Equatable {
        case checking
        case signedOut
        case signedIn(email: String)
    }

    @Published public private(set) var phase: Phase = .checking
    @Published public private(set) var status: StatusResponse? = nil
    @Published public var errorMessage: String? = nil
    @Published public private(set) var isAuthenticating: Bool = false

    public let client: APIClient

    private var activeAuthSession: ASWebAuthenticationSession?

    public init(client: APIClient = APIClient()) {
        self.client = client
    }

    public func loadStatus() async {
        do {
            let status: StatusResponse = try await client.get(path: "/api/status")
            self.status = status
            if status.authenticated {
                let email = status.account?.email ?? "Пользователь"
                UserDefaults.standard.set(email, forKey: Self.lastEmailKey)
                self.phase = .signedIn(email: email)
            } else {
                signedOutLocally()
            }
            self.errorMessage = nil
        } catch APIError.unauthorized {
            signedOutLocally()
            self.errorMessage = nil
        } catch {
            // No network must not sign the owner out: workouts and money work offline.
            self.status = nil
            if hasSessionCookie {
                self.phase = .signedIn(email: UserDefaults.standard.string(forKey: Self.lastEmailKey) ?? "Пользователь")
            } else {
                self.phase = .signedOut
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private static let lastEmailKey = "arna.lastEmail"

    private var hasSessionCookie: Bool {
        HTTPCookieStorage.shared.cookies(for: client.baseURL)?.contains { $0.name == "san_session" } ?? false
    }

    /// The server said this session is gone: forget it, and call this for any 401 from later features.
    public func signedOutLocally() {
        clearCookies()
        UserDefaults.standard.removeObject(forKey: Self.lastEmailKey)
        status = nil
        phase = .signedOut
    }

    public func signInWithGoogle() async {
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        let verifier = PKCEHelper.makeVerifier()
        let challenge = PKCEHelper.makeChallenge(verifier: verifier)

        var loginURLComponents = URLComponents(url: client.baseURL, resolvingAgainstBaseURL: true)
        let currentPath = loginURLComponents?.path ?? ""
        let basePath = currentPath.hasSuffix("/") ? String(currentPath.dropLast()) : currentPath
        loginURLComponents?.path = "\(basePath)/auth/login"
        loginURLComponents?.queryItems = [
            URLQueryItem(name: "native_challenge", value: challenge)
        ]

        guard let authURL = loginURLComponents?.url else {
            errorMessage = "Не удалось сформировать адрес входа."
            return
        }

        do {
            let callbackURL = try await runWebAuthSession(
                url: authURL,
                callbackScheme: "arna",
                ephemeral: true
            )

            switch PKCEHelper.parseCallback(callbackURL) {
            case .code(let code):
                struct ExchangeBody: Encodable {
                    let code: String
                    let verifier: String
                }
                let body = ExchangeBody(code: code, verifier: verifier)
                let _: EmptyResponse = try await client.post(path: "/api/auth/native/exchange", body: body)
                await loadStatus()

            case .cancelled:
                // Stay on login without error banner
                break

            case .calendarConnected, .invalid:
                errorMessage = "Получен некорректный ответ авторизации."
            }
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            // User dismissed web view
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Step 1 of the email sign-in: the server mails a 6-digit code. True when it was sent.
    public func requestEmailCode(_ email: String) async -> Bool {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else { return false }
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }
        struct StartBody: Encodable { let email: String }
        do {
            let _: EmptyResponse = try await client.post(path: "/api/auth/email/start", body: StartBody(email: address))
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Step 2: the code from the letter opens a session for that address.
    public func verifyEmailCode(email: String, code: String) async {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return }
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }
        struct VerifyBody: Encodable { let email: String; let code: String }
        do {
            let _: EmptyResponse = try await client.post(
                path: "/api/auth/email/verify",
                body: VerifyBody(email: email.trimmingCharacters(in: .whitespacesAndNewlines), code: digits)
            )
            await loadStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func signInWithPassword(_ password: String) async {
        guard !password.isEmpty else { return }
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        struct LoginBody: Encodable {
            let password: String
        }

        do {
            let _: EmptyResponse = try await client.post(path: "/api/login", body: LoginBody(password: password))
            await loadStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func connectCalendar() async {
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        struct CalendarStartResponse: Decodable {
            let url: String
        }

        do {
            let resp: CalendarStartResponse = try await client.post(path: "/api/auth/native/calendar", body: EmptyBody())
            guard let calendarURL = URL(string: resp.url) else {
                errorMessage = "Некорректная ссылка календаря."
                return
            }

            let callbackURL = try await runWebAuthSession(
                url: calendarURL,
                callbackScheme: "arna",
                ephemeral: false
            )

            switch PKCEHelper.parseCallback(callbackURL) {
            case .calendarConnected:
                await loadStatus()
            case .cancelled:
                break
            default:
                await loadStatus()
            }
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            // Dismissed
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func disconnectCalendar() async {
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        do {
            let _: EmptyResponse = try await client.post(path: "/api/google/disconnect", body: EmptyBody())
            await loadStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func signOut() async {
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let _: EmptyResponse = try await client.post(path: "/api/logout", body: EmptyBody())
        } catch {
            // Continue clearing local state regardless of server logout result
        }

        signedOutLocally()
        errorMessage = nil
    }

    private func clearCookies() {
        let storage = HTTPCookieStorage.shared
        if let cookies = storage.cookies(for: client.baseURL) {
            for cookie in cookies {
                storage.deleteCookie(cookie)
            }
        }
        if let allCookies = storage.cookies {
            for cookie in allCookies where cookie.name == "san_session" {
                storage.deleteCookie(cookie)
            }
        }
    }

    private func runWebAuthSession(
        url: URL,
        callbackScheme: String,
        ephemeral: Bool
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let callbackURL = callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: APIError.invalidResponse)
                }
            }

            session.presentationContextProvider = AuthenticationPresentationContextProvider.shared
            session.prefersEphemeralWebBrowserSession = ephemeral
            self.activeAuthSession = session

            guard session.start() else {
                continuation.resume(throwing: APIError.transport("Не удалось запустить сессию авторизации."))
                return
            }
        }
    }
}
