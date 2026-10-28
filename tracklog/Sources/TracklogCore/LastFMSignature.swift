import CryptoKit
import Foundation

/// Last.fm's request signature: every parameter except `format` and `callback`,
/// sorted by name, concatenated as name and value, then MD5 of that string and
/// the application's shared secret. The result is lowercase hexadecimal.
public enum LastFMSignature {
    public static func signature(
        parameters: [String: String],
        sharedSecret: String,
    ) -> String {
        let signed = parameters
            .filter { name, _ in
                name != "format" && name != "callback" && name != "api_sig"
            }
            .sorted { $0.key < $1.key }
            .map { name, value in "\(name)\(value)" }
            .joined()

        let digest = Insecure.MD5.hash(data: Data((signed + sharedSecret).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
