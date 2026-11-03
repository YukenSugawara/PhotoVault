import CryptoKit
import Compression
import Foundation
import Security

/// 安全な乱数生成とAES-GCMによる暗号化／復号をまとめた補助型です。
enum CryptoBox {
    static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PhotoVaultError.credentialsMissing
        }
        return Data(bytes)
    }

    /// 平文をAES-GCMで暗号化し、nonceと認証タグを含む結合データを返します。
    static func seal(_ plaintext: Data, using keyData: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData))
        guard let combined = sealed.combined else {
            throw PhotoVaultError.databaseCorrupted
        }
        return combined
    }

    /// AES-GCMの認証に成功した場合だけ暗号文を復号します。
    static func open(_ ciphertext: Data, using keyData: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: SymmetricKey(data: keyData))
    }
}


// 写真を圧縮してから暗号化する。JPEG/HEICのように圧縮済みのデータは増量を避けてそのまま保存。
enum AutomaticBackupCompression {
    private static let magic = Data("PVZ01".utf8)
    private static let standaloneMagic = Data("PVM02".utf8)
    private static let maxManifestBytes = 256 * 1024 * 1024

    static func encode(_ original: Data) -> Data {
        guard !original.isEmpty else { return original }
        var output = Data(count: original.count)
        let count = original.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard let src = source.bindMemory(to: UInt8.self).baseAddress,
                      let dst = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dst, destination.count, src, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count > 0, count + magic.count < original.count else { return original }
        output.count = count
        return magic + output
    }

    static func encodeManifest(_ original: Data) -> Data {
        guard original.count <= maxManifestBytes else { return original }
        let compressed = encode(original)
        guard compressed.starts(with: magic),
              compressed.count + standaloneMagic.count + 8 < original.count else { return original }
        var size = UInt64(original.count).bigEndian
        var result = standaloneMagic
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(compressed)
        return result
    }

    static func decodeManifest(_ stored: Data) throws -> Data {
        guard stored.starts(with: standaloneMagic) else { return stored }
        let header = standaloneMagic.count
        guard stored.count > header + 8 else { throw PhotoVaultError.invalidBackup }
        var size: UInt64 = 0
        for byte in stored[header..<(header + 8)] { size = (size << 8) | UInt64(byte) }
        guard size <= UInt64(maxManifestBytes) else { throw PhotoVaultError.invalidBackup }
        return try decode(Data(stored.dropFirst(header + 8)), expectedSize: Int64(size))
    }

    static func decode(_ stored: Data, expectedSize: Int64) throws -> Data {
        guard expectedSize >= 0, expectedSize <= Int64(Int.max) else { throw PhotoVaultError.invalidBackup }
        guard stored.starts(with: magic) else {
            guard stored.count == Int(expectedSize) else { throw PhotoVaultError.invalidBackup }
            return stored
        }
        guard expectedSize > 0, expectedSize < Int64(Int.max) else { throw PhotoVaultError.invalidBackup }
        let compressed = stored.dropFirst(magic.count)
        // 1バイト余分に確保し、申告サイズを超える展開も検出します。
        var output = Data(count: Int(expectedSize) + 1)
        let count = compressed.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard let src = source.bindMemory(to: UInt8.self).baseAddress,
                      let dst = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, destination.count, src, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count == Int(expectedSize), count > 0 else { throw PhotoVaultError.invalidBackup }
        output.count = count
        return output
    }
}
