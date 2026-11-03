import CommonCrypto
import CryptoKit
import Foundation

/// PINから暗号鍵を導出し、照合用データを作成します。
enum KeyDerivation {
    private static let iterations: UInt32 = 210_000
    private static let keyLength = 32

    /// PBKDF2-HMAC-SHA256を反復し、PINを直接保存せずに32バイト鍵へ変換します。
    static func deriveKey(password: String, salt: Data) throws -> Data {
        let passwordData = Data(password.utf8)
        var derived = Data(repeating: 0, count: keyLength)

        let status: Int32 = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { outputBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        outputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw PhotoVaultError.credentialsMissing
        }
        return derived
    }

    static func verifier(for derivedKey: Data) -> Data {
        let key = SymmetricKey(data: derivedKey)
        let message = Data("PhotoVault.PasswordVerifier.v1".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    /// 比較時間の差から値を推測されにくいよう、全バイトを必ず比較します。
    static func securelyMatches(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
