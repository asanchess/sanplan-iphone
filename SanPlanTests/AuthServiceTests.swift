import XCTest
@testable import SanPlan

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            XCTFail("Handler is not set")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class AuthServiceTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeMockClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return APIClient(baseURL: URL(string: "https://sanplan-asanchess.vercel.app")!, session: session)
    }

    // MARK: - PKCE Tests

    func testVerifierLengthAndAllowedCharacters() {
        let verifier = PKCEHelper.makeVerifier()
        XCTAssertEqual(verifier.count, 64)

        let allowedCharacterSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        for scalar in verifier.unicodeScalars {
            XCTAssertTrue(allowedCharacterSet.contains(scalar), "Character '\(scalar)' is not allowed in PKCE verifier")
        }
    }

    func testRFC7636AppendixBVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expectedChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

        let challenge = PKCEHelper.makeChallenge(verifier: verifier)
        XCTAssertEqual(challenge, expectedChallenge)
        XCTAssertEqual(challenge.count, 43)
    }

    func testChallengeLengthForRandomVerifier() {
        let verifier = PKCEHelper.makeVerifier()
        let challenge = PKCEHelper.makeChallenge(verifier: verifier)
        XCTAssertEqual(challenge.count, 43)
    }

    // MARK: - Callback Parsing Tests

    func testParseCallbackCode() {
        let url = URL(string: "arna://auth?code=sample_oauth_code_123")!
        let result = PKCEHelper.parseCallback(url)
        XCTAssertEqual(result, .code("sample_oauth_code_123"))
    }

    func testParseCallbackCancelled() {
        let url = URL(string: "arna://auth?error=cancelled")!
        let result = PKCEHelper.parseCallback(url)
        XCTAssertEqual(result, .cancelled)
    }

    func testParseCallbackCalendarConnected() {
        let url = URL(string: "arna://auth?result=calendar")!
        let result = PKCEHelper.parseCallback(url)
        XCTAssertEqual(result, .calendarConnected)
    }

    func testParseCallbackForeignURL() {
        let foreign1 = URL(string: "https://example.com/auth?code=123")!
        XCTAssertEqual(PKCEHelper.parseCallback(foreign1), .invalid)

        let foreign2 = URL(string: "arna://otherpath?code=123")!
        XCTAssertEqual(PKCEHelper.parseCallback(foreign2), .invalid)

        let empty = URL(string: "arna://auth")!
        XCTAssertEqual(PKCEHelper.parseCallback(empty), .invalid)
    }

    // MARK: - APIClient and Protocol Tests

    func testAPIClientHandles401Unauthorized() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{}".utf8))
        }

        let client = makeMockClient()
        do {
            let _: StatusResponse = try await client.get(path: "/api/status")
            XCTFail("Expected unauthorized error")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAPIClientDecodesServerErrorMessage() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let errorJson = """
            {"message": "Неверный пароль"}
            """
            return (response, Data(errorJson.utf8))
        }

        let client = makeMockClient()
        do {
            let _: StatusResponse = try await client.get(path: "/api/status")
            XCTFail("Expected server error")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 400, message: "Неверный пароль"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAPIClientSendsOriginHeader() async throws {
        var observedOrigin: String?

        MockURLProtocol.requestHandler = { request in
            observedOrigin = request.value(forHTTPHeaderField: "Origin")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let statusJson = """
            {"authenticated": false}
            """
            return (response, Data(statusJson.utf8))
        }

        let client = makeMockClient()
        let _: StatusResponse = try await client.get(path: "/api/status")

        XCTAssertEqual(observedOrigin, "https://sanplan-asanchess.vercel.app")
    }

    func testAPIClientEncodesPostBody() async throws {
        struct TestPayload: Encodable {
            let password: String
        }

        var observedBodyData: Data?
        var observedContentType: String?

        MockURLProtocol.requestHandler = { request in
            observedBodyData = request.httpBody
            observedContentType = request.value(forHTTPHeaderField: "Content-Type")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{}".utf8))
        }

        let client = makeMockClient()
        let payload = TestPayload(password: "secret123")
        let _: EmptyResponse = try await client.post(path: "/api/login", body: payload)

        XCTAssertNotNil(observedBodyData)
        XCTAssertTrue(observedContentType?.contains("application/json") == true)

        let decoded = try JSONDecoder().decode([String: String].self, from: observedBodyData!)
        XCTAssertEqual(decoded["password"], "secret123")
    }
}
