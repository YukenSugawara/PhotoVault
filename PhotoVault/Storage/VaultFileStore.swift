import Foundation

/// 端末内部またはiCloud上の暗号化ファイル配置を管理します。
struct VaultFileStore {
    let kind: VaultKind
    let location: StorageLocation
    /// 鍵ごとに分離し、再作成したアルバムへ古いキャッシュを流用しません。
    var cacheNamespace: String? = nil
    /// テストでは実際の保管庫へ触れず、一時ディレクトリへ隔離します。
    var isolatedStorageRoot: URL? = nil

    private let fileManager = FileManager.default
    private let restartNamespace = LocalRestartState.namespace
    private let resetGeneration = CompleteVaultReset.generation
    private func validateAccess() throws {
        try CompleteVaultReset.validateStorageGeneration(resetGeneration)
        guard restartNamespace == LocalRestartState.namespace else { throw CancellationError() }
        try ICloudAccountGuard().validateBoundAccount()
    }

    /// 2つのアルバムごとに分離された保管ディレクトリを返します。
    var vaultDirectory: URL {
        get throws {
            try validateAccess()
            if let isolatedStorageRoot {
                return isolatedStorageRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
            }
            try validateAccess()
            let base: URL
            switch location {
            case .local:
                base = try fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            case .iCloud:
                try LocalRestartState.requireCloudAccess()
                #if DEBUG
                throw PhotoVaultError.iCloudDisabledInDebug
                #else
                guard let container = fileManager.url(forUbiquityContainerIdentifier: "iCloud.com.sugawarayuken.Album") else {
                    throw PhotoVaultError.iCloudUnavailable
                }
                try validateAccess()
                base = container.appendingPathComponent("Documents", isDirectory: true)
                #endif
            }
            if location == .local,
               let raw = UserDefaults.standard.string(forKey: Self.recoveryDirectoryKey(kind)),
               UUID(uuidString: raw) != nil {
                return base.appendingPathComponent("PhotoVaultRecovery", isDirectory: true)
                    .appendingPathComponent(raw, isDirectory: true)
                    .appendingPathComponent(kind.rawValue, isDirectory: true)
            }
            return base
                .appendingPathComponent(LocalRestartState.directory, isDirectory: true)
                .appendingPathComponent(kind.rawValue, isDirectory: true)
        }
    }

    static func recoveryDirectoryKey(_ kind: VaultKind) -> String {
        "vault.recovery-directory.\(kind.rawValue)"
    }

    static func recoveryRoot(id: UUID) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("PhotoVaultRecovery", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    var databaseURL: URL {
        get throws { try vaultDirectory.appendingPathComponent("vault-index.pvdb") }
    }

    var filesDirectory: URL {
        get throws { try vaultDirectory.appendingPathComponent("Files", isDirectory: true) }
    }

    var thumbnailsDirectory: URL {
        get throws { try vaultDirectory.appendingPathComponent("Thumbnails", isDirectory: true) }
    }

    func prepareDirectories() throws {
        try fileManager.createDirectory(at: try filesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: try thumbnailsDirectory, withIntermediateDirectories: true)
        try excludeLocalDirectoryFromBackupIfNeeded()
    }

    func writeDatabase(_ data: Data, expectedPrevious: Data? = nil) throws {
        try prepareDirectories()
        // 同期で届いた別の更新を、古い一覧で上書きしません。
        try coordinatedWrite(data, to: try databaseURL, expectedDatabase: expectedPrevious, checksDatabase: true)
        try? cacheDatabase(data)
    }

    func readDatabase() throws -> Data? {
        let url = try databaseURL
        // iCloudでは「未取得」と「存在しない」をfileExistsだけで区別できません。
        if location == .iCloud { return try readAvailableData(at: url, requiresCurrent: true) }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// 管理DBがないだけで、写真や完成済みバックアップを空アルバムとして隠さない。
    func ensureSafeToCreateLocalDatabase() throws {
        guard location == .local else { return }
        for directory in [try filesDirectory, try thumbnailsDirectory] {
            do {
                if !(try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)).isEmpty {
                    throw PhotoVaultError.databaseCorrupted
                }
            } catch {
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) { continue }
                throw error
            }
        }
        let backup = try automaticBackupDirectory().appendingPathComponent("manifest.pvauto")
        do {
            _ = try backup.resourceValues(forKeys: [.isRegularFileKey])
            throw PhotoVaultError.databaseCorrupted
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) { return }
            throw error
        }
    }

    func writePhoto(_ data: Data, named filename: String) throws {
        try prepareDirectories()
        try coordinatedWrite(data, to: try filesDirectory.appendingPathComponent(filename))
    }

    func writeThumbnail(_ data: Data, named filename: String) throws {
        try prepareDirectories()
        try coordinatedWrite(data, to: try thumbnailsDirectory.appendingPathComponent(filename))
        try? cacheThumbnail(data, named: filename)
    }

    func readPhoto(named filename: String) throws -> Data {
        try readAvailableData(at: try filesDirectory.appendingPathComponent(filename))
    }

    func readThumbnail(named filename: String) throws -> Data {
        try readAvailableData(at: try thumbnailsDirectory.appendingPathComponent(filename))
    }

    /// 非actorのasync関数なので、待機中にDB更新actorやメインスレッドを占有しません。
    func downloadDatabase() async throws -> DownloadedVaultIndex {
        try await CloudDownloadDeadline.run {
            let url = try databaseURL
            var fresh = url
            fresh.removeAllCachedResourceValues()
            let status = try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
            let current = status == .current
            if status == .downloaded { try? fileManager.startDownloadingUbiquitousItem(at: url) }
            let data = try await downloadedData(at: url, requiresCurrent: current)
            // 読む前に最新版と確認できなかった場合は、表示だけに利用します。
            return DownloadedVaultIndex(data: data, isCurrent: current)
        }
    }

    func downloadImage(named filename: String, thumbnail: Bool) async throws -> Data {
        let directory = thumbnail ? try thumbnailsDirectory : try filesDirectory
        return try await downloadedData(at: directory.appendingPathComponent(filename))
    }

    private func downloadedData(at url: URL, requiresCurrent: Bool = false) async throws -> Data {
        guard location == .iCloud else { return try Data(contentsOf: url) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        var nextDownloadRequest = clock.now
        var downloadRequestError: Error?
        while true {
            try Task.checkCancellation()
            try validateAccess()
            do {
                return try readAvailableData(at: url, requiresCurrent: requiresCurrent)
            } catch {
                try Task.checkCancellation()
                if clock.now >= nextDownloadRequest {
                    // 一時的なダウンロードエラー後も、開始要求をやり直します。
                    do { try fileManager.startDownloadingUbiquitousItem(at: url); downloadRequestError = nil }
                    catch { downloadRequestError = error }
                    nextDownloadRequest = clock.now.advanced(by: .seconds(3))
                }
                guard clock.now < deadline else { throw CloudReadAvailability.preferredError(readError: error, downloadError: downloadRequestError) }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func readAvailableData(at url: URL, requiresCurrent: Bool = false) throws -> Data {
        try validateAccess()
        guard location == .iCloud else { return try Data(contentsOf: url) }
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey
        ])
        try CloudReadAvailability.requireReadable(status: values.ubiquitousItemDownloadingStatus,
            requiresCurrent: requiresCurrent, downloadError: values.ubiquitousItemDownloadingError)
        // 利用可能になったファイルだけを調整して読み、通信待ちを同期I/Oに持ち込みません。
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges,
                                       error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw PhotoVaultError.iCloudDownloadPending }
        return try result.get()
    }

    private func coordinatedWrite(_ data: Data, to url: URL,
                                  expectedDatabase: Data? = nil, checksDatabase: Bool = false) throws {
        try validateAccess()
        if location == .local {
            // 端末内は同一プロセスの保存を直列化し、比較と書き込みの間への割り込みを防ぎます。
            VaultLocalDatabaseWrites.lock.lock()
            defer { VaultLocalDatabaseWrites.lock.unlock() }
            if checksDatabase { try validateDatabaseVersion(at: url, expected: expectedDatabase) }
            return try atomicWrite(data, to: url)
        }
        var coordinationError: NSError?
        var writeError: Error?
        let options: NSFileCoordinator.WritingOptions = fileManager.fileExists(atPath: url.path) ? .forReplacing : []
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options,
                                       error: &coordinationError) { coordinatedURL in
            do {
                try validateAccess()
                if checksDatabase {
                    if location == .iCloud {
                        guard expectedDatabase != nil else { throw PhotoVaultError.iCloudIndexNotReady }
                        var fresh = coordinatedURL
                        fresh.removeAllCachedResourceValues()
                        let values = try fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                        guard values.ubiquitousItemDownloadingStatus == .current else {
                            throw PhotoVaultError.iCloudIndexNotReady
                        }
                    }
                    try validateDatabaseVersion(at: coordinatedURL, expected: expectedDatabase)
                }
                try atomicWrite(data, to: coordinatedURL)
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func validateDatabaseVersion(at url: URL, expected: Data?) throws {
        let current: Data?
        do { current = try Data(contentsOf: url) }
        catch {
            let ns = error as NSError
            guard ns.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(ns.code)
            else { throw error }
            current = nil
        }
        guard current == expected else { throw MaintenanceError.databaseChanged }
    }

    private func automaticBackupKindDirectory() throws -> URL {
        try validateAccess()
        let base: URL
        if let isolatedStorageRoot { base = isolatedStorageRoot.appendingPathComponent("AutomaticBackups") }
        else {
            base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
                .appendingPathComponent("PhotoVaultAutoBackup")
                .appendingPathComponent(LocalRestartState.namespace ?? "original")
        }
        return base.appendingPathComponent(kind.rawValue)
    }

    func automaticBackupDirectory() throws -> URL {
        guard let cacheNamespace else { throw PhotoVaultError.credentialsMissing }
        return try automaticBackupKindDirectory().appendingPathComponent(cacheNamespace)
    }

    func readAutomaticBackupFile(_ name: String) throws -> Data {
        try Data(contentsOf: automaticBackupDirectory().appendingPathComponent(name))
    }

    func writeAutomaticBackupFile(_ data: Data, name: String) throws {
        let directory = try automaticBackupDirectory()
        let destination = directory.appendingPathComponent(name)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicWrite(data, to: destination)
    }

    func retainedBackupIDs() throws -> [String] {
        let directory = try automaticBackupDirectory().appendingPathComponent("Retained")
        do {
            return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "pvauto" }
                .map { $0.deletingPathExtension().lastPathComponent }
        } catch {
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code) { return [] }
            throw error
        }
    }

    func pruneAutomaticBackupFiles(keeping names: Set<String>) throws {
        let directory = try automaticBackupDirectory()
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try validateAccess()
            if !names.contains(url.lastPathComponent) { try fileManager.removeItem(at: url) }
        }
    }

    // キャッシュには既存のAES-GCM暗号文だけを保存し、元画像は重複保存しません。
    private var cacheDirectory: URL {
        get throws {
            guard location == .iCloud, let cacheNamespace else {
                throw CocoaError(.fileNoSuchFile)
            }
            let account = try ICloudAccountGuard().cloudNamespace()
            return try Self.cacheRoot()
                .appendingPathComponent(kind.rawValue, isDirectory: true)
                .appendingPathComponent(account, isDirectory: true)
                .appendingPathComponent(cacheNamespace, isDirectory: true)
        }
    }

    private static func cacheRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("PhotoVaultReadCache", isDirectory: true)
    }

    func cachedDatabase() throws -> Data {
        try Data(contentsOf: try cacheDirectory.appendingPathComponent("vault-index.pvdb"))
    }

    func cacheDatabase(_ encrypted: Data) throws {
        try writeCache(encrypted, to: try cacheDirectory.appendingPathComponent("vault-index.pvdb"))
    }

    func cachedThumbnail(named filename: String) throws -> Data {
        try Data(contentsOf: try cacheDirectory.appendingPathComponent("Thumbnails")
            .appendingPathComponent(filename))
    }

    func cacheThumbnail(_ encrypted: Data, named filename: String) throws {
        let directory = try cacheDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        try writeCache(encrypted, to: directory.appendingPathComponent(filename))
        // 一括取り込み中の全件走査を避け、最大1分に1回だけ容量を整理します。
        guard VaultCacheMaintenance.shared.shouldTrim(directory) else { return }
        // サムネイルのみ約128 MiB。古いものから削除し、DBの先行表示は維持します。
        let urls = try fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        let entries = urls.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > 128 * 1_024 * 1_024 {
            try? fileManager.removeItem(at: entry.0)
            total -= entry.1
        }
    }

    private func writeCache(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root = try Self.cacheRoot()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        try atomicWrite(data, to: url)
    }

    func clearReadCache() {
        if let url = try? cacheDirectory { try? fileManager.removeItem(at: url) }
    }

    func removePhoto(named filename: String, thumbnailNamed thumbnail: String) throws {
        if let cache = try? cacheDirectory {
            do { try fileManager.removeItem(at: cache.appendingPathComponent("Thumbnails").appendingPathComponent(thumbnail)) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
        let photoURL = try filesDirectory.appendingPathComponent(filename)
        let thumbnailURL = try thumbnailsDirectory.appendingPathComponent(thumbnail)
        try removeStoredFile(at: photoURL)
        try removeStoredFile(at: thumbnailURL)
    }

    private func removeStoredFile(at url: URL) throws {
        func remove(_ url: URL) throws {
            do { try fileManager.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
        guard location == .iCloud else { return try remove(url) }
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting,
                                                       error: &coordinationError) { coordinatedURL in
            result = Result {
                try validateAccess()
                try remove(coordinatedURL)
            }
        }
        if let error = coordinationError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { return }
            throw error
        }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }

    /// 復元データを一時ディレクトリへ完全に書いてから、現在のアルバムと原子的に入れ替えます。
    /// 書き込みや移動に失敗した場合は退避した旧アルバムを元へ戻します。
    func replaceVaultData(
        database: Data,
        photos: [String: Data],
        thumbnails: [String: Data]
    ) throws {
        let current = try vaultDirectory
        let parent = current.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".\(kind.rawValue)-restore-\(UUID().uuidString)")
        let rollback = parent.appendingPathComponent(".\(kind.rawValue)-rollback-\(UUID().uuidString)")
        let stagingFiles = staging.appendingPathComponent("Files", isDirectory: true)
        let stagingThumbnails = staging.appendingPathComponent("Thumbnails", isDirectory: true)
        var movedCurrentToRollback = false

        do {
            try fileManager.createDirectory(at: stagingFiles, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagingThumbnails, withIntermediateDirectories: true)
            try atomicWrite(database, to: staging.appendingPathComponent("vault-index.pvdb"))
            for (filename, data) in photos {
                try atomicWrite(data, to: stagingFiles.appendingPathComponent(filename))
            }
            for (filename, data) in thumbnails {
                try atomicWrite(data, to: stagingThumbnails.appendingPathComponent(filename))
            }

            if fileManager.fileExists(atPath: current.path) {
                try fileManager.moveItem(at: current, to: rollback)
                movedCurrentToRollback = true
            }
            try fileManager.moveItem(at: staging, to: current)
            if movedCurrentToRollback {
                // 新データへの切り替えは完了済みなので、退避領域の後片付け失敗で復元全体を失敗扱いにしません。
                try? fileManager.removeItem(at: rollback)
            }
            try? excludeLocalDirectoryFromBackupIfNeeded()
            clearReadCache()
            try? cacheDatabase(database)
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
            if movedCurrentToRollback,
               !fileManager.fileExists(atPath: current.path),
               fileManager.fileExists(atPath: rollback.path) {
                try? fileManager.moveItem(at: rollback, to: current)
            }
            throw error
        }
    }

    func storageStatus(database: VaultDatabase) -> VaultStorageStatus {
        VaultStorageStatus(checkedAt: .now, originalBytes: database.totalOriginalByteCount,
                           trashBytes: database.trashByteCount,
                           encryptedFileBytes: try? Self.directoryByteCount(at: filesDirectory),
                           thumbnailBytes: try? Self.directoryByteCount(at: thumbnailsDirectory),
                           indexBytes: try? Self.fileByteCount(at: databaseURL),
                           cacheBytes: location == .local ? 0 : (try? Self.directoryByteCount(at: cacheDirectory)))
    }

    func clearReadCacheReportingErrors() throws {
        guard location == .iCloud else { return }
        let directory = try cacheDirectory
        do { try fileManager.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }

    private static func fileByteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else { throw CocoaError(.fileReadUnknown) }
        return Int64(size)
    }

    private static func directoryByteCount(at directory: URL) throws -> Int64 {
        let manager = FileManager.default
        let urls: [URL]
        do {
            urls = try manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return 0
        }
        var total: Int64 = 0
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values.isDirectory == true { total += try directoryByteCount(at: url) }
            else if values.isRegularFile == true { total += try fileByteCount(at: url) }
        }
        return total
    }

    func cloudStatus(photos: [PhotoRecord]) throws -> VaultCloudStatus {
        guard location == .iCloud else {
            return VaultCloudStatus(checkedAt: .now, location: location, index: .unknown,
                                    uploadedPhotos: 0, pendingPhotos: 0,
                                    unknownPhotos: photos.count, failedPhotos: 0)
        }
        func state(_ url: URL) -> CloudFileState {
            var fresh = url
            fresh.removeAllCachedResourceValues()
            guard let values = try? fresh.resourceValues(forKeys: [
                .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
                .ubiquitousItemUploadingErrorKey, .ubiquitousItemHasUnresolvedConflictsKey
            ]) else { return .unknown }
            return .evaluate(isUbiquitous: values.isUbiquitousItem,
                             uploaded: values.ubiquitousItemIsUploaded,
                             uploading: values.ubiquitousItemIsUploading,
                             hasError: values.ubiquitousItemUploadingError != nil,
                             hasConflict: values.ubiquitousItemHasUnresolvedConflicts)
        }
        let originals = try filesDirectory
        let thumbnails = try thumbnailsDirectory
        var counts: [CloudFileState: Int] = [:]
        for photo in photos {
            let states = [state(originals.appendingPathComponent(photo.encryptedFilename)),
                          state(thumbnails.appendingPathComponent(photo.encryptedThumbnailFilename))]
            let combined: CloudFileState = states.contains(.failed) ? .failed
                : states.contains(.unknown) ? .unknown
                : states.contains(.pending) ? .pending : .uploaded
            counts[combined, default: 0] += 1
        }
        return VaultCloudStatus(checkedAt: .now, location: location, index: state(try databaseURL),
                                uploadedPhotos: counts[.uploaded, default: 0],
                                pendingPhotos: counts[.pending, default: 0],
                                unknownPhotos: counts[.unknown, default: 0],
                                failedPhotos: counts[.failed, default: 0])
    }

    /// 現在のアルバムディレクトリにある通常ファイルの合計サイズを返します。
    func storedByteCount() throws -> Int64 {
        let directory = try vaultDirectory
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// 現在のアルバムに属する暗号化DB・写真・サムネイルをまとめて削除します。
    func removeAllVaultData(recreateDirectories: Bool = true) throws {
        let directory = try vaultDirectory
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        if !LocalRestartState.isActive, let root = try? Self.cacheRoot().appendingPathComponent(kind.rawValue) {
            try? fileManager.removeItem(at: root)
        }
        let backups = try automaticBackupKindDirectory()
        if fileManager.fileExists(atPath: backups.path) { try fileManager.removeItem(at: backups) }
        if recreateDirectories {
            try prepareDirectories()
        }
    }

    /// 設定画面から全データ消去を実行した時に、両アルバムを端末とiCloudから削除します。
    static func removeAllApplicationData() throws {
        for kind in VaultKind.allCases {
            try VaultFileStore(kind: kind, location: .local)
                .removeAllVaultData(recreateDirectories: false)
        }

        if LocalRestartState.isActive { return }
        #if !DEBUG
        for kind in VaultKind.allCases {
            do {
                try VaultFileStore(kind: kind, location: .iCloud)
                    .removeAllVaultData(recreateDirectories: false)
            } catch PhotoVaultError.iCloudUnavailable {
                // iCloud Driveが未設定の場合は、端末内データの消去だけを完了させます。
            }
        }
        #endif
    }

    /// 移行先へ一度コピーしてから切り替え、途中失敗時の元データを保護します。
    static func migrate(
        kind: VaultKind,
        from: StorageLocation,
        to: StorageLocation,
        sourceIsEmpty: Bool
    ) throws {
        guard from != to else { return }
        let fileManager = FileManager.default
        let source = try VaultFileStore(kind: kind, location: from).vaultDirectory
        let destination = try VaultFileStore(kind: kind, location: to).vaultDirectory
        guard fileManager.fileExists(atPath: source.path) else {
            try VaultFileStore(kind: kind, location: to).prepareDirectories()
            return
        }

        let destinationDatabase = destination.appendingPathComponent("vault-index.pvdb")
        if fileManager.fileExists(atPath: destinationDatabase.path) {
            // 異なる鍵で作った空の保管庫から既存のiCloud保管庫を上書きしません。
            throw PhotoVaultError.destinationContainsVault
        }

        let destinationParent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        // 一時ディレクトリへのコピーが完了するまで、移行先を置き換えません。
        let staging = destinationParent.appendingPathComponent(".\(kind.rawValue)-migration-\(UUID().uuidString)")

        do {
            try ICloudAccountGuard().validateBoundAccount()
            try fileManager.copyItem(at: source, to: staging)
            try ICloudAccountGuard().validateBoundAccount()
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
            if from == .local {
                // iCloudフォルダへのコピー成功はアップロード完了ではありません。
                // 元の暗号化アルバムは端末内の退避領域へ移し、削除しません。
                _ = try Self.retainLocalMigrationSource(source)
            }
            // iCloudから端末へ移す場合も、以前のiCloudデータは削除しません。
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
            throw error
        }
    }

    @discardableResult
    static func retainLocalMigrationSource(_ source: URL) throws -> URL {
        let backup = source.deletingLastPathComponent()
            .appendingPathComponent(".\(source.lastPathComponent)-before-cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: backup)
        return backup
    }

    /// DBや写真が途中状態にならないよう原子的に書き込みます。
    private func atomicWrite(_ data: Data, to url: URL) throws {
        try validateAccess()
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private func excludeLocalDirectoryFromBackupIfNeeded() throws {
        guard location == .local else { return }
        var url = try vaultDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

/// 複数の画像要求が重なっても、キャッシュ全体の容量走査を繰り返しません。
private final class VaultCacheMaintenance: @unchecked Sendable {
    static let shared = VaultCacheMaintenance()
    private let lock = NSLock()
    private var lastTrim: [URL: Date] = [:]

    func shouldTrim(_ directory: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastTrim[directory] ?? .distantPast) >= 60 else { return false }
        lastTrim[directory] = now
        return true
    }
}

/// OSの同期I/Oが戻らなくても呼び出し側は期限内に復帰します。
/// 遅れて返った読み取り結果は破棄し、保管庫の状態を変更しません。
enum CloudDownloadDeadline {
    static func run<Value: Sendable>(seconds: Double = 25, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let state = PendingCloudDownload<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let worker = Task.detached {
                    do { state.finish(.success(try await operation())) }
                    catch { state.finish(.failure(error)) }
                }
                let timer = Task.detached {
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    state.finish(.failure(CloudDownloadTimeout()))
                }
                state.attach([worker, timer])
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }
}

struct CloudDownloadTimeout: LocalizedError {
    var errorDescription: String? {
        "iCloudの応答が時間内に返りませんでした。通信接続とiCloud Driveの状態を確認して再読み込みしてください。既存の写真は変更していません。"
    }
}

private final class PendingCloudDownload<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        let completed = result
        if completed == nil { self.continuation = continuation }
        lock.unlock()
        if let completed { continuation.resume(with: completed) }
    }

    func attach(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        let completed = result != nil
        if !completed { self.tasks = tasks }
        lock.unlock()
        if completed { tasks.forEach { $0.cancel() } }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

struct DownloadedVaultIndex: Sendable {
    let data: Data
    let isCurrent: Bool
}

/// 取得済みの実体を読める場合、過去の追加ダウンロードエラーだけでは拒否しません。
enum CloudReadAvailability {
    static func requireReadable(status: URLUbiquitousItemDownloadingStatus?, requiresCurrent: Bool,
                                downloadError: Error?) throws {
        if status == .current || (!requiresCurrent && status == .downloaded) { return }
        if let downloadError { throw downloadError }
        throw PhotoVaultError.iCloudDownloadPending
    }

    /// 存在しないURLへの開始要求は実機で257を返すため、読み取り時の不在を優先します。
    static func preferredError(readError: Error, downloadError: Error?) -> Error {
        guard let downloadError else { return readError }
        let value = readError as NSError
        let missing = (value.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(value.code))
            || (value.domain == NSPOSIXErrorDomain && value.code == 2)
        let denied = value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoPermissionError
        let selected = (missing || denied ? readError : downloadError) as NSError
        var info = selected.userInfo
        info[CloudRestoreDiagnostics.readDetailsKey] = CloudRestoreDiagnostics.message(for: readError)
        info[CloudRestoreDiagnostics.downloadDetailsKey] = CloudRestoreDiagnostics.message(for: downloadError)
        // 優先するコードは変えず、消えていた前段のエラーも報告に残します。
        return NSError(domain: selected.domain, code: selected.code, userInfo: info)
    }

    static func readBeforeRequestingDownload(read: () throws -> Data, requestDownload: () throws -> Void) throws -> Data {
        do { return try read() }
        catch {
            let readError = error
            do { try requestDownload() }
            catch { throw preferredError(readError: readError, downloadError: error) }
            throw readError
        }
    }
}


private enum VaultLocalDatabaseWrites {
    static let lock = NSLock()
}
