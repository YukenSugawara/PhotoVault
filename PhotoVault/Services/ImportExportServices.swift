import Foundation
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// ImageIOから読み出した、検索・詳細表示用の写真情報です。
struct ImageMetadataSnapshot: Sendable {
    let capturedAt: Date?
    let cameraMake: String?
    let cameraModel: String?
    let lensModel: String?
    let focalLength35mm: Double?
    let aperture: Double?
    let exposureTime: Double?
    let isoSpeed: Int?
}

/// 画像のEXIF／TIFF情報を、元画像を再エンコードせずに読み取ります。
enum ImageMetadataService {
    static func read(from data: Data) -> ImageMetadataSnapshot {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            return emptySnapshot
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let capturedAt = parseExifDate(
            exif[kCGImagePropertyExifDateTimeOriginal] as? String
                ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
                ?? tiff[kCGImagePropertyTIFFDateTime] as? String
        )

        return ImageMetadataSnapshot(
            capturedAt: capturedAt,
            cameraMake: clean(tiff[kCGImagePropertyTIFFMake] as? String),
            cameraModel: clean(tiff[kCGImagePropertyTIFFModel] as? String),
            lensModel: clean(
                exif[kCGImagePropertyExifLensModel] as? String
                    ?? exifAux[kCGImagePropertyExifAuxLensModel] as? String
            ),
            focalLength35mm: number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]),
            aperture: number(exif[kCGImagePropertyExifFNumber]),
            exposureTime: number(exif[kCGImagePropertyExifExposureTime]),
            isoSpeed: integer(from: exif[kCGImagePropertyExifISOSpeedRatings])
        )
    }

    private static var emptySnapshot: ImageMetadataSnapshot {
        ImageMetadataSnapshot(
            capturedAt: nil,
            cameraMake: nil,
            cameraModel: nil,
            lensModel: nil,
            focalLength35mm: nil,
            aperture: nil,
            exposureTime: nil,
            isoSpeed: nil
        )
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        return nil
    }

    private static func integer(from value: Any?) -> Int? {
        if let values = value as? [NSNumber] { return values.first?.intValue }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    /// EXIFの日付は一般的な「yyyy:MM:dd HH:mm:ss」形式を優先して解釈します。
    private static func parseExifDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

/// Visionの文字認識をバックグラウンドで実行し、検索用のプレーンテキストを返します。
enum ImageOCRService {
    static func recognizeText(in data: Data) async -> String {
        await Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return "" }

            // 巨大なRAW等をそのまま展開せず、OCRには長辺2,048pxの解析画像を使います。
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return ""
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                let supported = try request.supportedRecognitionLanguages()
                let preferredLanguages = ["ja-JP", "en-US"].filter(supported.contains)
                if !preferredLanguages.isEmpty {
                    request.recognitionLanguages = preferredLanguages
                }
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                guard !Task.isCancelled else { return "" }
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                // 管理DBが際限なく大きくならないよう、検索には先頭20,000文字を保存します。
                return String(lines.joined(separator: "\n").prefix(20_000))
            } catch {
                // OCRできない形式も写真自体は問題なく利用できるため、解析済みの空文字として扱います。
                return ""
            }
        }.value
    }
}

/// 位置情報、撮影機器、撮影日時等を除いた共有用コピーをImageIOで作ります。
enum ImagePrivacyService {
    struct Result: Sendable {
        let data: Data
        let contentType: UTType
    }

    static func removingMetadata(from data: Data, originalType: UTType) throws -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw PhotoVaultError.metadataRemovalFailed
        }

        let supportedTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        let outputType: UTType
        if supportedTypes.contains(originalType.identifier) {
            outputType = originalType
        } else {
            // 書き出し非対応のRAW等は、解像度を維持した最高品質JPEGとして共有します。
            outputType = .jpeg
        }

        let output = NSMutableData()
        let imageCount = outputType == originalType ? CGImageSourceGetCount(source) : 1
        guard let destination = CGImageDestinationCreateWithData(
            output,
            outputType.identifier as CFString,
            imageCount,
            nil
        ) else {
            throw PhotoVaultError.metadataRemovalFailed
        }
        for index in 0..<imageCount {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw PhotoVaultError.metadataRemovalFailed
            }

            // Sourceから圧縮データを直接コピーすると未知のメタデータが残る可能性があります。
            // 画素だけを取り出して新規ファイルへ書き、表示方向以外の撮影情報は引き継ぎません。
            let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any] ?? [:]
            var outputProperties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 1.0,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true
            ]
            if let orientation = sourceProperties[kCGImagePropertyOrientation] {
                outputProperties[kCGImagePropertyOrientation] = orientation
            }
            CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw PhotoVaultError.metadataRemovalFailed
        }
        return Result(data: output as Data, contentType: outputType)
    }
}

/// バックアップ専用パスワードで、アルバム全体を端末鍵から独立して暗号化します。
enum VaultBackupCodec {
    private static let magic = Data("PVBACKUP2".utf8)
    private static let saltLength = 16

    static func seal(_ payload: VaultBackupPayload, password: String) throws -> Data {
        guard password.count >= 8 else { throw PhotoVaultError.backupPasswordTooShort }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(payload)
        let salt = try CryptoBox.randomData(count: saltLength)
        let key = try KeyDerivation.deriveKey(password: password, salt: salt)
        var output = magic
        output.append(salt)
        output.append(try CryptoBox.seal(plaintext, using: key))
        return output
    }

    static func open(_ backup: Data, password: String) throws -> VaultBackupPayload {
        guard password.count >= 8 else { throw PhotoVaultError.backupPasswordTooShort }
        let headerLength = magic.count + saltLength
        guard backup.count > headerLength,
              backup.subdata(in: 0..<magic.count) == magic else {
            throw PhotoVaultError.invalidBackup
        }

        do {
            let salt = backup.subdata(in: magic.count..<headerLength)
            let ciphertext = backup.subdata(in: headerLength..<backup.count)
            let key = try KeyDerivation.deriveKey(password: password, salt: salt)
            let plaintext = try CryptoBox.open(ciphertext, using: key)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(VaultBackupPayload.self, from: plaintext)
            guard [1, 2].contains(payload.formatVersion),
                  payload.photos.count == payload.database.allStoredPhotos.count else {
                throw PhotoVaultError.invalidBackup
            }
            return payload
        } catch let error as PhotoVaultError {
            throw error
        } catch {
            throw PhotoVaultError.invalidBackup
        }
    }
}

/// 写真ピッカー／ファイル選択の結果を共通の取り込み形式へ変換します。
enum ImageImportService {
    /// PhotosPickerItemから元形式の画像データを非同期で読み込みます。
    static func load(_ item: PhotosPickerItem) async throws -> ImportedImage {
        // PhotosPickerがライブラリIDを返した場合はPHAsset経由で読み込み、
        // Appleの写真ライブラリが保持する元ファイル名も一緒に引き継ぎます。
        if let identifier = item.itemIdentifier,
           let asset = PHAsset.fetchAssets(
               withLocalIdentifiers: [identifier],
               options: nil
           ).firstObject {
            return try await load(asset)
        }

        // IDを取得できない共有写真などでは元ファイル名へアクセスできないため、
        // 元データと拡張子を維持した安全な代替名を使用します。
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw PhotoVaultError.invalidImage
        }
        let declaredType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .image
        let type = detectedContentType(in: data) ?? declaredType
        let ext = type.preferredFilenameExtension ?? "image"
        let filename = "photo-\(UUID().uuidString.prefix(8)).\(ext)"
        return ImportedImage(
            data: data,
            filename: filename,
            contentType: type,
            photoLibraryIdentifier: item.itemIdentifier
        )
    }

    /// 専用選択画面で選ばれたPhotoKitアセットから、再圧縮せず元データを読み込みます。
    /// iCloud上にだけ存在する写真も取得できるよう、ネットワークアクセスを許可します。
    static func load(_ asset: PHAsset) async throws -> ImportedImage {
        let resources = PHAssetResource.assetResources(for: asset)
        // `.photo`は写真ライブラリの元リソースです。編集済み写真などで取得できない場合だけ
        // `.fullSizePhoto`へフォールバックし、可能な限り元ファイル名と元データを優先します。
        guard let resource = resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first else {
            throw PhotoVaultError.photoLibraryAssetNotFound
        }

        let accumulator = AssetDataAccumulator()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in
                    // PhotoKitは分割データを複数回返すため、ロック内で安全に連結します。
                    accumulator.append(chunk)
                },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: accumulator.snapshot())
                    }
                }
            )
        }

        guard !data.isEmpty else { throw PhotoVaultError.invalidImage }
        let declaredType = UTType(resource.uniformTypeIdentifier) ?? .image
        let type = detectedContentType(in: data) ?? declaredType
        guard type.conforms(to: .image) else { throw PhotoVaultError.unsupportedImage }
        let fallbackExtension = type.preferredFilenameExtension ?? "image"
        let filename = resource.originalFilename.isEmpty
            ? "photo-\(UUID().uuidString.prefix(8)).\(fallbackExtension)"
            : resource.originalFilename

        return ImportedImage(
            data: data,
            filename: filename,
            contentType: type,
            photoLibraryIdentifier: asset.localIdentifier
        )
    }

    /// サンドボックス外の選択ファイルへ一時的にアクセスして読み込みます。
    static func load(_ url: URL) throws -> ImportedImage {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let declaredType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
            ?? .data
        let type = detectedContentType(in: data) ?? declaredType
        guard type.conforms(to: .image) else { throw PhotoVaultError.unsupportedImage }
        return ImportedImage(
            data: data,
            filename: url.lastPathComponent,
            contentType: type,
            photoLibraryIdentifier: nil
        )
    }

    /// 拡張子ではなく元データのImageIO識別子を優先し、共有・出力時にも正しい形式名を保ちます。
    private static func detectedContentType(in data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) else {
            return nil
        }
        return UTType(identifier as String)
    }

    /// PhotoKitの分割コールバックから受け取る元画像データを直列化します。
    private final class AssetDataAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
}

/// 取り込み元の写真を、Apple標準の確認画面を経由して削除します。
enum PhotoDeletionService {
    /// 読み書き権限を確認し、保存済み写真に対応する元アセットの削除を依頼します。
    static func requestDeletion(identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PhotoVaultError.photoLibraryAccessDenied
        }

        // 重複した選択をまとめ、PhotoKitが認識できる元写真だけを取得します。
        let uniqueIdentifiers = Array(Set(identifiers))
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIdentifiers, options: nil)
        guard assets.count == uniqueIdentifiers.count else {
            throw PhotoVaultError.photoLibraryAssetNotFound
        }

        // 実際の削除前には、OSがユーザーへ標準の確認画面を表示します。
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}

/// SwiftUIのfileExporterへZIPデータを渡すためのドキュメント型です。
struct ArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var data = Data()

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    /// Finder／ファイルアプリで通常の画像やZIPと区別する暗号化バックアップ形式です。
    static let photoVaultBackup = UTType(exportedAs: "jp.photovault.encrypted-backup", conformingTo: .data)
}

/// SwiftUIのfileExporter／fileImporterへ暗号化バックアップを受け渡します。
struct VaultBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.photoVaultBackup] }
    var data = Data()

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
