import Foundation
import Testing
@testable import F1TV

@Suite struct LoginCookieTests {
    static let json = #"{"data":{"subscriptionToken":"TOK123"}}"#

    static func encoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? s
    }

    @Test func rawJSON() {
        #expect(LoginCookie.token(from: Self.json) == "TOK123")
    }

    @Test func urlEncoded() {
        #expect(LoginCookie.token(from: Self.encoded(Self.json)) == "TOK123")
    }

    @Test func doubleURLEncoded() {
        #expect(LoginCookie.token(from: Self.encoded(Self.encoded(Self.json))) == "TOK123")
    }

    @Test func loginSessionPrefix() {
        #expect(LoginCookie.token(from: "login-session=" + Self.encoded(Self.json)) == "TOK123")
        #expect(LoginCookie.token(from: "Login-Session=" + Self.json) == "TOK123")
    }

    @Test func quotesAndNewline() {
        #expect(LoginCookie.token(from: "\"" + Self.json + "\"\n") == "TOK123")
        #expect(LoginCookie.token(from: "'" + Self.encoded(Self.json) + "'  \n") == "TOK123")
    }

    @Test func longValue() {
        let pad = String(repeating: "x", count: 3000)
        let raw = #"{"pad":"\#(pad)","data":{"subscriptionToken":"TOK123"}}"#
        #expect(raw.count > 3000)
        #expect(LoginCookie.token(from: raw) == "TOK123")
        #expect(LoginCookie.token(from: Self.encoded(raw)) == "TOK123")
    }

    @Test func bareToken() {
        #expect(LoginCookie.token(from: "abc.DEF-123_xyz") == "abc.DEF-123_xyz")
        #expect(LoginCookie.token(from: "  abc.DEF-123_xyz\n") == "abc.DEF-123_xyz")
    }

    @Test func cookieWithoutTokenIsNil() {
        #expect(LoginCookie.token(from: #"{"data":{"other":"x"}}"#) == nil)
        #expect(LoginCookie.token(from: #"{"data":{"subscriptionToken":""}}"#) == nil)
        #expect(LoginCookie.token(from: Self.encoded(#"{"data":{}}"#)) == nil)
    }

    @Test func notACookieIsNil() {
        #expect(LoginCookie.token(from: "two words") == nil)
        #expect(LoginCookie.token(from: "") == nil)
        #expect(LoginCookie.token(from: "   \n") == nil)
    }

    @Test func loginURL() {
        #expect(LoginCookie.loginURL.absoluteString == "https://account.formula1.com/#/en/login")
    }
}
