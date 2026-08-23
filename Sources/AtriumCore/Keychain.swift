import Foundation
import Security

/// The OAuth client secret, in the login keychain.
///
/// The secret is bound to `client.owner_user_id` on the Atrium PA side,
/// so it is a durable credential for the user's whole account — not a
/// scoped upload token. It therefore never goes in the repo, never in
/// `config.json`, and never into a log line.
///
/// Keyed by client ID as well as service, so re-minting the client in
/// atrium-pa's admin UI leaves the old entry orphaned rather than
/// silently shadowing the new one.
public enum Keychain {

    public static let service = "com.atrium-mac.capture.oauth"

    public enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)

        public var description: String {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return message ?? "keychain error \(status)"
            }
        }
    }

    /// Account under which the OAuth refresh token is filed.
    ///
    /// Prefixed rather than stored under the client ID, so a refresh
    /// token and a client secret for the same client cannot collide.
    private static func refreshAccount(_ clientID: String) -> String {
        "refresh-token:\(clientID)"
    }

    private static func query(clientID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: clientID,
        ]
    }

    // MARK: - Refresh tokens

    /// The refresh token from a browser login.
    ///
    /// Stored beside the client secret and treated the same way: it is a
    /// long-lived credential for the user's account, so it belongs in the
    /// keychain and nowhere else. It rotates on every use — each
    /// exchange returns a new one and invalidates the old — so this is
    /// written far more often than the secret is.
    public static func refreshToken(for clientID: String) -> String? {
        read(account: refreshAccount(clientID))
    }

    public static func setRefreshToken(_ token: String, for clientID: String) throws {
        try write(token, account: refreshAccount(clientID))
    }

    public static func removeRefreshToken(for clientID: String) {
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: refreshAccount(clientID),
            ] as CFDictionary)
    }

    // MARK: - Generic item access

    private static func read(account: String) -> String? {
        guard !account.isEmpty else { return nil }
        var lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private static func write(_ value: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let payload = Data(value.utf8)

        // Delete then add, rather than update in place. See the note in
        // `setClientSecret`.
        SecItemDelete(base as CFDictionary)

        var insert = base
        insert[kSecValueData as String] = payload
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public static func clientSecret(for clientID: String) -> String? {
        guard !clientID.isEmpty else { return nil }
        var lookup = query(clientID: clientID)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let secret = String(data: data, encoding: .utf8)
        else { return nil }
        return secret
    }

    public static func setClientSecret(_ secret: String, for clientID: String) throws {
        let base = query(clientID: clientID)
        let payload = Data(secret.utf8)

        // Delete then add, rather than update in place.
        //
        // `SecItemUpdate` on an item created by a *different code
        // identity* is precisely what macOS blocks behind a login
        // password prompt: the item's ACL names the application allowed
        // to touch it without asking, and that name is the signature.
        // During development the signature changes whenever the build
        // is re-signed, so an in-place update meant a password dialog
        // every single time.
        //
        // Deleting first drops the stale ACL along with the old item,
        // and the replacement is created owned by whatever is running
        // now. Re-adding is what `SecItemAdd` is for; there is nothing
        // to preserve in the row being replaced.
        SecItemDelete(base as CFDictionary)

        var insert = base
        insert[kSecValueData as String] = payload
        // The uploader runs unattended after login, including while the
        // screen is locked mid-meeting, so the item must be readable
        // then. `AfterFirstUnlock` is the weakest class that allows it.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public static func removeClientSecret(for clientID: String) {
        SecItemDelete(query(clientID: clientID) as CFDictionary)
    }
}
