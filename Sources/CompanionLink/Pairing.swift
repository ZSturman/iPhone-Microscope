import Foundation
import CryptoKit
import Security

/// A short-lived invitation carried by the Mac's QR code, never by discovery metadata.
public struct PairingInvitation: Equatable {
    public let id: String
    public let viewerID: String
    public let code: String
    public let secret: Data
    public let expires: Date
    public init(viewerID: String, code: String, expires: Date = Date().addingTimeInterval(300), secret: Data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, id: String = UUID().uuidString) {
        self.id = id; self.viewerID = viewerID; self.code = code; self.expires = expires; self.secret = secret
    }
    public var legacyURL: URL {
        var parts = URLComponents()
        parts.scheme = "benchlens"; parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "invite", value: id), URLQueryItem(name: "viewer", value: viewerID), URLQueryItem(name: "code", value: code), URLQueryItem(name: "expires", value: String(Int(expires.timeIntervalSince1970))), URLQueryItem(name: "secret", value: secret.base64EncodedString())]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }
    /// The browser fallback opens the App Store. Fragments never go to the web server.
    public var url: URL {
        var parts = URLComponents(string: "https://zacharysturman.com/iphone-microscope/connect")!
        parts.percentEncodedFragment = URLComponents(url: legacyURL, resolvingAgainstBaseURL: false)!.percentEncodedQuery
        return parts.url!
    }
    public init?(url: URL, now: Date = Date()) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        if parts.scheme == "https" {
            guard parts.host == "zacharysturman.com", parts.path == "/iphone-microscope/connect", parts.query == nil,
                  let fragment = parts.percentEncodedFragment else { return nil }
            parts = URLComponents(string: "benchlens://pair?" + fragment) ?? URLComponents()
        } else {
            guard parts.scheme == "benchlens", parts.host == "pair", parts.path.isEmpty, parts.fragment == nil else { return nil }
        }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? { let matches = items.filter { $0.name == name }; return matches.count == 1 ? matches[0].value : nil }
        guard let invitationID = value("invite"), UUID(uuidString: invitationID) != nil,
              let id = value("viewer"), UUID(uuidString: id) != nil,
              let code = value("code"), Self.validCode(code),
              let seconds = value("expires").flatMap(Double.init), seconds.isFinite,
              let encoded = value("secret"), let secret = Data(base64Encoded: encoded), secret.count == 32 else { return nil }
        let expires = Date(timeIntervalSince1970: seconds)
        guard expires > now, expires.timeIntervalSince(now) <= 310 else { return nil }
        self.init(viewerID: id, code: code, expires: expires, secret: secret, id: invitationID)
    }
    public func matchesDiscovery(_ info: [String: String], now: Date = Date()) -> Bool {
        expires > now && info["target"] == viewerID && info["invite"] == id
    }
    public static func validCode(_ code: String) -> Bool { code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) } }
}

struct TrustedCompanion: Codable {
    var id: String
    var secret: Data
}

/// Role-separated proofs bind both installations and fresh nonces; discovery is not trust.
enum PairingProof {
    static func make(secret: Data, role: String, cameraID: String, viewerID: String, challenge: String, response: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(["benchlens-v2", role, cameraID, viewerID, challenge, response].joined(separator: "|").utf8), using: SymmetricKey(data: secret)))
    }
    static func verify(_ proof: Data, secret: Data, role: String, cameraID: String, viewerID: String, challenge: String, response: String) -> Bool {
        let message = Data(["benchlens-v2", role, cameraID, viewerID, challenge, response].joined(separator: "|").utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: secret))
    }
}

/// One remembered partner per installation. Secrets stay in this device's Keychain.
enum PairingKeychain {
    static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.local.iPhoneMicroscope.pairing.v2", kSecAttrAccount as String: id]
    }
    static func load(_ id: String) -> TrustedCompanion? {
        var query = query(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TrustedCompanion.self, from: data)
    }
    static func save(_ pair: TrustedCompanion, id: String) -> Bool {
        guard let data = try? JSONEncoder().encode(pair) else { return false }
        let query = query(id)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    static func forget(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}
