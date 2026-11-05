import Foundation

public struct EmptyBody: Encodable {}

public struct EmptyResponse: Decodable {}

public struct ServerErrorMessage: Decodable {
    public let message: String
}

public struct StatusResponse: Decodable, Equatable {
    public struct GoogleInfo: Decodable, Equatable {
        public let configured: Bool
        public let connected: Bool
        public let needsReconnect: Bool?

        public init(configured: Bool, connected: Bool, needsReconnect: Bool? = nil) {
            self.configured = configured
            self.connected = connected
            self.needsReconnect = needsReconnect
        }
    }

    public struct AccountInfo: Decodable, Equatable {
        public let id: String?
        public let email: String?

        public init(id: String? = nil, email: String? = nil) {
            self.id = id
            self.email = email
        }
    }

    public let google: GoogleInfo?
    public let authenticated: Bool
    public let account: AccountInfo?

    public init(google: GoogleInfo? = nil, authenticated: Bool, account: AccountInfo? = nil) {
        self.google = google
        self.authenticated = authenticated
        self.account = account
    }
}

public enum APIError: Error, LocalizedError, Equatable {
    case unauthorized
    case server(status: Int, message: String)
    case invalidResponse
    case transport(String)
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Сессия истекла. Войдите снова."
        case .server(_, let message):
            return message
        case .invalidResponse:
            return "Некорректный ответ сервера."
        case .transport(let message):
            return message
        case .responseTooLarge:
            return "Ответ сервера превышает допустимый размер."
        }
    }
}

public final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public final class APIClient: @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let noRedirectDelegate: NoRedirectDelegate

    public static let defaultBaseURL = URL(string: "https://sanplan-asanchess.vercel.app")!
    private static let maxResponseBytes: Int = 5 * 1024 * 1024 // 5 MB

    public init(
        baseURL: URL = APIClient.defaultBaseURL,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        let delegate = NoRedirectDelegate()
        self.noRedirectDelegate = delegate

        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpCookieStorage = HTTPCookieStorage.shared
            config.httpShouldSetCookies = true
            config.httpCookieAcceptPolicy = .always
            self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        }
    }

    public func get<T: Decodable>(
        path: String,
        query: [String: String]? = nil
    ) async throws -> T {
        let request = try buildRequest(path: path, query: query, method: "GET", bodyData: nil)
        return try await perform(request)
    }

    public func post<T: Decodable>(
        path: String,
        body: (any Encodable)? = nil
    ) async throws -> T {
        let bodyData: Data?
        if let body = body {
            bodyData = try JSONEncoder().encode(body)
        } else {
            bodyData = nil
        }
        let request = try buildRequest(path: path, query: nil, method: "POST", bodyData: bodyData)
        return try await perform(request)
    }

    private func buildRequest(
        path: String,
        query: [String: String]?,
        method: String,
        bodyData: Data?
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw APIError.invalidResponse
        }

        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let existingPath = components.path.hasSuffix("/") ? components.path : "\(components.path)/"
        components.path = existingPath + trimmedPath

        if let query = query, !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method

        let origin: String
        if let scheme = baseURL.scheme, let host = baseURL.host {
            if let port = baseURL.port {
                origin = "\(scheme)://\(host):\(port)"
            } else {
                origin = "\(scheme)://\(host)"
            }
        } else {
            origin = baseURL.absoluteString
        }

        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let bodyData = bodyData {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if data.count > Self.maxResponseBytes {
            throw APIError.responseTooLarge
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        if (200...299).contains(httpResponse.statusCode) {
            if T.self == EmptyResponse.self, data.isEmpty {
                // Return empty decodable
                return try JSONDecoder().decode(T.self, from: Data("{}".utf8))
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError.invalidResponse
            }
        }

        // Try to decode error message from JSON { "message": "..." }
        if let decodedError = try? JSONDecoder().decode(ServerErrorMessage.self, from: data),
           !decodedError.message.isEmpty {
            throw APIError.server(status: httpResponse.statusCode, message: decodedError.message)
        }

        let fallbackMessage = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
        throw APIError.server(status: httpResponse.statusCode, message: fallbackMessage)
    }
}
