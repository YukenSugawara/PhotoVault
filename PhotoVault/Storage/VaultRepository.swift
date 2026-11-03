import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 1画像の取り込み結果です。重複時はファイルを増やさず、既存写真のIDを返します。
enum ImageImportOutcome: Sendable {
    case imported(database: VaultDatabase, photo: PhotoRecord, folderID: UUID)
    case duplicate(database: VaultDatabase, existingPhotoID: UUID)
}

/// 1つのアルバムのDBと暗号化写真を直列に更新するリポジトリです。
actor VaultRepository {
    private let kind: VaultKind
    private let key: Data
    private let store: VaultFileStore
    private var database: VaultDatabase
    private var lastPersistedDatabase: Data?
    private var automaticBackupTask: Task<Void, Never>?
    private var automaticBackupGeneration = UUID()
    private var automaticBackupRequiresRefresh = true
    private let dailyBackupCompletionKey: String
    private(set) var automaticBackupStatus = "保存待ち"
    private struct AutomaticManifest: Codable {
        let createdAt: Date
        let encryptedDatabase: Data
        let originals: [String: String]
    }

    private(set) var canWrite = false
    private var revision = UUID()
    private(set) var hasLoadedDatabase = false

    init(kind: VaultKind, masterKey: Data, location: StorageLocation, isolatedStorageRoot: URL? = nil) throws {
        self.kind = kind
        self.key = masterKey
        let namespace = SHA256.hash(data: masterKey).map { String(format: "%02x", $0) }.joined()
        self.store = VaultFileStore(kind: kind, location: location, cacheNamespace: namespace, isolatedStorageRoot: isolatedStorageRoot)
        let scope = (isolatedStorageRoot?.path ?? "app") + ":" + (LocalRestartState.namespace ?? "original") + ":" + kind.rawValue + ":" + namespace
        let scopeHash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        self.dailyBackupCompletionKey = "backup.daily.success." + scopeHash
        self.database = .empty
    }

    /// iCloudは暗号化キャッシュを先に表示。クラウド未取得時には空DBを書きません。
    func open() async throws -> VaultDatabase {
        if store.location == .iCloud {
            #if DEBUG
            throw PhotoVaultError.iCloudDisabledInDebug
            #else
            let cacheStore = store
            if let encrypted = try? await CloudDownloadDeadline.run(seconds: 2, operation: { try cacheStore.cachedDatabase() }),
               let cached = try? decodeDatabase(encrypted) {
                try Task.checkCancellation()
                database = cached
                _ = migrateLegacyDatabaseIfNeeded()
                hasLoadedDatabase = true
            }
            try Task.checkCancellation()
            return database
            #endif
        }
        try store.prepareDirectories()
        canWrite = true
        if let encrypted = try store.readDatabase() {
            do {
                let plaintext = try CryptoBox.open(encrypted, using: key)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                database = try decoder.decode(VaultDatabase.self, from: plaintext)
                lastPersistedDatabase = encrypted
                if migrateLegacyDatabaseIfNeeded() {
                    try persist()
                }
            } catch {
                throw PhotoVaultError.databaseCorrupted
            }
        } else {
            try store.ensureSafeToCreateLocalDatabase()
            database = .empty
            _ = migrateLegacyDatabaseIfNeeded()
            try persist()
        }
        hasLoadedDatabase = true
        scheduleAutomaticBackup()
        return database
    }

    /// 通信待ちはactorの外で行います。成功するまでキャッシュからの更新は許可しません。
    func refreshFromCloud() async throws -> VaultDatabase {
        guard store.location == .iCloud else { return database }
        canWrite = false
        let download = try await store.downloadDatabase()
        let encrypted = download.data
        try Task.checkCancellation()
        let loaded = try decodeDatabase(encrypted)
        try Task.checkCancellation()
        database = loaded
        lastPersistedDatabase = encrypted
        revision = UUID()
        hasLoadedDatabase = true
        // 表示用の旧形式補完はメモリ上だけで行い、読み込みによる不要な再アップロードを避けます。
        _ = migrateLegacyDatabaseIfNeeded()
        try? store.cacheDatabase(encrypted)
        try Task.checkCancellation()
        canWrite = download.isCurrent
        if canWrite {
            automaticBackupRequiresRefresh = true
            scheduleAutomaticBackup()
        }
        return database
    }

    private func decodeDatabase(_ encrypted: Data) throws -> VaultDatabase {
        try Self.decodeCloudDatabase(encrypted, key: key)
    }

    static func decodeCloudDatabase(_ encrypted: Data, key: Data) throws -> VaultDatabase {
        let plaintext: Data
        do { plaintext = try CryptoBox.open(encrypted, using: key) }
        catch { throw CloudRestoreReadError.cannotDecrypt }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(VaultDatabase.self, from: plaintext)
        } catch { throw CloudRestoreReadError.cannotDecode }
    }

    private func requireWritableDatabase() throws {
        guard canWrite else { throw PhotoVaultError.iCloudIndexNotReady }
    }

    func snapshot() -> VaultDatabase { database }

    func storageStatus() -> VaultStorageStatus { store.storageStatus(database: database) }

    func clearReadCache() throws { try store.clearReadCacheReportingErrors() }

    func cloudStatus() throws -> VaultCloudStatus {
        try store.cloudStatus(photos: database.allStoredPhotos)
    }

    func createFolder(named name: String, parentID: UUID? = nil) throws -> VaultDatabase {
        try requireWritableDatabase()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return database }
        // parentIDが指定された場合は、存在するフォルダの直下にだけ作成します。
        if let parentID,
           !database.folders.contains(where: { $0.id == parentID }) {
            return database
        }
        database.folders.append(AlbumFolder(name: trimmed, parentID: parentID))
        try persist()
        return database
    }

    func renameFolder(id: UUID, to name: String) throws -> VaultDatabase {
        try requireWritableDatabase()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = database.folders.firstIndex(where: { $0.id == id }) else {
            return database
        }
        database.folders[index].name = trimmed
        try persist()
        return database
    }

    /// フォルダを最上位、または別フォルダの直下へ移動します。
    /// 自分自身や自分の配下を親にすると循環が発生するため、DB層でも必ず拒否します。
    func moveFolder(id: UUID, toParentID parentID: UUID?) throws -> VaultDatabase {
        try requireWritableDatabase()
        guard let index = database.folders.firstIndex(where: { $0.id == id }) else {
            return database
        }

        if let parentID {
            guard database.folders.contains(where: { $0.id == parentID }) else {
                return database
            }
            let invalidDestinationIDs = database.folderIDs(includingDescendantsOf: id)
            guard !invalidDestinationIDs.contains(parentID) else {
                return database
            }
        }

        guard database.folders[index].parentID != parentID else { return database }
        database.folders[index].parentID = parentID
        try persist()
        return database
    }

    /// 復号や再圧縮を行わず、写真レコードの所属フォルダだけを変更します。
    /// 移動元でフォルダ画像に設定されていた写真は、古い参照を同時に解除します。
    func movePhoto(id: UUID, toFolderID folderID: UUID) throws -> VaultDatabase {
        try requireWritableDatabase()
        guard database.folders.contains(where: { $0.id == folderID }),
              let index = database.photos.firstIndex(where: { $0.id == id }) else {
            return database
        }

        let previousFolderID = database.photos[index].folderID
        guard previousFolderID != folderID else { return database }
        database.photos[index].folderID = folderID
        if let previousFolderID,
           database.folderFeaturedPhotoIDs?[previousFolderID] == id {
            database.folderFeaturedPhotoIDs?.removeValue(forKey: previousFolderID)
        }
        try persist()
        return database
    }

    /// フォルダ構造だけを削除し、中の写真は30日間ゴミ箱へ保持します。
    func deleteFolder(id: UUID) throws -> VaultDatabase {
        try requireWritableDatabase()
        let folderIDs = database.folderIDs(includingDescendantsOf: id)
        let photoIDs = Set(database.photos.filter { $0.folderID.map { folderIDs.contains($0) } ?? false }.map(\.id))
        var next = database
        moveToTrash(ids: photoIDs, in: &next)
        next.folders.removeAll { folderIDs.contains($0.id) }
        for id in folderIDs { next.folderFeaturedPhotoIDs?.removeValue(forKey: id) }
        try commit(next)
        return database
    }

    /// 元画像と一覧表示用サムネイルを暗号化してからDBへ登録します。
    /// 元データは再エンコードせず、そのままAES-GCMで暗号化するため画質は変わりません。
    func importImage(_ image: ImportedImage, into folderID: UUID?) throws -> ImageImportOutcome {
        try requireWritableDatabase()
        guard image.contentType.conforms(to: .image) else {
            throw PhotoVaultError.unsupportedImage
        }
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw PhotoVaultError.invalidImage
        }

        let digest = Self.contentDigest(for: image.data)
        if let existingPhotoID = try duplicatePhotoID(for: image, digest: digest) {
            return .duplicate(database: database, existingPhotoID: existingPhotoID)
        }

        // フォルダ一覧から取り込んだ場合は、最初の重複でない画像の直前にだけ日時フォルダを作ります。
        let resolvedFolderID: UUID
        let automaticallyCreatedFolder: AlbumFolder?
        if let folderID,
           database.folders.contains(where: { $0.id == folderID }) {
            resolvedFolderID = folderID
            automaticallyCreatedFolder = nil
        } else {
            let folder = AlbumFolder(name: Self.timestampFolderName())
            database.folders.append(folder)
            resolvedFolderID = folder.id
            automaticallyCreatedFolder = folder
        }

        let id = UUID()
        let photoFilename = "\(id.uuidString).pvimg"
        let thumbnailFilename = "\(id.uuidString).pvthumb"
        let dimensions = Self.imageDimensions(source: source)
        let metadata = ImageMetadataService.read(from: image.data)
        let thumbnail = try Self.makeThumbnail(source: source)
        let encryptedPhoto = try CryptoBox.seal(image.data, using: key)
        let encryptedThumbnail = try CryptoBox.seal(thumbnail, using: key)

        // どちらかのファイル保存が失敗した場合は、片方だけ残らないよう巻き戻します。
        do {
            try store.writePhoto(encryptedPhoto, named: photoFilename)
            try store.writeThumbnail(encryptedThumbnail, named: thumbnailFilename)
        } catch {
            if let automaticallyCreatedFolder {
                database.folders.removeAll { $0.id == automaticallyCreatedFolder.id }
            }
            try? store.removePhoto(named: photoFilename, thumbnailNamed: thumbnailFilename)
            throw error
        }

        let record = PhotoRecord(
            id: id,
            folderID: resolvedFolderID,
            originalFilename: image.filename,
            encryptedFilename: photoFilename,
            encryptedThumbnailFilename: thumbnailFilename,
            contentTypeIdentifier: image.contentType.identifier,
            addedAt: .now,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            originalByteCount: Int64(image.data.count),
            contentDigest: digest,
            sourceAssetIdentifier: image.photoLibraryIdentifier,
            capturedAt: metadata.capturedAt,
            cameraMake: metadata.cameraMake,
            cameraModel: metadata.cameraModel,
            lensModel: metadata.lensModel,
            focalLength35mm: metadata.focalLength35mm,
            aperture: metadata.aperture,
            exposureTime: metadata.exposureTime,
            isoSpeed: metadata.isoSpeed
        )
        database.photos.append(record)
        do {
            try persist()
        } catch {
            database.photos.removeAll { $0.id == id }
            if let automaticallyCreatedFolder {
                database.folders.removeAll { $0.id == automaticallyCreatedFolder.id }
            }
            try? store.removePhoto(named: photoFilename, thumbnailNamed: thumbnailFilename)
            throw error
        }
        return .imported(database: database, photo: record, folderID: resolvedFolderID)
    }

    /// 表示時に必要な写真だけを読み込み、メモリ上で復号します。
    func imageData(for photoID: UUID, thumbnail: Bool) async throws -> Data {
        guard let photo = database.allStoredPhotos.first(where: { $0.id == photoID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let filename = thumbnail ? photo.encryptedThumbnailFilename : photo.encryptedFilename
        if thumbnail, let cached = try? store.cachedThumbnail(named: filename),
           let plaintext = try? CryptoBox.open(cached, using: key) {
            return plaintext
        }
        let encrypted = try await store.downloadImage(named: filename, thumbnail: thumbnail)
        try Task.checkCancellation()
        let plaintext = try CryptoBox.open(encrypted, using: key)
        if thumbnail { try? store.cacheThumbnail(encrypted, named: filename) }
        return plaintext
    }

    /// 保存済みハッシュを鵜呑みにせず、元ファイルを復号して照合します。
    func scanDuplicates() async throws -> DuplicateScanResult {
        try requireWritableDatabase()
        let scanRevision = revision
        let photos = database.photos.sorted {
            $0.addedAt == $1.addedAt ? $0.id.uuidString < $1.id.uuidString : $0.addedAt < $1.addedAt
        }
        var groups: [String: [PhotoRecord]] = [:]
        var failed = 0
        for photo in photos {
            try Task.checkCancellation()
            do {
                let encrypted = try await store.downloadImage(named: photo.encryptedFilename, thumbnail: false)
                try Task.checkCancellation()
                let data = try CryptoBox.open(encrypted, using: key)
                guard revision == scanRevision else { throw MaintenanceError.databaseChanged }
                let digest = Self.contentDigest(for: data)
                groups[digest, default: []].append(photo)
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard revision == scanRevision else { throw MaintenanceError.databaseChanged }
                failed += 1
            }
        }
        guard revision == scanRevision else { throw MaintenanceError.databaseChanged }
        let duplicates = groups.filter { $0.value.count > 1 }
            .map { DuplicatePhotoGroup(id: $0.key, photos: $0.value) }
            .sorted { $0.id < $1.id }
        return DuplicateScanResult(groups: duplicates, inspectedCount: photos.count - failed, failedCount: failed)
    }

    /// 代表画像との類似度でまとめ、類似関係の連鎖だけで別の写真を同じ組にしません。
    func scanSimilarPhotos() async throws -> SimilarPhotoScanResult {
        try requireWritableDatabase()
        let scanRevision = revision
        let photos = database.photos.sorted {
            $0.addedAt == $1.addedAt ? $0.id.uuidString < $1.id.uuidString : $0.addedAt < $1.addedAt
        }
        var groups: [(fingerprint: SimilarImageFingerprint, photos: [PhotoRecord])] = []
        var failed = 0
        for photo in photos {
            try Task.checkCancellation()
            do {
                let encrypted = try await store.downloadImage(named: photo.encryptedFilename, thumbnail: false)
                try Task.checkCancellation()
                guard revision == scanRevision else { throw MaintenanceError.databaseChanged }
                let fingerprint = try autoreleasepool {
                    try SimilarImageFingerprint(data: CryptoBox.open(encrypted, using: key))
                }
                var match: Int?
                for index in groups.indices {
                    if index % 128 == 0 { try Task.checkCancellation() }
                    if fingerprint.resembles(groups[index].fingerprint) { match = index; break }
                }
                if let match { groups[match].photos.append(photo) }
                else { groups.append((fingerprint, [photo])) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard revision == scanRevision else { throw MaintenanceError.databaseChanged }
                failed += 1
            }
        }
        try Task.checkCancellation()
        guard revision == scanRevision else { throw MaintenanceError.databaseChanged }
        return SimilarPhotoScanResult(groups: groups.filter { $0.photos.count > 1 }.map {
            SimilarPhotoGroup(id: $0.photos[0].id, photos: $0.photos)
        }, inspectedCount: photos.count - failed, failedCount: failed)
    }

    func trashDuplicates(group: DuplicatePhotoGroup, keeping keptID: UUID) throws -> VaultDatabase {
        try requireWritableDatabase()
        guard group.photos.count > 1, Set(group.photos.map(\.id)).count == group.photos.count,
              let kept = database.photos.first(where: { $0.id == keptID }),
              group.photos.contains(where: { $0.id == keptID }) else { throw MaintenanceError.databaseChanged }
        let original = try CryptoBox.open(store.readPhoto(named: kept.encryptedFilename), using: key)
        guard Self.contentDigest(for: original) == group.id else { throw MaintenanceError.databaseChanged }
        for candidate in group.photos where candidate.id != keptID {
            guard let current = database.photos.first(where: { $0.id == candidate.id }), current == candidate else {
                throw MaintenanceError.databaseChanged
            }
            let bytes = try CryptoBox.open(store.readPhoto(named: current.encryptedFilename), using: key)
            guard bytes == original else { throw MaintenanceError.databaseChanged }
        }
        return try trashPhotos(ids: Set(group.photos.map(\.id)).subtracting([keptID]))
    }

    func deletePhoto(id: UUID) throws -> VaultDatabase {
        try trashPhotos(ids: [id])
    }

    func trashPhotos(ids: Set<UUID>) throws -> VaultDatabase {
        try requireWritableDatabase()
        var next = database
        moveToTrash(ids: ids, in: &next)
        try commit(next)
        return database
    }

    private func moveToTrash(ids: Set<UUID>, in next: inout VaultDatabase) {
        var trash = next.trash ?? []
        for photo in next.photos where ids.contains(photo.id) {
            trash.append(TrashedPhoto(photo: photo, deletedAt: .now,
                                     originalFolderName: next.folders.first { $0.id == photo.folderID }?.name))
            if let folderID = photo.folderID, next.folderFeaturedPhotoIDs?[folderID] == photo.id {
                next.folderFeaturedPhotoIDs?.removeValue(forKey: folderID)
            }
        }
        next.photos.removeAll { ids.contains($0.id) }
        next.trash = trash
    }

    func restoreTrashedPhoto(id: UUID, photoLimit: Int?) throws -> VaultDatabase {
        try requireWritableDatabase()
        guard let entry = database.trash?.first(where: { $0.id == id }), entry.canRestore() else {
            throw MaintenanceError.trashUnavailable
        }
        if let photoLimit, database.photos.count >= photoLimit { throw MaintenanceError.photoLimit }
        var next = database
        var photo = entry.photo
        if !next.folders.contains(where: { $0.id == photo.folderID }) {
            let folder = AlbumFolder(id: photo.folderID ?? UUID(), name: entry.originalFolderName ?? "復元した写真")
            next.folders.append(folder)
            photo.folderID = folder.id
        }
        next.photos.append(photo)
        next.trash?.removeAll { $0.id == id }
        try commit(next)
        return database
    }

    /// 先に削除意図を永続化し、I/Oが失敗した場合も次回の清掃で再試行します。
    func permanentlyDelete(ids: Set<UUID>) throws -> VaultDatabase {
        try requireWritableDatabase()
        var next = database
        for index in (next.trash ?? []).indices where ids.contains(next.trash![index].id) {
            next.trash![index].deletionRequested = true
        }
        try commit(next)
        for entry in database.trash ?? [] where ids.contains(entry.id) {
            guard Self.isSafeStoredFilename(entry.photo.encryptedFilename),
                  Self.isSafeStoredFilename(entry.photo.encryptedThumbnailFilename),
                  !database.allStoredPhotos.contains(where: {
                      $0.id != entry.id && ($0.encryptedFilename == entry.photo.encryptedFilename ||
                      $0.encryptedThumbnailFilename == entry.photo.encryptedThumbnailFilename)
                  }) else { throw PhotoVaultError.databaseCorrupted }
            try store.removePhoto(named: entry.photo.encryptedFilename,
                                  thumbnailNamed: entry.photo.encryptedThumbnailFilename)
            var updated = database
            updated.trash?.removeAll { $0.id == entry.id }
            try commit(updated)
        }
        return database
    }

    func purgeExpiredTrash(now: Date = .now) throws -> VaultDatabase {
        let ids = Set((database.trash ?? []).filter { !$0.canRestore(at: now) }.map(\.id))
        return ids.isEmpty ? database : try permanentlyDelete(ids: ids)
    }

    /// 新しい操作では保存失敗時にメモリ上の状態も元に戻します。
    private func commit(_ next: VaultDatabase) throws {
        let previous = database
        database = next
        do { try persist() } catch { database = previous; throw error }
    }

    /// 取り込み後のOCR結果、または旧写真を開いたときに取得した撮影情報をDBへ追記します。
    func updateAnalysis(
        photoID: UUID,
        metadata: ImageMetadataSnapshot? = nil,
        ocrText: String? = nil
    ) throws -> VaultDatabase {
        try requireWritableDatabase()
        guard let index = database.photos.firstIndex(where: { $0.id == photoID }) else {
            return database
        }
        if let metadata {
            database.photos[index].capturedAt = metadata.capturedAt
            database.photos[index].cameraMake = metadata.cameraMake
            database.photos[index].cameraModel = metadata.cameraModel
            database.photos[index].lensModel = metadata.lensModel
            database.photos[index].focalLength35mm = metadata.focalLength35mm
            database.photos[index].aperture = metadata.aperture
            database.photos[index].exposureTime = metadata.exposureTime
            database.photos[index].isoSpeed = metadata.isoSpeed
        }
        if let ocrText {
            database.photos[index].ocrText = ocrText
            database.photos[index].ocrIndexedAt = .now
        }
        try persist()
        return database
    }

    func setFeaturedPhoto(id: UUID?, folderID: UUID) throws -> VaultDatabase {
        try requireWritableDatabase()
        if let id {
            guard database.photos.contains(where: { $0.id == id && $0.folderID == folderID }) else {
                return database
            }
            var featured = database.folderFeaturedPhotoIDs ?? [:]
            featured[folderID] = id
            database.folderFeaturedPhotoIDs = featured
        } else {
            database.folderFeaturedPhotoIDs?.removeValue(forKey: folderID)
        }
        try persist()
        return database
    }

    func updateSettings(
        layout: AlbumLayout? = nil,
        photoSortOrder: PhotoSortOrder? = nil,
        folderSortOrder: FolderSortOrder? = nil,
        slideshowEnabled: Bool? = nil,
        deletesOriginalAfterImport: Bool? = nil
    ) throws -> VaultDatabase {
        try requireWritableDatabase()
        if let layout { database.albumLayout = layout }
        if let photoSortOrder { database.photoSortOrder = photoSortOrder }
        if let folderSortOrder { database.folderSortOrder = folderSortOrder }
        if let slideshowEnabled { database.slideshowEnabled = slideshowEnabled }
        if let deletesOriginalAfterImport {
            database.deletesOriginalAfterImport = deletesOriginalAfterImport
        }
        try persist()
        return database
    }

    /// ZIP出力の直前に対象写真を復号してエントリへ変換します。
    func exportEntries(folderID: UUID?) throws -> [ZipEntry] {
        let photos: [PhotoRecord]
        if let folderID {
            photos = database.photos(inFolderTree: folderID)
        } else {
            photos = database.photos(in: nil)
        }
        return try photos.map { photo in
            let encrypted = try store.readPhoto(named: photo.encryptedFilename)
            let data = try CryptoBox.open(encrypted, using: key)
            return ZipEntry(filename: photo.originalFilename, data: data)
        }
    }

    /// 現在のアルバムを、バックアップ専用暗号化の前段となる可搬データへ変換します。
    func backupPayload() throws -> VaultBackupPayload {
        try requireWritableDatabase()
        var backupDatabase = database
        backupDatabase.trash?.removeAll { $0.deletionRequested == true }
        let backupPhotos = try backupDatabase.allStoredPhotos.map { photo in
            let encrypted = try store.readPhoto(named: photo.encryptedFilename)
            let original = try CryptoBox.open(encrypted, using: key)
            return VaultBackupPhoto(record: photo, originalData: original)
        }
        return VaultBackupPayload(
            formatVersion: 2,
            createdAt: .now,
            sourceVaultKind: kind,
            database: backupDatabase,
            photos: backupPhotos
        )
    }

    /// バックアップ全体を事前検証・再暗号化し、成功した場合だけ現在のアルバムを置き換えます。
    func restoreBackup(_ payload: VaultBackupPayload) throws -> VaultDatabase {
        try requireWritableDatabase()
        guard [1, 2].contains(payload.formatVersion),
              payload.sourceVaultKind == kind,
              payload.photos.count == payload.database.allStoredPhotos.count else {
            throw PhotoVaultError.invalidBackup
        }

        var payloadByID: [UUID: VaultBackupPhoto] = [:]
        for photo in payload.photos {
            guard payloadByID[photo.record.id] == nil else {
                throw PhotoVaultError.invalidBackup
            }
            payloadByID[photo.record.id] = photo
        }
        guard Set(payload.database.allStoredPhotos.map(\.id)) == Set(payloadByID.keys) else {
            throw PhotoVaultError.invalidBackup
        }

        var restoredDatabase = payload.database
        restoredDatabase.schemaVersion = 8
        var encryptedPhotos: [String: Data] = [:]
        var encryptedThumbnails: [String: Data] = [:]

        for photo in restoredDatabase.allStoredPhotos {
            guard let backedUpPhoto = payloadByID[photo.id],
                  backedUpPhoto.record == photo,
                  Self.isSafeStoredFilename(photo.encryptedFilename),
                  Self.isSafeStoredFilename(photo.encryptedThumbnailFilename),
                  encryptedPhotos[photo.encryptedFilename] == nil,
                  encryptedThumbnails[photo.encryptedThumbnailFilename] == nil,
                  photo.originalByteCount == Int64(backedUpPhoto.originalData.count),
                  let source = CGImageSourceCreateWithData(backedUpPhoto.originalData as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else {
                throw PhotoVaultError.invalidBackup
            }

            let expectedDigest = photo.contentDigest ?? Self.contentDigest(for: backedUpPhoto.originalData)
            guard expectedDigest == Self.contentDigest(for: backedUpPhoto.originalData) else {
                throw PhotoVaultError.invalidBackup
            }
            let thumbnail = try Self.makeThumbnail(source: source)
            encryptedPhotos[photo.encryptedFilename] = try CryptoBox.seal(
                backedUpPhoto.originalData,
                using: key
            )
            encryptedThumbnails[photo.encryptedThumbnailFilename] = try CryptoBox.seal(
                thumbnail,
                using: key
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedDatabase = try encoder.encode(restoredDatabase)
        let encryptedDatabase = try CryptoBox.seal(encodedDatabase, using: key)

        do {
            try store.replaceVaultData(
                database: encryptedDatabase,
                photos: encryptedPhotos,
                thumbnails: encryptedThumbnails
            )
            database = restoredDatabase
            lastPersistedDatabase = encryptedDatabase
            revision = UUID()
            automaticBackupRequiresRefresh = true
            if hasLoadedDatabase { scheduleAutomaticBackup() }
            return database
        } catch {
            throw PhotoVaultError.backupRestoreFailed
        }
    }

    /// 暗号化DB、元画像、サムネイルを含む現在アルバムの実ディスク使用量です。
    func storedByteCount() throws -> Int64 {
        try store.storedByteCount()
    }

    /// 管理DB全体をJSON化し、暗号化した状態で原子的に保存します。
    private func persist() throws {
        try requireWritableDatabase()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(database)
        let encrypted = try CryptoBox.seal(plaintext, using: key)
        try store.writeDatabase(encrypted, expectedPrevious: lastPersistedDatabase)
        lastPersistedDatabase = encrypted
        revision = UUID()
        if hasLoadedDatabase { scheduleAutomaticBackup() }
    }

    private enum AutomaticBackupResult {
        case completed, changed, failed, unavailable
    }

    private func scheduleAutomaticBackup() {
        guard automaticBackupTask == nil else { return }
        guard DailyBackupSchedule.isEnabled() else {
            automaticBackupStatus = "自動バックアップはオフです"
            return
        }
        automaticBackupGeneration = UUID()
        let generation = automaticBackupGeneration
        automaticBackupTask = Task { [weak self] in
            await self?.runDailyBackupSchedule(generation: generation)
        }
    }

    /// 設定・時刻・タイムゾーンやフォアグラウンド復帰の変更時に再計算します。
    func refreshAutomaticBackupSchedule() {
        cancelAutomaticBackup()
        guard canWrite, hasLoadedDatabase else {
            automaticBackupStatus = DailyBackupSchedule.isEnabled()
                ? "アルバムの読み込み完了後に保存します" : "自動バックアップはオフです"
            return
        }
        scheduleAutomaticBackup()
    }

    private func runDailyBackupSchedule(generation: UUID) async {
        while !Task.isCancelled && generation == automaticBackupGeneration && DailyBackupSchedule.isEnabled() {
            let now = Date()
            var last = UserDefaults.standard.object(forKey: dailyBackupCompletionKey) as? Date
            // 旧バージョンの完成済みバックアップも、その日の実施分として引き継ぎます。
            if last == nil, let existing = try? automaticManifest() {
                last = existing.createdAt
                UserDefaults.standard.set(existing.createdAt, forKey: dailyBackupCompletionKey)
            }
            let next = DailyBackupSchedule.nextRun(now: now, lastSuccess: last,
                                                  minuteOfDay: DailyBackupSchedule.minuteOfDay())
            if next > now {
                let nextLabel = next.formatted(date: .abbreviated, time: .shortened)
                if let last {
                    automaticBackupStatus = "前回：\(last.formatted(date: .abbreviated, time: .shortened))\n次回：\(nextLabel)"
                } else {
                    automaticBackupStatus = "次回：\(nextLabel)"
                }
                do { try await Task.sleep(for: .seconds(min(next.timeIntervalSince(now), 60))) }
                catch { break }
                continue
            }
            let result = await writeAutomaticBackup(markDailySuccess: true)
            guard !Task.isCancelled, generation == automaticBackupGeneration else { break }
            switch result {
            case .completed:
                break
            case .changed:
                automaticBackupStatus = "アルバムの変更後に再試行します"
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            case .failed:
                // 通信や空き容量の失敗では一定時間あけ、前回分を保持します。
                automaticBackupStatus += "\n5分後に自動で再試行します。"
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            case .unavailable:
                automaticBackupTask = nil
                return
            }
        }
    }

    func cancelAutomaticBackup() {
        automaticBackupGeneration = UUID()
        automaticBackupTask?.cancel()
        automaticBackupTask = nil
    }

    /// 隔離された回帰テストで実際のバックアップ処理を検証するための入口です。
    func runAutomaticBackupNow() async {
        cancelAutomaticBackup()
        _ = await writeAutomaticBackup(markDailySuccess: false)
    }

    private static func automaticObjectName(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".pvobject"
    }

    private func automaticManifest(retainedID: String? = nil) throws -> AutomaticManifest {
        let path: String
        if let retainedID {
            guard retainedID.count == 64, retainedID.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw PhotoVaultError.invalidBackup
            }
            path = "Retained/\(retainedID).pvauto"
        } else { path = "manifest.pvauto" }
        let sealed = try store.readAutomaticBackupFile(path)
        let decoded = try CryptoBox.open(sealed, using: key)
        return try JSONDecoder().decode(AutomaticManifest.self, from: AutomaticBackupCompression.decodeManifest(decoded))
    }

    private func writeAutomaticBackup(markDailySuccess: Bool) async -> AutomaticBackupResult {
        guard canWrite, hasLoadedDatabase else {
            automaticBackupStatus = "アルバムの読み込み完了後に保存します"
            return .unavailable
        }
        let generation = automaticBackupGeneration
        let snapshotRevision = revision
        var snapshot = database
        snapshot.trash?.removeAll { $0.deletionRequested == true }
        let previous: AutomaticManifest?
        do {
            previous = try automaticManifest()
        } catch {
            let value = error as NSError
            let missing = value.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code)
            guard missing else {
                automaticBackupStatus = "既存のバックアップを確認できないため更新を中止しました。元データは保持しています。\n" + error.localizedDescription
                return .failed
            }
            previous = nil
        }
        if previous == nil && snapshot.allStoredPhotos.isEmpty && snapshot.folders.isEmpty {
            automaticBackupStatus = "写真やフォルダの追加後に自動保存します"
            return .unavailable
        }
        let refreshAll = automaticBackupRequiresRefresh
        automaticBackupStatus = "保存中"
        do {
            var originals: [String: String] = [:]
            for photo in snapshot.allStoredPhotos {
                await Task.yield()
                try Task.checkCancellation()
                guard revision == snapshotRevision, generation == automaticBackupGeneration else { throw CancellationError() }
                let name = photo.encryptedFilename
                guard Self.isSafeStoredFilename(name) else { throw PhotoVaultError.databaseCorrupted }
                if !refreshAll, let object = previous?.originals[name],
                   let data = try? store.readAutomaticBackupFile(object),
                   Self.automaticObjectName(data) == object {
                    originals[name] = object
                    continue
                }
                let encrypted = try await store.downloadImage(named: name, thumbnail: false)
                try Task.checkCancellation()
                guard revision == snapshotRevision, generation == automaticBackupGeneration else { throw CancellationError() }
                let original = try CryptoBox.open(encrypted, using: key)
                guard Int64(original.count) == photo.originalByteCount else { throw PhotoVaultError.invalidBackup }
                if let expectedDigest = photo.contentDigest,
                   Self.contentDigest(for: original) != expectedDigest { throw PhotoVaultError.invalidBackup }
                // 同じ元写真なら既存バックアップを再利用。再暗号化のnonceで毎回差分にしない。
                if let object = previous?.originals[name],
                   let stored = try? store.readAutomaticBackupFile(object),
                   Self.automaticObjectName(stored) == object,
                   let plain = try? CryptoBox.open(stored, using: key),
                   let previousOriginal = try? AutomaticBackupCompression.decode(plain, expectedSize: photo.originalByteCount),
                   previousOriginal == original {
                    originals[name] = object
                    continue
                }
                let compressed = AutomaticBackupCompression.encode(original)
                let backupObject = try CryptoBox.seal(compressed, using: key)
                let object = Self.automaticObjectName(backupObject)
                try store.writeAutomaticBackupFile(backupObject, name: object)
                originals[name] = object
            }
            try Task.checkCancellation()
            guard revision == snapshotRevision, generation == automaticBackupGeneration else { throw CancellationError() }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let encryptedIndex = try CryptoBox.seal(encoder.encode(snapshot), using: key)
            let manifest = AutomaticManifest(createdAt: .now, encryptedDatabase: encryptedIndex, originals: originals)
            let encodedManifest = try JSONEncoder().encode(manifest)
            let sealed = try CryptoBox.seal(AutomaticBackupCompression.encodeManifest(encodedManifest), using: key)
            guard try store.readDatabase() == lastPersistedDatabase else {
                throw MaintenanceError.databaseChanged
            }
            if let previous {
                let old = try Self.decodeCloudDatabase(previous.encryptedDatabase, key: key)
                let removedPhotos = !Set(old.photos.map(\.id)).isSubset(of: Set(snapshot.photos.map(\.id)))
                let removedFolders = !Set(old.folders.map(\.id)).isSubset(of: Set(snapshot.folders.map(\.id)))
                let replacedOriginals = previous.originals.contains { originals[$0.key] != $0.value }
                if removedPhotos || removedFolders || replacedOriginals {
                    // 削除後の最新版で置き換える前に、前回分を保管します。退避失敗なら置換しません。
                    try retainCurrentAutomaticBackup()
                }
            }
            // 必要な元写真が全部揃った時だけ、前回の完成済みバックアップを切り替えます。
            try store.writeAutomaticBackupFile(sealed, name: "manifest.pvauto")
            // 完成した直後に記録し、設定変更などでタスクが中断されても同日の二重実行を防ぎます。
            if markDailySuccess { UserDefaults.standard.set(Date(), forKey: dailyBackupCompletionKey) }
            automaticBackupRequiresRefresh = false
            automaticBackupStatus = "保存済み：\(manifest.createdAt.formatted(date: .abbreviated, time: .shortened))"
            // 完了した一覧から参照されないオブジェクトだけを後片付けします。
            // 保管分を読めない場合は整理を中止し、写真オブジェクトを残します。
            if let retainedObjects = try? retainedAutomaticObjects() {
                try? store.pruneAutomaticBackupFiles(keeping:
                    Set(originals.values).union(retainedObjects).union(["manifest.pvauto", "Retained"]))
            }
            return .completed
        } catch is CancellationError {
            return .changed
        } catch {
            guard generation == automaticBackupGeneration else { return .changed }
            automaticBackupStatus = (previous == nil ? "保存失敗：" : "保存失敗（前回分を保持）：") + error.localizedDescription
            return .failed
        }
    }

    func automaticBackupPayload(retainedID: String? = nil) throws -> VaultBackupPayload {
        let manifest = try automaticManifest(retainedID: retainedID)
        let restored = try Self.decodeCloudDatabase(manifest.encryptedDatabase, key: key)
        let photos = try restored.allStoredPhotos.map { photo in
            guard let object = manifest.originals[photo.encryptedFilename],
                  Self.isSafeStoredFilename(object) else { throw PhotoVaultError.invalidBackup }
            let encrypted = try store.readAutomaticBackupFile(object)
            guard Self.automaticObjectName(encrypted) == object else { throw PhotoVaultError.invalidBackup }
            let compressed = try CryptoBox.open(encrypted, using: key)
            let original = try AutomaticBackupCompression.decode(compressed, expectedSize: photo.originalByteCount)
            return VaultBackupPhoto(record: photo, originalData: original)
        }
        return VaultBackupPayload(formatVersion: 2, createdAt: manifest.createdAt,
                                  sourceVaultKind: kind, database: restored, photos: photos)
    }

    /// 復元結果を別の端末ディレクトリへ作り、壊れた元アルバムは書き換えません。
    func recoverAutomaticBackupToLocal(root: URL, photoLimit: Int?) async throws {
        let payload = try automaticBackupPayload()
        guard photoLimit == nil || payload.database.photos.count <= photoLimit! else {
            throw MaintenanceError.photoLimit
        }
        let recovered = try VaultRepository(kind: kind, masterKey: key, location: .local, isolatedStorageRoot: root)
        _ = try await recovered.open()
        do {
            _ = try await recovered.restoreBackup(payload)
            await recovered.cancelAutomaticBackup()
        } catch {
            await recovered.cancelAutomaticBackup()
            throw error
        }
    }

    func retainCurrentAutomaticBackup() throws {
        // 完成した最新バックアップだけを保管。新しい鍵や平文ファイルは作りません。
        _ = try automaticManifest()
        let sealed = try store.readAutomaticBackupFile("manifest.pvauto")
        let id = SHA256.hash(data: sealed).map { String(format: "%02x", $0) }.joined()
        try store.writeAutomaticBackupFile(sealed, name: "Retained/\(id).pvauto")
    }

    func retainedAutomaticBackups() throws -> [RetainedBackupSummary] {
        try store.retainedBackupIDs().map { id in
            let manifest = try automaticManifest(retainedID: id)
            let saved = try Self.decodeCloudDatabase(manifest.encryptedDatabase, key: key)
            return RetainedBackupSummary(id: id, createdAt: manifest.createdAt,
                                         photoCount: saved.allStoredPhotos.count)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func retainedAutomaticObjects() throws -> Set<String> {
        var objects = Set<String>()
        for id in try store.retainedBackupIDs() {
            objects.formUnion(try automaticManifest(retainedID: id).originals.values)
        }
        return objects
    }

    /// 旧版の未分類写真と代表画像を新しいフォルダ単位のDB構造へ移行します。
    private func migrateLegacyDatabaseIfNeeded() -> Bool {
        var changed = false

        if database.photoSortOrder == nil {
            database.photoSortOrder = .newestFirst
            changed = true
        }

        if database.folderSortOrder == nil {
            database.folderSortOrder = .newestFirst
            changed = true
        }

        if database.folderFeaturedPhotoIDs == nil {
            database.folderFeaturedPhotoIDs = [:]
            changed = true
        }

        if database.slideshowEnabled == nil {
            database.slideshowEnabled = true
            changed = true
        }

        // 旧DBではparentIDがnilとして復号されるため、既存フォルダはすべて最上位に残ります。
        // 破損バックアップなどの不正な親ID・自己参照・循環参照は最上位へ戻します。
        let folderByID = database.folders.reduce(into: [UUID: AlbumFolder]()) { result, folder in
            result[folder.id] = folder
        }
        for index in database.folders.indices {
            guard let parentID = database.folders[index].parentID else { continue }
            var visited: Set<UUID> = [database.folders[index].id]
            var currentParentID: UUID? = parentID
            var isValid = true
            while let currentID = currentParentID {
                guard let parent = folderByID[currentID], visited.insert(currentID).inserted else {
                    isValid = false
                    break
                }
                currentParentID = parent.parentID
            }
            if !isValid {
                database.folders[index].parentID = nil
                changed = true
            }
        }

        let unfiledIndexes = database.photos.indices.filter { database.photos[$0].folderID == nil }
        if !unfiledIndexes.isEmpty {
            let folder = AlbumFolder(name: Self.timestampFolderName(prefix: "移行データ"))
            database.folders.append(folder)
            for index in unfiledIndexes {
                database.photos[index].folderID = folder.id
            }
            changed = true
        }

        if let legacyPhotoID = database.featuredPhotoID,
           let legacyPhoto = database.photos.first(where: { $0.id == legacyPhotoID }),
           let folderID = legacyPhoto.folderID {
            var featured = database.folderFeaturedPhotoIDs ?? [:]
            if featured[folderID] == nil {
                featured[folderID] = legacyPhotoID
                database.folderFeaturedPhotoIDs = featured
            }
            database.featuredPhotoID = nil
            database.showsFeaturedPhoto = false
            changed = true
        }

        if database.schemaVersion < 8 {
            database.schemaVersion = 8
            changed = true
        }
        return changed
    }

    /// アセットIDまたは元データのSHA-256で、同じアルバム内の重複を判定します。
    /// 旧版レコードは同じバイト数の候補だけを復号し、必要な分だけハッシュを補完します。
    private func duplicatePhotoID(for image: ImportedImage, digest: String) throws -> UUID? {
        if let identifier = image.photoLibraryIdentifier,
           let existing = database.photos.first(where: { $0.sourceAssetIdentifier == identifier }) {
            return existing.id
        }
        if let existing = database.photos.first(where: { $0.contentDigest == digest }) {
            return existing.id
        }

        var didBackfillDigest = false
        var duplicateID: UUID?
        let candidateIndexes = database.photos.indices.filter {
            database.photos[$0].contentDigest == nil
                && database.photos[$0].originalByteCount == Int64(image.data.count)
        }

        for index in candidateIndexes {
            let photo = database.photos[index]
            // 1件の旧ファイルが欠損していても、新しい画像の取り込み全体は止めません。
            guard let encrypted = try? store.readPhoto(named: photo.encryptedFilename),
                  let plaintext = try? CryptoBox.open(encrypted, using: key) else {
                continue
            }
            let existingDigest = Self.contentDigest(for: plaintext)
            database.photos[index].contentDigest = existingDigest
            didBackfillDigest = true
            if existingDigest == digest {
                duplicateID = photo.id
                break
            }
        }

        if didBackfillDigest {
            try persist()
        }
        return duplicateID
    }

    /// 画像の内容だけから安定した識別値を作り、ファイル名変更の影響を受けないようにします。
    private static func contentDigest(for data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func isSafeStoredFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename == (filename as NSString).lastPathComponent
            && !filename.contains("..")
            && !filename.contains("/")
            && !filename.contains("\\")
    }

    /// 自動作成時は日時だけ、旧DB移行時は用途名を先頭に付けたフォルダ名を返します。
    private static func timestampFolderName(prefix: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let timestamp = formatter.string(from: .now)
        guard let prefix else { return timestamp }
        return "\(prefix) \(timestamp)"
    }

    private static func imageDimensions(source: CGImageSource) -> (width: Int, height: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (0, 0)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (width, height)
    }

    /// 一覧表示を軽くするため、最大640pxのJPEGサムネイルを生成します。
    private static func makeThumbnail(source: CGImageSource) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoVaultError.invalidImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoVaultError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoVaultError.invalidImage
        }
        return output as Data
    }
}
