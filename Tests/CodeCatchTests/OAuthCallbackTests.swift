import Testing
@testable import CodeCatch

/// The tables use the callback's path and query; this puts CodeCatch's redirect in front of them.
private func callback(_ target: String) -> String {
    target.hasPrefix("/") && !target.hasPrefix("//") ? OAuth.google.redirect + target.dropFirst() : target
}

@MainActor struct OAuthCallbackTests {
    @Test(arguments: [
        ("/?state=expected-state&code=authorization-code", "expected-state", "authorization-code"),
        ("/?code=a%2Bb%2Fc%3D%26d&state=expected%2Dstate", "expected-state", "a+b/c=&d"),
        ("/?state=state%20with%20spaces&code=%C5%A1ifra", "state with spaces", "šifra"),
    ])
    func matchingStatePreservesTheDecodedAuthorizationCode(target: String, state: String, code: String) throws {
        #expect(try OAuth.google.authorizationCode(in: callback(target), state: state) == code)
    }

    @Test(arguments: [
        "/?code=authorization-code",
        "/?state=&code=authorization-code",
        "/?state=wrong-state&code=authorization-code",
        "/?state=Expected-state&code=authorization-code",
        "/?state=%20expected-state&code=authorization-code",
        "/?state=expected-state%20&code=authorization-code",
        "/?error=access_denied",
        "/?state=wrong-state&error=access_denied",
        "/?state=expected-state",
        "/?state=expected-state&code=",
        "/?state=expected-state&code",
        "/?state=expected-state&error=",
        "/",
        "/favicon.ico",
    ])
    func unauthenticatedOrEmptyCallbacksCannotCompleteOrCancelLogin(target: String) throws {
        #expect(try OAuth.google.authorizationCode(in: callback(target), state: "expected-state") == nil)
    }

    @Test(arguments: [
        "/?state=expected-state&error=access_denied",
        "/?error=server_error&state=expected%2Dstate",
        "/?state=expected-state&code=authorization-code&error=access_denied",
    ])
    func authenticatedProviderErrorsCannotBeMistakenForSuccessfulLogin(target: String) {
        #expect(throws: (any Error).self) {
            try OAuth.google.authorizationCode(in: callback(target), state: "expected-state")
        }
    }

    @Test(arguments: [
        "/?state=expected-state&state=expected-state&code=authorization-code",
        "/?state=wrong-state&state=expected-state&code=authorization-code",
        "/?state=expected-state&state=wrong-state&code=authorization-code",
        "/?state=expected-state&code=first&code=second",
        "/?state=expected-state&code=&code=authorization-code",
        "/?state=expected-state&error=access_denied&error=server_error",
        "/?state=expected-state&error=&error=access_denied",
        "/?state=expected-state&%73tate=expected-state&code=authorization-code",
        "/?state=expected-state&code=first&%63ode=second",
        "/?state=expected-state&error=access_denied&%65rror=server_error",
    ])
    func duplicateCallbackParametersCannotSelectAnAmbiguousOutcome(target: String) throws {
        #expect(try OAuth.google.authorizationCode(in: callback(target), state: "expected-state") == nil)
    }

    @Test(arguments: [
        "",
        "?state=expected-state&code=authorization-code",
        "/callback?state=expected-state&code=authorization-code",
        "https://example.invalid/?state=expected-state&code=authorization-code",
        "http://localhost:8765/?state=expected-state&code=authorization-code",
        "//example.invalid/?state=expected-state&code=authorization-code",
        "com.example.other:/oauth2redirect?state=expected-state&code=authorization-code",
        "/?state=expected-state&code=%ZZ",
        "/?state=expected-state&code=%",
    ])
    func malformedOrNonRootTargetsCannotCompleteLogin(target: String) throws {
        #expect(try OAuth.google.authorizationCode(in: callback(target), state: "expected-state") == nil)
    }

    /// Each provider only takes its own redirect, so one's callback can't finish the other's sign-in.
    @Test func providersOnlyAcceptTheirOwnRedirect() throws {
        let query = "?state=expected-state&code=authorization-code"
        #expect(try OAuth.microsoft.authorizationCode(in: OAuth.microsoft.redirect + query, state: "expected-state") == "authorization-code")
        #expect(try OAuth.microsoft.authorizationCode(in: OAuth.google.redirect + query, state: "expected-state") == nil)
        #expect(try OAuth.google.authorizationCode(in: OAuth.microsoft.redirect + query, state: "expected-state") == nil)
    }
}
