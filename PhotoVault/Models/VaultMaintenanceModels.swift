import Foundation
import CoreGraphics
import ImageIO

/// iCloudのメタデータが明示している状態だけを採用します。
enum CloudFileState: String, Sendable {
    case uploaded, pending, unknown, failed

    var title: String {
        switch self {
        case .uploaded: "アップロード済み"
        case .pending: "同期中・待機中"
        case .unknown: "未確認"
        case .failed: "エラー・競合あり"
        }
    }

    static func evaluate(isUbiquitous: Bool?, uploaded: Bool?, uploading: Bool?,
                         hasError: Bool, hasConflict: Bool?) -> Self {
        if hasError || hasConflict == true { return .failed }
        guard isUbiquitous == true else { return .unknown }
        if uploading == true { return .pending }
        if uploaded == true { return .uploaded }
        return uploaded == false ? .pending : .unknown
    }
}

struct VaultCloudStatus: Sendable {
    let checkedAt: Date
    let location: StorageLocation
    let index: CloudFileState
    let uploadedPhotos: Int
    let pendingPhotos: Int
    let unknownPhotos: Int
    let failedPhotos: Int
}

struct TrashedPhoto: Codable, Identifiable, Sendable {
    var photo: PhotoRecord
    let deletedAt: Date
    let originalFolderName: String?
    // 完全削除開始後のI/O失敗でも、次回に残りのファイルを削除できるよう記録します。
    var deletionRequested: Bool? = nil
    var id: UUID { photo.id }
    var expiresAt: Date { deletedAt.addingTimeInterval(30 * 24 * 60 * 60) }
    func canRestore(at date: Date = .now) -> Bool {
        deletionRequested != true && expiresAt > date
    }
}

enum MaintenanceError: LocalizedError {
    case trashUnavailable, photoLimit, databaseChanged
    var errorDescription: String? {
        switch self {
        case .trashUnavailable: "復元期限を過ぎたか、完全削除を開始した写真です。"
        case .photoLimit: "無料版の写真枚数上限に達しています。"
        case .databaseChanged: "アルバムが別の処理や端末で更新されました。上書きを防ぐため保存を中止しました。アルバムをロックして開き直し、最新の内容を確認してください。"
        }
    }
}

struct DuplicatePhotoGroup: Identifiable, Sendable {
    let id: String
    let photos: [PhotoRecord]
    var recoverableBytes: Int64 {
        photos.dropFirst().reduce(0) { $0 + max(0, $1.originalByteCount) }
    }
}

struct DuplicateScanResult: Sendable {
    let groups: [DuplicatePhotoGroup]
    let inspectedCount: Int
    let failedCount: Int
}

struct VaultStorageStatus: Sendable {
    let checkedAt: Date
    let originalBytes: Int64
    let trashBytes: Int64
    let encryptedFileBytes: Int64?
    let thumbnailBytes: Int64?
    let indexBytes: Int64?
    let cacheBytes: Int64?
}

/// 小さな輝度画像の傾きと明るさを比較します。写真の同一性を保証する判定ではありません。
struct SimilarImageFingerprint: Sendable {
    let gradient: UInt64
    let luminance: [UInt8]

    init(pixels: [UInt8]) {
        precondition(pixels.count == 72)
        luminance = pixels
        var bits: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 where pixels[y * 9 + x] > pixels[y * 9 + x + 1] {
                bits |= UInt64(1) << (y * 8 + x)
            }
        }
        gradient = bits
    }

    init(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        var pixels = [UInt8](repeating: 0, count: 72)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8,
                                          bitsPerComponent: 8, bytesPerRow: 9,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard rendered else { throw CocoaError(.fileReadCorruptFile) }
        self.init(pixels: pixels)
    }

    func resembles(_ other: Self) -> Bool {
        let differences = zip(luminance, other.luminance).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return (gradient ^ other.gradient).nonzeroBitCount <= 6 && differences <= 72 * 24
    }
}

struct SimilarPhotoGroup: Identifiable, Sendable {
    let id: UUID
    let photos: [PhotoRecord]
}

struct SimilarPhotoScanResult: Sendable {
    let groups: [SimilarPhotoGroup]
    let inspectedCount: Int
    let failedCount: Int
}

/// 復元失敗を断定しすぎず、取得・復号・形式のどこで止まったかを案内します。
enum CloudRestoreReadError: LocalizedError {
    case cannotDecrypt, cannotDecode
    var errorDescription: String? {
        switch self {
        case .cannotDecrypt:
            "[PV-RESTORE-KEY] iCloudの管理データは取得できましたが、保存されている認証情報では開けませんでした。認証情報とデータの組み合わせが異なるか、データが破損している可能性があります。新しいアルバムの作成やデータ消去は行わず、この内容をお問い合わせください。"
        case .cannotDecode:
            "[PV-RESTORE-FORMAT] 管理データの暗号化は解除できましたが、内容を読み取れませんでした。未対応のデータ形式または破損の可能性があります。この内容をお問い合わせください。"
        }
    }
}

/// ファイルパスや認証情報を追加せず、OSエラーの分類に必要な識別子だけを補足します。
enum CloudRestoreDiagnostics {
    static let readDetailsKey = "PhotoVault.ReadFailureDetails"
    static let downloadDetailsKey = "PhotoVault.DownloadFailureDetails"

    /// コードと下位エラーを維持し、不在ファイルの再試行判定を変えずに失敗箇所を付けます。
    static func atStage<T>(_ stage: String, operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch {
            if error is CancellationError { throw error }
            if case PhotoVaultError.iCloudDownloadPending = error { throw error }
            let original = error as NSError
            var info = original.userInfo
            info[NSLocalizedDescriptionKey] = "[PV-RECONNECT: \(stage)]\n\(original.localizedDescription)"
            throw NSError(domain: original.domain, code: original.code, userInfo: info)
        }
    }


    static func message(for error: Error) -> String {
        var details = [error.localizedDescription]
        let root = error as NSError
        if (root.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(root.code))
            || (root.domain == NSPOSIXErrorDomain && root.code == 2) {
            details.append("iCloudの管理ファイルを現在の保存先で確認できません。まだ同期されていない場合のほか、以前の保存先が端末内だった可能性もあります。このエラーだけで写真が削除されたとは判断できません。")
        }
        var current: NSError? = error as NSError
        for _ in 0..<3 {
            guard let value = current else { break }
            details.append("エラーコード：\(value.domain) / \(value.code)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if let read = root.userInfo[readDetailsKey] as? String {
            details.append("【ダウンロード要求前の読み取り】\n" + read)
        }
        if let download = root.userInfo[downloadDetailsKey] as? String {
            details.append("【ダウンロード開始要求】\n" + download)
        }
        return details.joined(separator: "\n")
    }
}


// 初期化後も以前の鍵とファイルを上書きしない、端末専用の独立した保存領域。
enum LocalRestartState {
    static let namespaceKey = "vault.local-restart-namespace"
    static var namespace: String? {
        guard let value = UserDefaults.standard.string(forKey: namespaceKey),
              UUID(uuidString: value) != nil else { return nil }
        return value
    }
    static var isActive: Bool { namespace != nil }
    static func account(_ original: String) -> String {
        namespace.map { original + ".restart." + $0 } ?? original
    }
    static var directory: String { namespace.map { "PhotoVault-Restart/" + $0 } ?? "PhotoVault" }
    static func requireCloudAccess() throws {
        if isActive { throw LocalRestartError.localOnly }
    }
}
enum LocalRestartError: LocalizedError {
    case localOnly, uploadUnconfirmed
    var errorDescription: String? {
        switch self {
        case .localOnly:
            "初期化後は端末保存専用です。以前のiCloudデータと復元用情報を保護するため、iCloudへの切り替えはできません。端末内の写真はバックアップを書き出して保管してください。"
        case .uploadUnconfirmed:
            "iCloudへの同期完了を確認できないため、元写真は削除していません。設定のバックアップ状況を確認してください。"
        }
    }
}

extension VaultCloudStatus {
    var allowsOriginalDeletion: Bool {
        location == .iCloud && index == .uploaded
            && pendingPhotos == 0 && unknownPhotos == 0 && failedPhotos == 0
    }
}


struct RetainedBackupSummary: Identifiable, Sendable {
    let id: String
    let createdAt: Date
    let photoCount: Int
}


/// 日時は端末の現在のタイムゾーンで解釈します。
enum DailyBackupSchedule {
    static let enabledKey = "backup.daily.enabled"
    static let minuteKey = "backup.daily.minute"
    static let defaultMinute = 2 * 60

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    static func minuteOfDay(defaults: UserDefaults = .standard) -> Int {
        guard let value = defaults.object(forKey: minuteKey) as? Int, (0..<1440).contains(value) else {
            return defaultMinute
        }
        return value
    }

    /// 今日の指定時刻を過ぎて未成功なら即実行。今日成功済みなら明日まで待つ。
    static func nextRun(now: Date, lastSuccess: Date?, minuteOfDay: Int,
                        calendar: Calendar = .current) -> Date {
        let minute = (0..<1440).contains(minuteOfDay) ? minuteOfDay : defaultMinute
        let start = calendar.startOfDay(for: now)
        let today = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                                  of: start, matchingPolicy: .nextTime,
                                  repeatedTimePolicy: .first, direction: .forward) ?? start
        if let lastSuccess, calendar.isDate(lastSuccess, inSameDayAs: now) {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86400)
            return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                                 of: tomorrow, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first, direction: .forward) ?? tomorrow
        }
        return now >= today ? now : today
    }
}
