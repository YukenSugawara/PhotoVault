import Foundation

/// ZIPへ格納するファイル名と復号済みデータの組です。
struct ZipEntry: Sendable {
    let filename: String
    let data: Data
}

/// 外部ライブラリを使わず、無圧縮ZIPを書き出します。
enum ZipArchive {
    private struct CentralRecord {
        let name: Data
        let crc32: UInt32
        let size: UInt32
        let offset: UInt32
    }

    /// ローカルヘッダー、中央ディレクトリ、終端レコードの順にZIPを構築します。
    static func make(entries: [ZipEntry]) throws -> Data {
        var output = Data()
        var centralRecords: [CentralRecord] = []
        var usedNames = Set<String>()

        for (index, entry) in entries.enumerated() {
            guard entry.data.count <= Int(UInt32.max), output.count <= Int(UInt32.max) else {
                throw PhotoVaultError.archiveTooLarge
            }
            let filename = uniqueFilename(entry.filename, fallbackIndex: index + 1, used: &usedNames)
            let name = Data(filename.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)

            output.appendLE(UInt32(0x04034b50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0x0800))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(crc)
            output.appendLE(size)
            output.appendLE(size)
            output.appendLE(UInt16(name.count))
            output.appendLE(UInt16(0))
            output.append(name)
            output.append(entry.data)
            centralRecords.append(CentralRecord(name: name, crc32: crc, size: size, offset: offset))
        }

        guard output.count <= Int(UInt32.max), centralRecords.count <= Int(UInt16.max) else {
            throw PhotoVaultError.archiveTooLarge
        }
        let centralOffset = UInt32(output.count)

        for record in centralRecords {
            output.appendLE(UInt32(0x02014b50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0x0800))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(record.crc32)
            output.appendLE(record.size)
            output.appendLE(record.size)
            output.appendLE(UInt16(record.name.count))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt32(0))
            output.appendLE(record.offset)
            output.append(record.name)
        }

        guard output.count <= Int(UInt32.max) else {
            throw PhotoVaultError.archiveTooLarge
        }
        let centralSize = UInt32(output.count) - centralOffset
        output.appendLE(UInt32(0x06054b50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(centralRecords.count))
        output.appendLE(UInt16(centralRecords.count))
        output.appendLE(centralSize)
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
        return output
    }

    /// 不正なパス文字や重複名を除き、ZIP内で安全な一意名を作ります。
    private static func uniqueFilename(_ original: String, fallbackIndex: Int, used: inout Set<String>) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\0")
        let components = original.components(separatedBy: invalid).filter { !$0.isEmpty }
        let cleaned = components.joined(separator: "_")
        let base = cleaned.isEmpty ? "photo-\(fallbackIndex).jpg" : cleaned
        var candidate = base
        var suffix = 2
        while used.contains(candidate.lowercased()) {
            let url = URL(fileURLWithPath: base)
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}

/// ZIP形式が要求するCRC-32チェックサムを計算します。
private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 {
                value = (value >> 1) ^ (value & 1 == 1 ? 0xEDB88320 : 0)
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
