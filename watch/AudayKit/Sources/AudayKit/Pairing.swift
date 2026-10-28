import CryptoKit
import Foundation
#if !os(watchOS)
import Network
#endif

/// Pairing the iPhone with the Mac the way Auday's "Connect to your workflow" pairs a computer:
/// the iPhone shows a 16-character communication password and advertises itself over Bonjour;
/// on the Mac one command (`python -m app.pair_iphone`) finds it, asks for the password and, over
/// TLS-PSK keyed by that password, sends the Mac's address and upload token. See docs/IPHONE_PAIRING.md.
public enum Pairing {
    public static let serviceType = "_audayreplica._tcp"
    public static let identity = "auday-replica-pair-v1"
    static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")   // Auday's: no 0 1 I O

    /// 16 characters from the alphabet (80 bits), at least 4 different ones.
    public static func newPassword() -> String {
        var generator = SystemRandomNumberGenerator()
        while true {
            let text = String((0..<16).map { _ in alphabet.randomElement(using: &generator)! })
            if Set(text).count >= 4 { return text }
        }
    }

    /// Upper-cased, without spaces and dashes; nil unless it is a valid password.
    public static func normalize(_ password: String) -> String? {
        let text = password.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard text.count == 16, text.allSatisfy(alphabet.contains), Set(text).count >= 4 else { return nil }
        return text
    }

    /// "XXXX-XXXX-XXXX-XXXX", as Auday shows it.
    public static func formatted(_ password: String) -> String {
        stride(from: 0, to: password.count, by: 4).map { i -> String in
            let start = password.index(password.startIndex, offsetBy: i)
            return String(password[start..<(password.index(start, offsetBy: 4, limitedBy: password.endIndex) ?? password.endIndex)])
        }.joined(separator: "-")
    }

    /// HKDF-SHA256 of the normalized password, salt and PSK identity "auday-replica-pair-v1".
    public static func pskKey(_ password: String) -> Data? {
        guard let text = normalize(password) else { return nil }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(text.utf8)),
                                         salt: Data(identity.utf8), info: Data("tls-psk".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// One frame: a 4-byte big-endian length, then a UTF-8 JSON object.
    public static func frame(_ value: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// The JSON object in a complete frame, or nil.
    public static func object(inFrame data: Data) -> [String: Any]? {
        guard data.count >= 4 else { return nil }
        let length = data.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= 64 * 1024, data.count == 4 + length else { return nil }
        return try? JSONSerialization.jsonObject(with: data.dropFirst(4)) as? [String: Any]
    }

    #if !os(watchOS)
    /// TLS 1.2, ECDHE-PSK-CHACHA20-POLY1305 only, keyed by the password; IPv4, so the Mac's
    /// address as the iPhone sees it is a plain one.
    public static func parameters(password: String) -> NWParameters? {
        guard let key = pskKey(password) else { return nil }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options,
            tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!)
        let id = Data(identity.utf8)
        key.withUnsafeBytes { raw in id.withUnsafeBytes { name in
            sec_protocol_options_add_pre_shared_key(options, DispatchData(bytes: raw) as __DispatchData,
                                                    DispatchData(bytes: name) as __DispatchData)
        }}
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return parameters
    }

    /// Reads one frame from `connection`.
    public static func receive(on connection: NWConnection, _ done: @escaping ([String: Any]?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { head, _, _, error in
            guard let head, head.count == 4, error == nil else { return done(nil) }
            let length = head.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= 64 * 1024 else { return done(nil) }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard let body, error == nil else { return done(nil) }
                done(object(inFrame: head + body))
            }
        }
    }
    #endif
}
