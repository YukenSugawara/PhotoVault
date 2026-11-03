import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 独立した暗号鍵と管理DBを持つアルバムの種類です。
enum VaultKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case main
    case sub

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .main: "メインアルバム"
        case .sub: "サブアルバム"
        }
    }

    var symbolName: String {
        switch self {
        case .main: "photo.stack.fill"
        case .sub: "rectangle.stack.fill"
        }
    }
}

/// 暗号化データを保存する物理的な場所です。
enum StorageLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case iCloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: "この端末"
        case .iCloud: "iCloud"
        }
    }

    var symbolName: String {
        switch self {
        case .local: "internaldrive.fill"
        case .iCloud: "icloud.fill"
        }
    }
}

/// 写真一覧でユーザーが選択できる表示形式です。
enum AlbumLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case comfortableGrid
    case compactGrid
    case list

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .comfortableGrid: "大きいグリッド"
        case .compactGrid: "小さいグリッド"
        case .list: "リスト"
        }
    }

    var symbolName: String {
        switch self {
        case .comfortableGrid: "square.grid.2x2"
        case .compactGrid: "square.grid.3x3"
        case .list: "list.bullet"
        }
    }
}

/// 写真一覧で選択できる並び順です。
/// 既存DBとの互換性を保つためrawValueは変更せず、画面上では「日付順／名前順」と表示します。
enum PhotoSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst
    case filenameAscending
    case filenameDescending

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newestFirst: "日付順（新しいものから）"
        case .oldestFirst: "日付順（古いものから）"
        case .filenameAscending: "名前順（昇順）"
        case .filenameDescending: "名前順（降順）"
        }
    }
}

/// フォルダ一覧で選択できる並び順です。
/// 作成日時またはフォルダ名を基準にし、同じ値の場合はIDで順序を固定して表示の揺れを防ぎます。
enum FolderSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst
    case nameAscending
    case nameDescending

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newestFirst: "日付順（新しいものから）"
        case .oldestFirst: "日付順（古いものから）"
        case .nameAscending: "名前順（昇順）"
        case .nameDescending: "名前順（降順）"
        }
    }
}

/// アプリがバックグラウンドへ移ったあと、暗号鍵を破棄するまでの時間です。
enum AutoLockInterval: String, CaseIterable, Identifiable, Hashable, Sendable {
    case immediately
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .immediately: "すぐにロック"
        case .oneMinute: "1分後"
        case .fiveMinutes: "5分後"
        case .fifteenMinutes: "15分後"
        case .never: "自動ロックしない"
        }
    }

    /// nilは自動ロックしない設定を表します。
    var seconds: TimeInterval? {
        switch self {
        case .immediately: 0
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .never: nil
        }
    }
}

/// 写真を共有するときに適用するプライバシー設定です。
enum PhotoShareMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case original
    case removingMetadata

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: "元画質で共有"
        case .removingMetadata: "位置情報などを削除して共有"
        }
    }

    var symbolName: String {
        switch self {
        case .original: "photo.badge.checkmark"
        case .removingMetadata: "location.slash.fill"
        }
    }
}

/// 容量別スマートフォルダで使用する、固定のファイルサイズ範囲です。
enum PhotoSizeCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: "5 MB未満"
        case .medium: "5〜20 MB"
        case .large: "20 MB以上"
        }
    }

    func contains(byteCount: Int64) -> Bool {
        let fiveMB: Int64 = 5 * 1_024 * 1_024
        let twentyMB: Int64 = 20 * 1_024 * 1_024
        switch self {
        // このメソッドは閾値の定義後にswitchするため、各分岐で戻り値を明示します。
        case .small:
            return byteCount < fiveMB
        case .medium:
            return byteCount >= fiveMB && byteCount < twentyMB
        case .large:
            return byteCount >= twentyMB
        }
    }
}

/// 実フォルダを増やさず、写真情報からその場で絞り込むスマートフォルダです。
enum SmartFolderFilter: Hashable, Sendable {
    case year(Int)
    case month(year: Int, month: Int)
    case format(String)
    case size(PhotoSizeCategory)

    var displayName: String {
        switch self {
        // format分岐だけが複数行でも、すべての分岐から確実にStringを返すよう明示します。
        case .year(let year):
            return "\(year)年"
        case .month(let year, let month):
            return "\(year)年\(month)月"
        case .format(let identifier):
            let extensionName = UTType(identifier)?.preferredFilenameExtension?.uppercased()
            return extensionName ?? "その他"
        case .size(let category):
            return category.displayName
        }
    }

    var symbolName: String {
        switch self {
        case .year: "calendar"
        case .month: "calendar.badge.clock"
        case .format: "doc.richtext"
        case .size: "externaldrive.fill"
        }
    }

    func matches(_ photo: PhotoRecord, calendar: Calendar = .current) -> Bool {
        switch self {
        case .year(let year):
            return calendar.component(.year, from: photo.effectiveCaptureDate) == year
        case .month(let year, let month):
            let components = calendar.dateComponents([.year, .month], from: photo.effectiveCaptureDate)
            return components.year == year && components.month == month
        case .format(let identifier):
            return photo.contentTypeIdentifier == identifier
        case .size(let category):
            return category.contains(byteCount: photo.originalByteCount)
        }
    }
}

/// 画面の背景とアクセントカラーの組み合わせです。
enum AppTheme: String, CaseIterable, Identifiable {
    case midnight
    case ocean
    case forest
    case rose
    case sunset
    case lavender
    case graphite
    case gold

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .midnight: "ミッドナイト"
        case .ocean: "オーシャン"
        case .forest: "フォレスト"
        case .rose: "ローズ"
        case .sunset: "サンセット"
        case .lavender: "ラベンダー"
        case .graphite: "グラファイト"
        case .gold: "ゴールド"
        }
    }

    var tint: Color {
        switch self {
        case .midnight: Color(red: 0.38, green: 0.42, blue: 0.95)
        case .ocean: Color(red: 0.02, green: 0.55, blue: 0.78)
        case .forest: Color(red: 0.12, green: 0.58, blue: 0.36)
        case .rose: Color(red: 0.88, green: 0.28, blue: 0.48)
        case .sunset: Color(red: 0.95, green: 0.38, blue: 0.20)
        case .lavender: Color(red: 0.62, green: 0.42, blue: 0.86)
        case .graphite: Color(red: 0.33, green: 0.38, blue: 0.45)
        case .gold: Color(red: 0.78, green: 0.57, blue: 0.10)
        }
    }
}

/// 設定画面から切り替えられるアルバム風アイコンです。
enum AppIconStyle: String, CaseIterable, Identifiable {
    case standard
    case indigo
    case rose
    case emerald
    case sunset
    case sky

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "ブラック"
        case .indigo: "インディゴ"
        case .rose: "ローズ"
        case .emerald: "エメラルド"
        case .sunset: "サンセット"
        case .sky: "スカイ"
        }
    }

    var alternateIconName: String? {
        switch self {
        case .standard: nil
        case .indigo: "AppIconIndigo"
        case .rose: "AppIconRose"
        case .emerald: "AppIconEmerald"
        case .sunset: "AppIconSunset"
        case .sky: "AppIconSky"
        }
    }

}

/// 生体認証に成功したあと、どのアルバムを開くかを表す設定です。
enum BiometricUnlockDestination: String, CaseIterable, Identifiable, Sendable {
    case chooseEveryTime
    case main
    case sub

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chooseEveryTime: "毎回選択"
        case .main: VaultKind.main.displayName
        case .sub: VaultKind.sub.displayName
        }
    }
}

/// PIN照合情報と、PINで包んだマスター鍵を保持します。PINそのものは保存しません。
struct VaultProfile: Codable, Sendable {
    let kind: VaultKind
    let salt: Data
    let passwordVerifier: Data
    let wrappedMasterKey: Data
    let createdAt: Date
}

/// ユーザーが写真を分類するためのフォルダ情報です。
struct AlbumFolder: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    /// nilは最上位、値がある場合は親フォルダのIDです。optionalなので旧DBも移行なしで復号できます。
    var parentID: UUID?

    init(id: UUID = UUID(), name: String, createdAt: Date = .now, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.parentID = parentID
    }
}

/// 暗号化ファイルを特定するためにDBへ保存する写真メタデータです。
struct PhotoRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var folderID: UUID?
    let originalFilename: String
    let encryptedFilename: String
    let encryptedThumbnailFilename: String
    let contentTypeIdentifier: String
    let addedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let originalByteCount: Int64
    /// 元データ全体のSHA-256。ファイル名や保存先が違っても同一画像を判定できます。
    var contentDigest: String?
    /// 写真ライブラリから取り込んだ場合のアセットID。再選択時の早い重複判定に使います。
    var sourceAssetIdentifier: String?
    /// ImageIOから取得した撮影日時。情報がない画像では追加日時を代わりに使用します。
    var capturedAt: Date? = nil
    var cameraMake: String? = nil
    var cameraModel: String? = nil
    var lensModel: String? = nil
    var focalLength35mm: Double? = nil
    var aperture: Double? = nil
    var exposureTime: Double? = nil
    var isoSpeed: Int? = nil
    /// Visionで認識した文字列。nilは未解析、空文字は解析済みで文字なしを表します。
    var ocrText: String? = nil
    var ocrIndexedAt: Date? = nil

    var displayFilename: String {
        originalFilename.isEmpty ? "画像" : originalFilename
    }

    var effectiveCaptureDate: Date { capturedAt ?? addedAt }

    var displayFormat: String {
        UTType(contentTypeIdentifier)?.preferredFilenameExtension?.uppercased() ?? "画像"
    }

    var cameraDescription: String? {
        let components = [cameraMake, cameraModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: " ")
    }
}

/// 1つのアルバムに属するフォルダ、写真、表示設定をまとめた管理DBです。
struct VaultDatabase: Codable, Sendable {
    var schemaVersion = 8
    var folders: [AlbumFolder] = []
    var photos: [PhotoRecord] = []
    /// Optionalなのでゴミ箱のない旧DBも読み込めます。
    var trash: [TrashedPhoto]?
    var allStoredPhotos: [PhotoRecord] { photos + (trash ?? []).map(\.photo) }
    var trashByteCount: Int64 { (trash ?? []).reduce(0) { $0 + max(0, $1.photo.originalByteCount) } }
    // 旧版DBとの互換性を保つため残しています。open時にフォルダ別設定へ移行します。
    var featuredPhotoID: UUID?
    var showsFeaturedPhoto = false
    var albumLayout: AlbumLayout = .comfortableGrid
    var deletesOriginalAfterImport = false
    var folderFeaturedPhotoIDs: [UUID: UUID]?
    var photoSortOrder: PhotoSortOrder?
    /// optionalにしておくことで、フォルダ並び順を持たない旧DBもそのまま復号できます。
    var folderSortOrder: FolderSortOrder?
    var slideshowEnabled: Bool?

    static let empty = VaultDatabase()

    /// 指定フォルダの写真を新しい順で返します。nilの場合は全写真です。
    func photos(in folderID: UUID?) -> [PhotoRecord] {
        let matches: [PhotoRecord]
        if let folderID {
            matches = photos.filter { $0.folderID == folderID }
        } else {
            matches = photos
        }
        switch effectivePhotoSortOrder {
        case .newestFirst:
            return matches.sorted {
                if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        case .oldestFirst:
            return matches.sorted {
                if $0.addedAt != $1.addedAt { return $0.addedAt < $1.addedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        case .filenameAscending:
            return matches.sorted {
                let comparison = $0.displayFilename.localizedStandardCompare($1.displayFilename)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return $0.id.uuidString < $1.id.uuidString
            }
        case .filenameDescending:
            return matches.sorted {
                let comparison = $0.displayFilename.localizedStandardCompare($1.displayFilename)
                if comparison != .orderedSame { return comparison == .orderedDescending }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    var effectivePhotoSortOrder: PhotoSortOrder {
        photoSortOrder ?? .newestFirst
    }

    /// 設定された順序でフォルダを返します。旧DBでは作成日時の新しい順を使用します。
    var sortedFolders: [AlbumFolder] {
        folders.sorted { first, second in
            switch effectiveFolderSortOrder {
            case .newestFirst:
                if first.createdAt != second.createdAt { return first.createdAt > second.createdAt }
            case .oldestFirst:
                if first.createdAt != second.createdAt { return first.createdAt < second.createdAt }
            case .nameAscending:
                let comparison = first.name.localizedStandardCompare(second.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .nameDescending:
                let comparison = first.name.localizedStandardCompare(second.name)
                if comparison != .orderedSame { return comparison == .orderedDescending }
            }
            return first.id.uuidString < second.id.uuidString
        }
    }

    var effectiveFolderSortOrder: FolderSortOrder {
        folderSortOrder ?? .newestFirst
    }

    /// 指定した親の直下にあるフォルダだけを、現在の設定順で返します。
    func childFolders(of parentID: UUID?) -> [AlbumFolder] {
        sortedFolders.filter { $0.parentID == parentID }
    }

    /// 削除・集計・出力で使うため、指定フォルダ自身とすべての子孫IDを循環に強い反復処理で集めます。
    func folderIDs(includingDescendantsOf folderID: UUID) -> Set<UUID> {
        var result: Set<UUID> = [folderID]
        var pending = [folderID]
        while let parentID = pending.popLast() {
            for child in folders where child.parentID == parentID {
                if result.insert(child.id).inserted {
                    pending.append(child.id)
                }
            }
        }
        return result
    }

    /// 指定フォルダとすべてのサブフォルダ内にある写真を、写真の並び替え設定を保って返します。
    func photos(inFolderTree folderID: UUID) -> [PhotoRecord] {
        let folderIDs = folderIDs(includingDescendantsOf: folderID)
        return photos(in: nil).filter { photo in
            guard let photoFolderID = photo.folderID else { return false }
            return folderIDs.contains(photoFolderID)
        }
    }

    var effectiveSlideshowEnabled: Bool {
        slideshowEnabled ?? true
    }

    /// 現在のアルバムが保持する元画像の合計容量です。
    var totalOriginalByteCount: Int64 {
        photos.reduce(0) { $0 + max($1.originalByteCount, 0) }
    }

    /// 指定条件に一致する写真へ、現在の並び順をそのまま適用します。
    func photos(matching filter: SmartFolderFilter) -> [PhotoRecord] {
        let matchingIDs = Set(photos.filter { filter.matches($0) }.map(\.id))
        return photos(in: nil).filter { matchingIDs.contains($0.id) }
    }

    /// フォルダごとの写真枚数を1回の走査で集計し、一覧表示の再計算を減らします。
    var photoCountsByFolder: [UUID: Int] {
        photos.reduce(into: [:]) { counts, photo in
            guard let folderID = photo.folderID else { return }
            counts[folderID, default: 0] += 1
        }
    }

    /// フォルダカードには、その配下のサブフォルダを含めた合計写真枚数を表示します。
    var photoCountsByFolderTree: [UUID: Int] {
        let directCounts = photoCountsByFolder
        let parentByID = folders.reduce(into: [UUID: UUID]()) { result, folder in
            if let parentID = folder.parentID { result[folder.id] = parentID }
        }
        var totals = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, 0) })

        // 直接枚数を親方向へ加算するため、フォルダごとに全子孫を再探索しません。
        for (folderID, count) in directCounts {
            var currentID: UUID? = folderID
            var visited = Set<UUID>()
            while let id = currentID, visited.insert(id).inserted {
                totals[id, default: 0] += count
                currentID = parentByID[id]
            }
        }
        return totals
    }

    /// フォルダごとの代表写真をまとめて返し、カードごとの繰り返し検索を避けます。
    var featuredPhotosByFolder: [UUID: PhotoRecord] {
        guard let featuredIDs = folderFeaturedPhotoIDs, !featuredIDs.isEmpty else { return [:] }
        let photosByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        return featuredIDs.reduce(into: [:]) { result, entry in
            guard let photo = photosByID[entry.value], photo.folderID == entry.key else { return }
            result[entry.key] = photo
        }
    }

    /// 指定フォルダの代表画像を返します。
    func featuredPhoto(in folderID: UUID) -> PhotoRecord? {
        guard let photoID = folderFeaturedPhotoIDs?[folderID] else { return nil }
        return photos.first { $0.id == photoID && $0.folderID == folderID }
    }
}

/// 写真ライブラリまたはファイル選択から受け取った未暗号化の一時データです。
struct ImportedImage: Sendable {
    let data: Data
    let filename: String
    let contentType: UTType
    let photoLibraryIdentifier: String?
}

/// バックアップ内では元画像だけを平文JSONへまとめ、ファイル全体を後段でAES-GCM暗号化します。
struct VaultBackupPhoto: Codable, Sendable {
    let record: PhotoRecord
    let originalData: Data
}

/// 端末固有Keychainに依存せず復元できる、1アルバム分のバックアップ内容です。
struct VaultBackupPayload: Codable, Sendable {
    let formatVersion: Int
    let createdAt: Date
    let sourceVaultKind: VaultKind
    let database: VaultDatabase
    let photos: [VaultBackupPhoto]
}

/// メインのフォルダ一覧から遷移できる画面を表します。
enum MainRoute: Hashable {
    case folder(UUID)
    case smartFolders
    case smartFolder(SmartFolderFilter)
    case ocrSearch
    case settings
}

/// ユーザーへ日本語で表示するアプリ固有エラーです。
enum PhotoVaultError: LocalizedError {
    case invalidPassword
    case passwordsMustDiffer
    case passwordTooShort
    case credentialsMissing
    case biometricUnavailable
    case biometricKeyMissing
    case invalidImage
    case unsupportedImage
    case photoLibraryAccessDenied
    case photoLibraryAssetNotFound
    case iCloudDisabledInDebug
    case iCloudUnavailable
    case iCloudDownloadPending
    case iCloudIndexNotReady
    case destinationContainsVault
    case databaseCorrupted
    case archiveTooLarge
    case sharePreparationFailed
    case metadataRemovalFailed
    case backupPasswordTooShort
    case invalidBackup
    case backupRestoreFailed
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPassword: "PINが違います。"
        case .passwordsMustDiffer: "2つのアルバムには異なるPINを設定してください。"
        case .passwordTooShort: "PINは4〜6桁の数字にしてください。"
        case .credentialsMissing: "アルバムの認証情報が見つかりません。"
        case .biometricUnavailable: "Face IDまたはTouch IDを利用できません。"
        case .biometricKeyMissing: "この端末でアルバムを開くための鍵が見つかりません。"
        case .invalidImage: "画像ファイルとして読み込めませんでした。"
        case .unsupportedImage: "この画像形式は端末で認識できません。"
        case .photoLibraryAccessDenied: "元写真を削除するには、設定で写真ライブラリへのアクセスを許可してください。"
        case .photoLibraryAssetNotFound: "削除対象の元写真を写真ライブラリで確認できませんでした。"
        case .iCloudDisabledInDebug: "デバッグ版ではiCloud保存を無効にしています。"
        case .iCloudUnavailable: "iCloud Driveを利用できません。端末のiCloud設定を確認してください。"
        case .iCloudDownloadPending: "iCloudからのダウンロードを待っています。通信状態を確認して再試行してください。"
        case .iCloudIndexNotReady: "iCloudの一覧を確認中です。読み込み完了後にもう一度操作してください。"
        case .destinationContainsVault: "切り替え先にも写真があるため、自動移行を中止しました。データを失わないよう、先にどちらかのアルバムをZIP出力してください。"
        case .databaseCorrupted: "アルバムの管理データを読み込めませんでした。"
        case .archiveTooLarge: "出力するデータがZIP形式の上限を超えています。"
        case .sharePreparationFailed: "共有する元画像データを準備できませんでした。"
        case .metadataRemovalFailed: "位置情報などを削除した共有用画像を作成できませんでした。"
        case .backupPasswordTooShort: "バックアップ用パスワードは8文字以上にしてください。"
        case .invalidBackup: "バックアップを開けません。ファイルまたはパスワードを確認してください。"
        case .backupRestoreFailed: "バックアップを安全に復元できませんでした。元のアルバムは変更していません。"
        case .importFailed(let reason): "画像を取り込めませんでした。\n\(reason)"
        }
    }
}
