import Foundation
import Observation
import Security

/// The signed-in account. HN identifies you with a single `user` cookie; we keep a copy
/// in the Keychain (never the password) and put it back into the cookie store at launch.
@Observable
final class SessionStore {
    private(set) var username: String?
    private(set) var karma: Int?

    var isSignedIn: Bool { username != nil }

    func restore() async {
        if HNClient.sessionCookie == nil, let saved = Keychain.read() {
            HNClient.install(cookieValue: saved)
        }
        guard let cookie = HNClient.sessionCookie else { return }
        adopt(cookie)
        await refresh()
    }

    func signIn(username: String, password: String) async throws {
        let cookie = try await HNClient.shared.login(username: username, password: password)
        adopt(cookie)
        await refresh()
    }

    func createAccount(username: String, password: String) async throws {
        let cookie = try await HNClient.shared.createAccount(username: username, password: password)
        adopt(cookie)
        await refresh()
    }

    /// Called with the cookie captured from the web sign-in sheet, or after a native sign-in.
    func adopt(_ cookie: HTTPCookie) {
        HTTPCookieStorage.shared.setCookie(cookie)
        Keychain.save(cookie.value)
        // The cookie looks like "name&hash".
        username = cookie.value.split(separator: "&").first.map(String.init)
    }

    func signOut() async {
        await HNClient.shared.logout()
        Keychain.delete()
        username = nil
        karma = nil
    }

    func refresh() async {
        guard let username else { return }
        if let profile = try? await HNClient.shared.user(username) {
            karma = profile.karma
        }
    }
}

nonisolated enum Keychain {
    private static let service = "dev.hnreader.session"
    private static let account = "user-cookie"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
