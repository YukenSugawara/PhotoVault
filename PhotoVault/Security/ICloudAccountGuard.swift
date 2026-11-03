import CryptoKit
import Foundation

/// iCloudの保存領域はOSがApple Accountごとに分離します。
/// このガードは、端末に残った鍵・キャッシュを別のアカウントで再利用するのを防ぎます。
struct ICloudAccountGuard {
    private var ownerAccount: String { LocalRestartState.account("icloud-vault-owner-token-v1") }
    private let keychain = KeychainStore()

    // Appleが比較用として提供する不透明トークンのみを保存し、メールアドレス等は取得しません。
    func bindIfNeeded() throws {
        if LocalRestartState.isActive { return }
        if try keychain.read(account: ownerAccount, synchronizable: false) != nil {
            try validateBoundAccount()
            return
        }
        guard let token = FileManager.default.ubiquityIdentityToken else { return }
        let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
        try keychain.save(data, account: ownerAccount, synchronizable: false)
    }

    func validateBoundAccount() throws {
        if LocalRestartState.isActive { return }
        guard let saved = try keychain.read(account: ownerAccount, synchronizable: false) else { return }
        try Self.validate(saved: saved, current: FileManager.default.ubiquityIdentityToken)
    }

    func cloudNamespace() throws -> String {
        try LocalRestartState.requireCloudAccess()
        guard let saved = try keychain.read(account: ownerAccount, synchronizable: false) else {
            throw PhotoVaultError.iCloudUnavailable
        }
        try Self.validate(saved: saved, current: FileManager.default.ubiquityIdentityToken)
        return SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined()
    }

    /// PINで得た鍵が現在のiCloud管理データを復号できる場合にだけ、端末の関連付けを更新します。
    func reconnect(using unlocked: UnlockedVault) async throws {
        try LocalRestartState.requireCloudAccess()
        guard let token = FileManager.default.ubiquityIdentityToken else { throw CloudAccountError.signedOut }
        let expectedIdentity = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
        let data: Data = try await CloudDownloadDeadline.run {
            #if DEBUG
            throw PhotoVaultError.iCloudDisabledInDebug
            #else
            let manager = FileManager.default
            guard let container = manager.url(forUbiquityContainerIdentifier: "iCloud.com.sugawarayuken.Album") else {
                throw PhotoVaultError.iCloudUnavailable
            }
            let url = container.appendingPathComponent("Documents/PhotoVault")
                .appendingPathComponent(unlocked.kind.rawValue).appendingPathComponent("vault-index.pvdb")
            var nextDownloadRequest = Date.distantPast
            return try await Self.waitForDownloadedIndex {
                try Self.validate(saved: expectedIdentity, current: manager.ubiquityIdentityToken)
                return try CloudReadAvailability.readBeforeRequestingDownload(read: {
                var fresh = url
                fresh.removeAllCachedResourceValues()
                let values = try CloudRestoreDiagnostics.atStage("metadata") {
                    try fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey,
                                                       .ubiquitousItemDownloadingErrorKey])
                }
                try CloudRestoreDiagnostics.atStage("download-status") {
                    try CloudReadAvailability.requireReadable(status: values.ubiquitousItemDownloadingStatus,
                        requiresCurrent: false, downloadError: values.ubiquitousItemDownloadingError)
                }
                var error: NSError?
                var result: Result<Data, Error>?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &error) {
                    coordinatedURL in result = Result {
                        try CloudRestoreDiagnostics.atStage("file-read") { try Data(contentsOf: coordinatedURL) }
                    }
                }
                if let error {
                    try CloudRestoreDiagnostics.atStage("file-coordination") { throw error }
                }
                guard let result else { throw PhotoVaultError.iCloudDownloadPending }
                return try result.get()
                }, requestDownload: {
                    if Date() >= nextDownloadRequest {
                        nextDownloadRequest = Date().addingTimeInterval(3)
                        try CloudRestoreDiagnostics.atStage("download-request") {
                            try manager.startDownloadingUbiquitousItem(at: url)
                        }
                    }
                })
            }
            #endif
        }
        try Task.checkCancellation()
        try confirmReconnection(data, key: unlocked.masterKey, expectedIdentity: expectedIdentity,
                                currentIdentity: { FileManager.default.ubiquityIdentityToken })
    }

    /// 新端末ではファイルのメタデータと実体の到着が遅れるため、不在・取得待ちだけを再試行します。
    static func waitForDownloadedIndex(timeout: Duration = .seconds(20), interval: Duration = .milliseconds(500),
                                       read: () throws -> Data) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            do { return try read() }
            catch {
                let ns = error as NSError
                let missing = (ns.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(ns.code))
                    || (ns.domain == NSPOSIXErrorDomain && ns.code == 2)
                let pending: Bool
                if case PhotoVaultError.iCloudDownloadPending = error { pending = true } else { pending = false }
                guard (missing || pending), clock.now < deadline else { throw error }
                try await Task.sleep(for: interval)
            }
        }
    }

    func confirmReconnection(_ encrypted: Data, key: Data, expectedIdentity: Data, currentIdentity: () -> Any?) throws {
        // 検証に失敗した場合は、以前の関連付けもクラウドのファイルも変更しません。
        try Self.validate(saved: expectedIdentity, current: currentIdentity())
        _ = try VaultRepository.decodeCloudDatabase(encrypted, key: key)
        try Self.validate(saved: expectedIdentity, current: currentIdentity())
        try keychain.save(expectedIdentity, account: ownerAccount, synchronizable: false)
    }

    static func validate(saved: Data, current: Any?) throws {
        guard let current else { throw CloudAccountError.signedOut }
        // NSCoding対応のOSトークンを、アプリ自身の端末専用Keychainからのみ復元します。
        guard let owner = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(saved) as? NSObject,
              owner.isEqual(current) else { throw CloudAccountError.changed }
    }
}

enum CloudAccountError: LocalizedError {
    case changed, signedOut
    var errorDescription: String? {
        switch self {
        case .changed:
            "iCloudの識別情報が以前の記録と一致しません。Apple Accountを変更していなくても、この確認が必要になる場合があります。同じ保管庫であることをPIN・パスワードとiCloudのデータで確認して再接続できます。写真や認証情報は削除していません。"
        case .signedOut:
            "この保管庫で使用していたiCloudからサインアウトしています。同じApple Accountでサインインしてから再確認してください。"
        }
    }
}


/// ユーザーが完全削除を明示した場合だけ使う独立した経路。
/// 以前のアカウントの保管庫ではなく、現在サインイン中のアカウントのアプリ領域が対象です。
enum CompleteVaultReset {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var active = false
        var generation = UUID()
    }
    private static let state = State()
    static var generation: UUID {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.generation
    }
    static func begin() {
        state.lock.lock(); defer { state.lock.unlock() }
        state.generation = UUID()
        state.active = true
    }
    static func end() {
        state.lock.lock(); defer { state.lock.unlock() }
        state.active = false
    }
    static func validateStorageGeneration(_ generation: UUID) throws {
        state.lock.lock(); defer { state.lock.unlock() }
        guard !state.active, generation == state.generation else { throw CancellationError() }
    }

    static func perform(validateIdentity: () throws -> Void,
                        deleteCloud: () throws -> Void,
                        deleteLocal: () throws -> Void,
                        deleteCredentials: () throws -> Void) throws {
        try validateIdentity()
        try deleteCloud()
        try validateIdentity()
        try deleteLocal()
        try validateIdentity()
        try deleteCredentials()
    }

    static func currentIdentity() throws -> Data {
        guard let token = FileManager.default.ubiquityIdentityToken else { throw CloudAccountError.signedOut }
        return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
    }

    static func erase(expectedIdentity: Data) throws {
        #if DEBUG
        throw PhotoVaultError.iCloudDisabledInDebug
        #else
        let manager = FileManager.default
        let validate = { try ICloudAccountGuard.validate(saved: expectedIdentity, current: manager.ubiquityIdentityToken) }
        try validate()
        guard let container = manager.url(forUbiquityContainerIdentifier: "iCloud.com.sugawarayuken.Album") else {
            throw PhotoVaultError.iCloudUnavailable
        }
        let cloud = container.appendingPathComponent("Documents/PhotoVault", isDirectory: true)
        try perform(validateIdentity: validate, deleteCloud: {
            // 不在・アクセス拒否もそのまま返す。見えていないだけの可能性があるため鍵を消さない。
            var coordinationError: NSError?
            var deletionError: Error?
            var deleted = false
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: cloud, options: .forDeleting,
                                                             error: &coordinationError) { coordinated in
                do {
                    try validate()
                    try manager.removeItem(at: coordinated)
                    deleted = true
                } catch { deletionError = error }
            }
            if let coordinationError { throw coordinationError }
            if let deletionError { throw deletionError }
            guard deleted else { throw PhotoVaultError.iCloudDownloadPending }
        }, deleteLocal: {
            let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: false)
            for directory in ["PhotoVault", "PhotoVault-Restart", "PhotoVaultReadCache", "PhotoVaultAutoBackup", "PhotoVaultRecovery"] {
                try validate()
                do { try manager.removeItem(at: support.appendingPathComponent(directory, isDirectory: true)) }
                catch {
                    let value = error as NSError
                    guard value.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code)
                    else { throw error }
                }
            }
        }, deleteCredentials: {
            // ファイル削除の成功後にのみ認証情報を削除します。
            NSUbiquitousKeyValueStore.default.removeObject(forKey: "PhotoVault.vault-profiles-v1")
            NSUbiquitousKeyValueStore.default.synchronize()
            try validate()
            try KeychainStore().deleteEntireService()
        })
        #endif
    }
}
