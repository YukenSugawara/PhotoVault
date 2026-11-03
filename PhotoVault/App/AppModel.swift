import Foundation
import PhotosUI
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

import UIKit

/// 配布先によって異なる課金・広告の動作を一か所で切り替えます。
///
/// PhotoVault-Personal-スキームでは`PERSONAL_BUILD`を有効にします。
/// 通常機能のコードは両スキームで共通にし、この定義を通して課金・広告を分岐することで、
/// 今後の機能修正を両方へ安全に反映しやすくしています。
enum AppDistribution {
#if PERSONAL_BUILD
    static let isPersonalEdition = true
#else
    static let isPersonalEdition = false
#endif

    static let usesSubscriptions = !isPersonalEdition
    static let showsAdvertising = !isPersonalEdition

    /// ホーム画面と同じアプリ名をInfo.plistから取得します。
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "アルバム"
    }
}

/// アプリ起動後の認証・アルバム選択・表示状態を表します。
enum AppLockState: Hashable {
    case needsSetup
    case locked
    case choosingVault
    case unlocking
    case unlocked
}

@MainActor
/// 画面から利用する状態と、認証・保存処理の橋渡しを一元管理します。
final class AppModel: ObservableObject {
    // MARK: - 画面へ公開する状態

    @Published private(set) var lockState: AppLockState
    @Published private(set) var currentVaultKind: VaultKind?
    @Published private(set) var database: VaultDatabase = .empty {
        didSet { cloudStatus = nil; storageStatus = nil; duplicateScan = nil; similarPhotoScan = nil; maintenanceRevision = UUID() }
    }
    @Published private(set) var maintenanceRevision = UUID()
    @Published private(set) var cloudStatus: VaultCloudStatus?
    @Published private(set) var storageStatus: VaultStorageStatus?

    func checkStorageStatus() async {
        guard let repository else { return }
        let revision = maintenanceRevision
        let result = await repository.storageStatus()
        guard self.repository === repository, revision == maintenanceRevision else { return }
        storageStatus = result
    }

    func clearDisplayCache() async {
        guard let repository, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let requests = Array(imageRequests.values)
        for request in requests { request.task.cancel() }
        imageRequests.removeAll()
        for request in requests { _ = await request.task.result }
        imageDataCache.removeAllObjects()
        do {
            try await repository.clearReadCache()
            guard self.repository === repository else { return }
            await checkStorageStatus()
        } catch {
            guard self.repository === repository else { return }
            errorMessage = error.localizedDescription
        }
    }
    @Published private(set) var cloudStatusError: String?
    @Published private(set) var duplicateScan: DuplicateScanResult?
    @Published private(set) var isScanningDuplicates = false

    func scanDuplicatePhotos() async {
        guard canEditVault, let repository, !isScanningDuplicates, !isScanningSimilarPhotos else { return }
        isScanningDuplicates = true
        duplicateScan = nil
        defer { isScanningDuplicates = false }
        let previousOCR = ocrIndexingTask
        previousOCR?.cancel()
        await previousOCR?.value
        do {
            try Task.checkCancellation()
            let result = try await repository.scanDuplicates()
            guard self.repository === repository else { return }
            duplicateScan = result
        } catch is CancellationError { }
        catch {
            guard self.repository === repository else { return }
            errorMessage = error.localizedDescription
        }
    }

    @Published private(set) var similarPhotoScan: SimilarPhotoScanResult?
    @Published private(set) var isScanningSimilarPhotos = false

    func scanSimilarPhotos() async {
        guard canEditVault, let repository, !isScanningSimilarPhotos, !isScanningDuplicates else { return }
        isScanningSimilarPhotos = true
        similarPhotoScan = nil
        defer { isScanningSimilarPhotos = false }
        let previousOCR = ocrIndexingTask
        previousOCR?.cancel()
        await previousOCR?.value
        do {
            try Task.checkCancellation()
            let result = try await repository.scanSimilarPhotos()
            try Task.checkCancellation()
            guard self.repository === repository else { return }
            similarPhotoScan = result
        } catch is CancellationError { }
        catch {
            guard self.repository === repository else { return }
            errorMessage = error.localizedDescription
        }
    }

    func removeDuplicates(_ group: DuplicatePhotoGroup, keeping id: UUID) async {
        await maintainVault { try await $0.trashDuplicates(group: group, keeping: id) }
    }

    func resumeOCRAfterDuplicateReview() {
        enqueueOCRIndexing(photoIDs: database.photos.filter { $0.ocrText == nil }.map(\.id))
    }

    var lastBackupExportDate: Date? {
        guard let currentVaultKind else { return nil }
        return UserDefaults.standard.object(forKey: "backup.last-export.\(currentVaultKind.rawValue)") as? Date
    }

    func recordBackupExport(for kind: VaultKind) {
        UserDefaults.standard.set(Date(), forKey: "backup.last-export.\(kind.rawValue)")
        objectWillChange.send()
    }

    var hasRecoveryCredentials: Bool { authentication.hasProfiles }

    func checkCloudStatus() async {
        guard let repository, hasLoadedVaultIndex else { return }
        let revision = maintenanceRevision
        cloudStatusError = nil
        do {
            let result = try await repository.cloudStatus()
            guard self.repository === repository, maintenanceRevision == revision else { return }
            cloudStatus = result
        } catch {
            guard self.repository === repository, maintenanceRevision == revision else { return }
            cloudStatus = nil
            cloudStatusError = error.localizedDescription
        }
    }
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published private(set) var authenticationFailureCount = 0
    @Published private(set) var pinBlockedUntil: Date?
    @Published private(set) var pinStateUnavailable = false

    func refreshPINWaitState() {
        do {
            pinBlockedUntil = try PINAttemptLimiter().state().blockedUntil
            pinStateUnavailable = false
        } catch {
            pinStateUnavailable = true
        }
    }
    @Published private(set) var theme: AppTheme
    @Published private(set) var iconStyle: AppIconStyle
    @Published private(set) var biometricsEnabled: Bool
    @Published private(set) var biometricUnlockDestination: BiometricUnlockDestination
    @Published private(set) var passwordEnabled: Bool
    @Published private(set) var subVaultEnabled: Bool
    @Published private(set) var mainPINConfigured: Bool
    @Published private(set) var subPINConfigured: Bool
    @Published private(set) var selectionWasBiometric = false
    @Published private(set) var hasConfirmedRecoveredCredential = false
    @Published private(set) var legacyCredentialMode: Bool
    @Published private(set) var autoLockInterval: AutoLockInterval
    @Published private(set) var currentVaultStorageBytes: Int64 = 0
    @Published private(set) var isOCRIndexing = false
    @Published private(set) var ocrIndexProgress: Double = 0
    @Published private(set) var subscriptionProducts: [Product] = []
    @Published private(set) var hasActiveSubscription = false
    @Published private(set) var isSubscriptionLoading = false
    @Published private(set) var subscriptionMessage: String?
    @Published var showsSubscriptionSheet = false
    @Published private(set) var hasLoadedVaultIndex = false
    @Published private(set) var isRefreshingCloud = false
    @Published private(set) var cloudLoadMessage: String?
    @Published private(set) var canEditVault = false
    @Published private(set) var imageReloadToken = UUID()
    @Published private(set) var isRecoveringFromICloud = false

    private let authentication = AuthenticationService()
    private var repository: VaultRepository?
    private var sessionMasterKey: Data?
    private var backgroundedAt: Date?
    private var pendingOCRPhotoIDs = Set<UUID>()
    private var ocrIndexingTask: Task<Void, Never>?
    private var cloudRefreshTask: Task<Void, Never>?
    private var cloudLoadWatchdog: Task<Void, Never>?
    private var cloudLoadRequestID = UUID()
    @Published private(set) var cloudLoadStage = ""
    private var cloudMetadataQuery: NSMetadataQuery?
    private var cloudMetadataObservers: [NSObjectProtocol] = []
    private var vaultSessionID = UUID()
    private struct ImageRequest {
        let id = UUID()
        let task: Task<Data, Error>
    }
    private var imageRequests: [NSString: ImageRequest] = [:]
    /// 復号済みデータを短時間保持し、同じ画像のディスク読込と復号の繰り返しを防ぎます。
    private let imageDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 180
        cache.totalCostLimit = 128 * 1_024 * 1_024
        return cache
    }()

    static let freePhotoLimit = 100
    static let monthlySubscriptionID = "jp.photovault.premium.monthly"
    static let yearlySubscriptionID = "jp.photovault.premium.yearly"
    static let subscriptionProductIDs = [monthlySubscriptionID, yearlySubscriptionID]

    /// 保存済み設定と認証情報を読み込み、最初に表示する画面を決定します。
    @Published private(set) var iCloudAccountIssue: String?
    @Published private(set) var isRecoveringCredentials = false
    private var recoveryGeneration = UUID()

    func cancelCredentialRecovery() {
        recoveryGeneration = UUID()
        isRecoveringCredentials = false
    }

    func reconnectICloudAccount(credential: String) async {
        guard iCloudAccountIssue != nil, !isWorking, !credential.isEmpty else { return }
        isWorking = true
        defer { isWorking = false; refreshPINWaitState() }
        do {
            let authentication = authentication
            let unlocked = try await Task.detached {
                try authentication.unlock(password: credential, forAccountRecovery: true)
            }.value
            try await ICloudAccountGuard().reconnect(using: unlocked)
            try Task.checkCancellation()
            refreshICloudAccount()
            guard iCloudAccountIssue == nil else { return }
            lockState = .locked
            // 既に入力したパスワードで端末鍵も復旧し、再入力なしでアルバムを開きます。
            let authenticated = try await Task.detached {
                try authentication.unlock(password: credential)
            }.value
            if authenticated.kind == .sub, !canAccessSubVault {
                presentSubscriptionOffer()
                return
            }
            try await open(authenticated)
        } catch {
            errorMessage = CloudRestoreDiagnostics.message(for: error)
        }
    }

    func refreshICloudAccount() {
        if isCompletelyResetting { return }
        do {
            try ICloudAccountGuard().bindIfNeeded()
            iCloudAccountIssue = nil
        } catch {
            cancelCredentialRecovery()
            lock()
            if !authentication.hasLocalProfiles { lockState = .needsSetup }
            iCloudAccountIssue = error.localizedDescription
        }
    }

    init() {
        // 再インストールを検知した場合は、KeychainとiCloud上の暗号化データを維持し、
        // 失われた保存先設定だけをiCloudへ戻して安全な復元を開始します。
        InstallationLifecycleService().prepareForLaunch()

        // 前回の共有中にアプリが終了した場合も、復号済み一時ファイルを次回起動時に残しません。
        Self.removeStaleShareFiles()
        let defaults = UserDefaults.standard
        let hasProfiles = AuthenticationService().hasProfiles
        // 新しい端末などでインストール識別子が引き継がれなくても、同期済み認証情報があり、
        // 保存先設定だけが消えている場合は既存iCloud保管庫の復元として扱います。
        let hasStoredLocation = VaultKind.allCases.contains {
            defaults.object(forKey: "vault.storage.\($0.rawValue)") != nil
        }
        if hasProfiles && !hasStoredLocation {
            for kind in VaultKind.allCases {
                defaults.set(StorageLocation.iCloud.rawValue, forKey: "vault.storage.\(kind.rawValue)")
            }
            defaults.set(true, forKey: InstallationLifecycleService.recoveryPendingKey)
        }
        isRecoveringFromICloud = defaults.bool(forKey: InstallationLifecycleService.recoveryPendingKey)
        let usesLegacyCredentials = hasProfiles && (defaults.object(forKey: "auth.legacy-credential-mode") != nil
            ? defaults.bool(forKey: "auth.legacy-credential-mode")
            : defaults.object(forKey: "auth.pin-enabled") == nil)

        // lockStateを初期化する前にインスタンスプロパティを参照すると
        // Swiftの初期化エラーになるため、まずローカル値として設定を確定します。
        let initialPasswordEnabled: Bool
        let initialSubVaultEnabled: Bool
        let initialMainPINConfigured: Bool
        let initialSubPINConfigured: Bool
        let initialBiometricsEnabled = defaults.bool(forKey: "auth.biometrics-enabled")
        let initialBiometricDestination = BiometricUnlockDestination(
            rawValue: defaults.string(forKey: "auth.biometric-destination") ?? ""
        ) ?? .chooseEveryTime
        let initialAutoLockInterval = AutoLockInterval(
            rawValue: defaults.string(forKey: "auth.auto-lock-interval") ?? ""
        ) ?? .immediately

        theme = AppTheme(rawValue: defaults.string(forKey: "app.theme") ?? "") ?? .midnight
        iconStyle = AppIconStyle(rawValue: defaults.string(forKey: "app.icon") ?? "") ?? .standard
        biometricsEnabled = initialBiometricsEnabled
        biometricUnlockDestination = initialBiometricDestination
        autoLockInterval = initialAutoLockInterval

        if hasProfiles {
            // 旧版からの更新時は、従来どおりPINとサブアルバムを有効として引き継ぎます。
            initialPasswordEnabled = defaults.object(forKey: "auth.pin-enabled") == nil
                ? true
                : defaults.bool(forKey: "auth.pin-enabled")
            initialSubVaultEnabled = defaults.object(forKey: "vault.sub-enabled") == nil
                ? true
                : defaults.bool(forKey: "vault.sub-enabled")
            initialMainPINConfigured = defaults.object(forKey: "auth.main-pin-configured") == nil
                ? !usesLegacyCredentials
                : defaults.bool(forKey: "auth.main-pin-configured")
            initialSubPINConfigured = defaults.object(forKey: "auth.sub-pin-configured") == nil
                ? !usesLegacyCredentials
                : defaults.bool(forKey: "auth.sub-pin-configured")
        } else {
            initialPasswordEnabled = true
            initialSubVaultEnabled = false
            initialMainPINConfigured = false
            initialSubPINConfigured = false
        }

        passwordEnabled = initialPasswordEnabled
        subVaultEnabled = initialSubVaultEnabled
        mainPINConfigured = initialMainPINConfigured
        subPINConfigured = initialSubPINConfigured
        legacyCredentialMode = usesLegacyCredentials
        hasConfirmedRecoveredCredential = defaults.bool(forKey: "auth.recovered-credential-confirmed")

        // ここではインスタンスプロパティを読まず、確定済みのローカル値だけで分岐します。
        if !hasProfiles {
            lockState = .needsSetup
        } else if initialPasswordEnabled || initialBiometricsEnabled {
            lockState = .locked
        } else {
            lockState = .unlocking
        }
        refreshICloudAccount()
    }

    var biometryName: String { authentication.availableBiometryName() }

    var biometricsAreAvailable: Bool { authentication.biometricsAreAvailable() }

    /// Touch ID端末では指紋、Face ID端末では顔のシステムアイコンを返します。
    var biometrySymbolName: String {
        switch biometryName {
        case "Touch ID": "touchid"
        case "Face ID": "faceid"
        default: "person.badge.key.fill"
        }
    }

    var availableVaultKinds: [VaultKind] {
        canAccessSubVault ? VaultKind.allCases : [.main]
    }

    var canCancelVaultSelection: Bool {
        passwordEnabled || biometricsEnabled
    }

    var canEnablePasswordWithoutConfiguration: Bool {
        mainPINConfigured && (!canAccessSubVault || subPINConfigured)
    }

    /// 個人用はすべての機能を常時利用可能にし、リリース用はStoreKitが検証した
    /// 有効な購入だけをプレミアム権利として扱います。
    var hasPremiumAccess: Bool {
        AppDistribution.isPersonalEdition || hasActiveSubscription
    }

    var canAccessSubVault: Bool {
        subVaultEnabled && hasPremiumAccess
    }

    var storageLocation: StorageLocation {
        guard let kind = currentVaultKind else { return .local }
        return storageLocation(for: kind)
    }

    var isICloudAvailableInThisBuild: Bool {
        #if DEBUG
        return false
        #else
        return !LocalRestartState.isActive
        #endif
    }

    @Published var showsLocalRestartConfirmation = false
    var isLocalRestartMode: Bool { LocalRestartState.isActive }

    /// 前の設定・鍵・ファイルを残し、別領域で初期設定を開始します。
    func restartLocally() {
        guard !isWorking else { return }
        do {
            let defaults = UserDefaults.standard
            let id = UUID().uuidString
            let settings = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
            let snapshot = try PropertyListSerialization.data(fromPropertyList:
                settings.filter { !$0.key.hasPrefix("vault.restart-settings.") }, format: .binary, options: 0)
            cancelCredentialRecovery()
            lock()
            for request in imageRequests.values { request.task.cancel() }
            imageRequests.removeAll()
            defaults.set(snapshot, forKey: "vault.restart-settings." + id)
            defaults.set(id, forKey: LocalRestartState.namespaceKey)
            for kind in VaultKind.allCases {
                defaults.set(StorageLocation.local.rawValue, forKey: storageKey(for: kind))
                defaults.removeObject(forKey: "vault.separate-recovery.\(kind.rawValue)")
                defaults.removeObject(forKey: VaultFileStore.recoveryDirectoryKey(kind))
            }
            defaults.removeObject(forKey: InstallationLifecycleService.recoveryPendingKey)
            isRecoveringFromICloud = false
            iCloudAccountIssue = nil
            errorMessage = nil
            passwordEnabled = true
            subVaultEnabled = false
            mainPINConfigured = false
            subPINConfigured = false
            biometricsEnabled = false
            biometricUnlockDestination = .chooseEveryTime
            legacyCredentialMode = false
            saveSecurityPreferences()
            defaults.set(false, forKey: "auth.biometrics-enabled")
            defaults.set(BiometricUnlockDestination.chooseEveryTime.rawValue, forKey: "auth.biometric-destination")
            lockState = .needsSetup
            showsLocalRestartConfirmation = false
            refreshPINWaitState()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - サブスクリプション

    /// 月額・年額の商品をStoreKitから取得します。
    /// Debug実行時は共有Schemeに指定したPhotoVault.storekit、Release版はApp Store Connectが取得元です。
    func prepareSubscriptions() async {
        // 個人用では課金画面を使用しないため、App Storeへ商品情報を問い合わせません。
        guard AppDistribution.usesSubscriptions else {
            subscriptionProducts = []
            subscriptionMessage = nil
            hasActiveSubscription = true
            return
        }

        // 起動処理と料金画面の再取得が重なっても、同じ問い合わせを二重実行しません。
        guard !isSubscriptionLoading else { return }

        // 再読み込み時に古い商品を一度空にし、取得失敗を成功時の一覧と混同しないようにします。
        subscriptionProducts = []
        subscriptionMessage = nil
        isSubscriptionLoading = true
        defer { isSubscriptionLoading = false }

        do {
            let products = try await Product.products(for: Self.subscriptionProductIDs)
            subscriptionProducts = products.sorted {
                let firstIndex = Self.subscriptionProductIDs.firstIndex(of: $0.id) ?? Int.max
                let secondIndex = Self.subscriptionProductIDs.firstIndex(of: $1.id) ?? Int.max
                return firstIndex < secondIndex
            }
            if products.isEmpty {
                subscriptionMessage = "料金プランを取得できませんでした。「再読み込み」をお試しください。"
            } else if products.count != Self.subscriptionProductIDs.count {
                subscriptionMessage = "App Storeから一部の料金プランを取得できませんでした。"
            } else {
                subscriptionMessage = nil
            }
        } catch {
            subscriptionMessage = "料金プランを取得できませんでした。通信状態を確認して再読み込みしてください。"
        }
        await refreshSubscriptionStatus()
    }

    /// App Storeが現在有効と判定した月額・年額プランだけをプレミアム権利として扱います。
    func refreshSubscriptionStatus() async {
        // 個人用は購入状態に依存せず、プレミアム機能を常時有効にします。
        guard AppDistribution.usesSubscriptions else {
            hasActiveSubscription = true
            return
        }

        var isActive = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.subscriptionProductIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let expirationDate = transaction.expirationDate, expirationDate <= .now {
                continue
            }
            isActive = true
            break
        }

        hasActiveSubscription = isActive
        if !isActive, currentVaultKind == .sub {
            lock()
        }
    }

    /// アプリ外での購入・更新・解約結果も受け取り、利用権を更新します。
    func observeSubscriptionTransactions() async {
        // 個人用ではStoreKitのトランザクション監視を開始しません。
        guard AppDistribution.usesSubscriptions else { return }

        for await result in Transaction.updates {
            guard !Task.isCancelled else { return }
            guard case .verified(let transaction) = result,
                  Self.subscriptionProductIDs.contains(transaction.productID) else { continue }
            await transaction.finish()
            await refreshSubscriptionStatus()
        }
    }

    /// Appleの購入確認画面を表示し、検証済み取引だけをアプリへ反映します。
    func purchaseSubscription(_ product: Product) async {
        // 個人用から誤って購入処理が呼ばれても、App Store画面を表示しません。
        guard AppDistribution.usesSubscriptions else { return }

        isSubscriptionLoading = true
        defer { isSubscriptionLoading = false }
        subscriptionMessage = nil

        do {
            let purchaseResult = try await product.purchase()
            switch purchaseResult {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    subscriptionMessage = "購入情報を確認できませんでした。"
                    return
                }
                await transaction.finish()
                await refreshSubscriptionStatus()
                if hasActiveSubscription {
                    showsSubscriptionSheet = false
                }
            case .pending:
                subscriptionMessage = "購入は承認待ちです。承認後に自動で反映されます。"
            case .userCancelled:
                break
            @unknown default:
                subscriptionMessage = "購入処理を完了できませんでした。"
            }
        } catch {
            subscriptionMessage = "購入処理に失敗しました。時間をおいて再度お試しください。"
        }
    }

    /// 同じApple Accountで購入済みの権利を再確認します。
    func restoreSubscriptions() async {
        // 個人用には復元対象となる購入がありません。
        guard AppDistribution.usesSubscriptions else { return }

        isSubscriptionLoading = true
        defer { isSubscriptionLoading = false }
        do {
            try await AppStore.sync()
            await refreshSubscriptionStatus()
            subscriptionMessage = hasActiveSubscription
                ? "購入情報を復元しました。"
                : "有効なサブスクリプションは見つかりませんでした。"
        } catch {
            subscriptionMessage = "購入情報を復元できませんでした。"
        }
    }

    func presentSubscriptionOffer() {
        // 個人用では、無料上限などの共通処理から呼ばれても料金画面を開きません。
        guard AppDistribution.usesSubscriptions else { return }
        showsSubscriptionSheet = true
    }

    /// 初回設定を保存し、メインアルバムだけを利用可能な状態で暗号化領域を作成します。
    func setup(
        passwordEnabled: Bool,
        mainPIN: String,
        initialStorage: StorageLocation = .local
    ) async {
        cancelCredentialRecovery()
        guard iCloudAccountIssue == nil else { return }
        await perform {
            if passwordEnabled {
                try Self.validatePIN(mainPIN)
            }

            for kind in VaultKind.allCases {
                UserDefaults.standard.set(StorageLocation.local.rawValue, forKey: self.storageKey(for: kind))
            }
            UserDefaults.standard.set(false, forKey: InstallationLifecycleService.recoveryPendingKey)
            self.isRecoveringFromICloud = false
            let mainPassword = passwordEnabled ? mainPIN : Self.internalPassword()
            // サブアルバムは内部鍵だけを作り、ユーザー用PINは初期設定後に任意で登録します。
            let subPassword = Self.internalPassword()
            let authentication = self.authentication
            let unlockedVaults = try await Task.detached {
                try authentication.createProfiles(
                    mainPassword: mainPassword,
                    subPassword: subPassword
                )
            }.value

            // 無料の初期状態ではメインアルバムだけを作成し、サブアルバムのDBは有効化時まで作りません。
            for unlocked in unlockedVaults where unlocked.kind == .main {
                let location = self.storageLocation(for: unlocked.kind)
                let repository = try VaultRepository(
                    kind: unlocked.kind,
                    masterKey: unlocked.masterKey,
                    location: location
                )
                _ = try await repository.open()
            }

            self.passwordEnabled = passwordEnabled
            // サブアルバムは初回画面に表示せず、設定から有効化できるよう初期値をオフにします。
            self.subVaultEnabled = false
            self.mainPINConfigured = passwordEnabled
            self.subPINConfigured = false
            self.legacyCredentialMode = false
            self.saveSecurityPreferences()
            // 端末内の作成を先に確定し、iCloudが利用できなくても同じ鍵で継続できます。
            if initialStorage == .iCloud && !LocalRestartState.isActive {
                do {
                    try await Task.detached {
                        try VaultFileStore.migrate(kind: .main, from: .local, to: .iCloud, sourceIsEmpty: true)
                    }.value
                    UserDefaults.standard.set(StorageLocation.iCloud.rawValue, forKey: self.storageKey(for: .main))
                    try await Task.detached { try authentication.publishProfilesToICloud() }.value
                } catch {
                    self.prepareEntryState()
                    if self.storageLocation(for: .main) == .local {
                        self.errorMessage = "iCloud保存に切り替えられなかったため、端末に保存しました。設定から保存先を変更できます。\n\(error.localizedDescription)"
                    } else {
                        self.errorMessage = "iCloudへの保存先変更は完了しましたが、復元用の認証情報を同期できませんでした。\n\(error.localizedDescription)"
                    }
                    return
                }
            }
            self.prepareEntryState()
        }
    }

    /// 再インストール後に、iCloudキーバリューストアまたは同期Keychainから
    /// 既存の認証プロファイルを再取得し、暗号化済みのiCloud保管庫を開く準備をします。
    /// 認証情報が見つからない場合は新しい鍵を作らず、既存データを変更しません。
    func recoverExistingICloudVault() async {
        guard lockState == .needsSetup, !isRecoveringCredentials, !isWorking,
              iCloudAccountIssue == nil else { return }
        let generation = UUID()
        recoveryGeneration = generation
        isRecoveringCredentials = true
        defer { if recoveryGeneration == generation { isRecoveringCredentials = false } }
        let authentication = authentication
        for attempt in 0..<15 {
            do {
                let candidate = try await Task.detached {
                    try authentication.findRecoveryProfiles()
                }.value
                guard recoveryGeneration == generation, lockState == .needsSetup, !isWorking else { return }
                if let candidate {
                    try authentication.acceptRecoveryProfiles(candidate)
                    let defaults = UserDefaults.standard
                    for kind in VaultKind.allCases {
                        defaults.set(StorageLocation.iCloud.rawValue, forKey: "vault.storage.\(kind.rawValue)")
                    }
                    defaults.set(true, forKey: InstallationLifecycleService.recoveryPendingKey)
                    passwordEnabled = true
                    subVaultEnabled = true
                    mainPINConfigured = false
                    subPINConfigured = false
                    legacyCredentialMode = true
                    hasConfirmedRecoveredCredential = false
                    defaults.set(false, forKey: "auth.recovered-credential-confirmed")
                    isRecoveringFromICloud = true
                    lockState = .locked
                    return
                }
                if attempt < 14 { try await Task.sleep(for: .seconds(1)) }
                guard recoveryGeneration == generation else { return }
            } catch {
                guard recoveryGeneration == generation else { return }
                errorMessage = error.localizedDescription
                return
            }
        }
        errorMessage = "復元用の認証情報がまだ取得できません。同じApple AccountでiCloud Driveとパスワードとキーチェーンを有効にし、少し待ってから再試行してください。"
    }

    /// 入力されたPIN（旧版ではパスワード）に一致するアルバムを開きます。
    @Published private(set) var isAutomaticallyCheckingCredential = false

    func unlock(credential: String, automatically: Bool = false) async {
        guard !Task.isCancelled, lockState == .locked, !isWorking else { return }
        isWorking = true
        isAutomaticallyCheckingCredential = automatically
        defer { isWorking = false; isAutomaticallyCheckingCredential = false; refreshPINWaitState() }
        do {
            if !legacyCredentialMode {
                try Self.validatePIN(credential)
            }
            let authenticationService = authentication
            let unlocked = try await Task.detached {
                try authenticationService.unlock(password: credential, automatically: automatically)
            }.value
            try Task.checkCancellation()
            if unlocked.kind == .sub, !canAccessSubVault {
                presentSubscriptionOffer()
                return
            }
            isAutomaticallyCheckingCredential = false
            try await open(unlocked)
            guard !Task.isCancelled, currentVaultKind == unlocked.kind else { return }
            // 照合済みの認証設定を保存し、再起動後も復元用入力へ戻さないようにします。
            if legacyCredentialMode || isRecoveringFromICloud {
                let isPIN = (4...6).contains(credential.count)
                    && credential.allSatisfy { $0.isASCII && $0.wholeNumberValue != nil }
                if unlocked.kind == .main { mainPINConfigured = isPIN }
                else { subPINConfigured = isPIN }
                // 未確認のサブや英数字パスワードも引き続き入力できる形式を維持します。
                legacyCredentialMode = !mainPINConfigured || (subVaultEnabled && !subPINConfigured)
                passwordEnabled = true
                hasConfirmedRecoveredCredential = true
                isRecoveringFromICloud = false
                UserDefaults.standard.set(true, forKey: "auth.recovered-credential-confirmed")
                UserDefaults.standard.removeObject(forKey: InstallationLifecycleService.recoveryPendingKey)
                saveSecurityPreferences()
            }
        } catch PhotoVaultError.invalidPassword {
            // PIN不一致はポップアップにせず、ログイン画面内の表示だけを更新します。
            if !automatically { authenticationFailureCount += 1 }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func unlockAutomatically() async {
        guard lockState == .unlocking else { return }
        await perform {
            let unlocked = try self.authentication.unlockWithDeviceKey(kind: .main)
            try await self.open(unlocked)
        }
    }

    func authenticateWithBiometrics() async {
        await perform {
            try await self.authentication.authenticateBiometrics()
            self.selectionWasBiometric = true

            // 「毎回選択」はサブアルバムを利用できる場合だけ選択画面を表示します。
            // 契約状態などでサブアルバムを開けない場合は、安全にメインアルバムへ戻します。
            switch self.biometricUnlockDestination {
            case .chooseEveryTime where self.canAccessSubVault:
                self.lockState = .choosingVault
            case .sub where self.canAccessSubVault:
                let unlocked = try self.authentication.unlockWithDeviceKey(kind: .sub)
                try await self.open(unlocked)
            case .chooseEveryTime, .main, .sub:
                let unlocked = try self.authentication.unlockWithDeviceKey(kind: .main)
                try await self.open(unlocked)
            }
        }
    }

    func selectVault(_ kind: VaultKind) async {
        guard kind != .sub || canAccessSubVault else {
            presentSubscriptionOffer()
            return
        }
        await perform {
            let unlocked = try self.authentication.unlockWithDeviceKey(kind: kind)
            try await self.open(unlocked)
        }
    }

    func lock() {
        resetLoadingSession()
        ocrIndexingTask?.cancel()
        ocrIndexingTask = nil
        pendingOCRPhotoIDs.removeAll()
        isOCRIndexing = false
        ocrIndexProgress = 0
        imageDataCache.removeAllObjects()
        repository = nil
        sessionMasterKey = nil
        currentVaultKind = nil
        currentVaultStorageBytes = 0
        backgroundedAt = nil
        database = .empty
        prepareEntryState()
    }

    /// バックグラウンド移行時刻を記録し、「すぐ」の場合だけその場で鍵を破棄します。
    func sceneDidEnterBackground() {
        guard lockState == .unlocked else { return }
        backgroundedAt = .now
        if autoLockInterval == .immediately {
            lock()
        }
    }

    /// 復帰時に経過時間を比較し、設定時間を超えていた場合だけロックします。
    func sceneDidBecomeActive() {
        refreshICloudAccount()
        guard iCloudAccountIssue == nil else { return }
        defer {
            if lockState == .unlocked {
                if let repository { Task { await repository.refreshAutomaticBackupSchedule() } }
                retryImageLoading()
                if storageLocation == .iCloud && !canEditVault { retryCloudLoading() }
            }
        }
        guard lockState == .unlocked,
              let seconds = autoLockInterval.seconds,
              let backgroundedAt else {
            self.backgroundedAt = nil
            return
        }
        self.backgroundedAt = nil
        if Date().timeIntervalSince(backgroundedAt) >= seconds {
            lock()
        }
    }

    func setAutoLockInterval(_ interval: AutoLockInterval) {
        autoLockInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: "auth.auto-lock-interval")
    }

    func cancelVaultSelection() {
        selectionWasBiometric = false
        lockState = .locked
    }

    func setPasswordEnabled(_ enabled: Bool) {
        guard !enabled || canEnablePasswordWithoutConfiguration else { return }
        passwordEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "auth.pin-enabled")
    }

    func setSubVaultEnabled(_ enabled: Bool) {
        guard !enabled || hasPremiumAccess else {
            presentSubscriptionOffer()
            return
        }
        guard !enabled || !passwordEnabled || subPINConfigured else { return }
        subVaultEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "vault.sub-enabled")

        // サブアルバムを無効にした後も、存在しない遷移先が残らないようにします。
        if !enabled, biometricUnlockDestination == .sub {
            setBiometricUnlockDestination(.main)
        }
    }

    func configurePINs(mainPIN: String, subPIN: String?) async {
        await perform {
            try Self.validatePIN(mainPIN)
            if let subPIN {
                guard self.hasPremiumAccess else {
                    self.presentSubscriptionOffer()
                    return
                }
                try Self.validatePIN(subPIN)
                guard mainPIN != subPIN else { throw PhotoVaultError.passwordsMustDiffer }
            }

            try self.authentication.setPassword(mainPIN, for: .main)
            self.mainPINConfigured = true
            if let subPIN {
                try self.authentication.setPassword(subPIN, for: .sub)
                self.subPINConfigured = true
                self.subVaultEnabled = true
            }
            self.passwordEnabled = true
            self.legacyCredentialMode = false
            self.saveSecurityPreferences()
        }
    }

    func configureSubPIN(_ pin: String) async {
        guard hasPremiumAccess else {
            presentSubscriptionOffer()
            return
        }
        await perform {
            try Self.validatePIN(pin)
            try self.authentication.setPassword(pin, for: .sub)
            self.subPINConfigured = true
            self.subVaultEnabled = true
            self.saveSecurityPreferences()
        }
    }

    func createFolder(named name: String, parentID: UUID? = nil) async {
        // 小さなDB更新で全画面ローディングを重ねると、シートの閉じるアニメーション中に
        // ツールバーが一時的に操作不能になることがあるため、画面を塞がずに保存します。
        await updateRepositoryWithoutBlockingUI { repository in
            self.database = try await repository.createFolder(named: name, parentID: parentID)
        }
    }

    func renameFolder(id: UUID, to name: String) async {
        await withRepository { repository in
            self.database = try await repository.renameFolder(id: id, to: name)
        }
    }

    /// フォルダカードから選ばれた移動先を保存し、一覧をすぐに再構成します。
    func moveFolder(id: UUID, toParentID parentID: UUID?) async {
        await updateRepositoryWithoutBlockingUI { repository in
            self.database = try await repository.moveFolder(id: id, toParentID: parentID)
        }
    }

    /// 暗号化ファイルをコピーせず、写真の所属フォルダだけを更新します。
    func movePhoto(id: UUID, toFolderID folderID: UUID) async {
        await updateRepositoryWithoutBlockingUI { repository in
            self.database = try await repository.movePhoto(id: id, toFolderID: folderID)
        }
    }

    func deleteFolder(id: UUID) async {
        // 親フォルダ削除時は、配下のサブフォルダにある写真キャッシュもすべて破棄します。
        let folderIDs = database.folderIDs(includingDescendantsOf: id)
        let deletedPhotoIDs = database.photos
            .filter { photo in
                guard let folderID = photo.folderID else { return false }
                return folderIDs.contains(folderID)
            }
            .map(\.id)
        await withRepository { repository in
            self.database = try await repository.deleteFolder(id: id)
        }
        for photoID in deletedPhotoIDs {
            removeCachedImageData(for: photoID)
        }
        await refreshStorageUsage()
    }

    /// 写真ライブラリで選択された画像を順番に暗号化して取り込みます。
    func importPickerItems(_ items: [PhotosPickerItem], into folderID: UUID?) async {
        await importPhotoLibraryItems(items, into: folderID) { item in
            try await ImageImportService.load(item)
        }
    }

    /// iOS標準PhotosPickerから受け取った写真を共通処理で取り込みます。
    ///
    /// 無料上限、重複判定、取り込み後削除、OCR登録の流れを一か所にまとめます。
    private func importPhotoLibraryItems<Item>(
        _ items: [Item],
        into folderID: UUID?,
        loader: (Item) async throws -> ImportedImage
    ) async {
        guard !items.isEmpty, let repository else { return }
        guard canEditVault else {
            errorMessage = PhotoVaultError.iCloudIndexNotReady.localizedDescription
            return
        }
        guard hasPremiumAccess || database.photos.count < Self.freePhotoLimit else {
            presentSubscriptionOffer()
            return
        }
        isWorking = true
        defer { isWorking = false }
        var identifiersToDelete: [String] = []
        var hasMissingDeletionIdentifier = false
        var destinationFolderID = folderID
        var importedCount = 0
        var duplicateCount = 0
        var exceededFreeLimit = false
        var importedPhotoIDs: [UUID] = []

        do {
            for item in items {
                // 無料枠は重複を除いた「実際に保存した枚数」で数えます。
                guard hasPremiumAccess || database.photos.count < Self.freePhotoLimit else {
                    exceededFreeLimit = true
                    break
                }
                let imported = try await loader(item)
                let outcome = try await repository.importImage(imported, into: destinationFolderID)
                switch outcome {
                case .imported(let updatedDatabase, let photo, let resolvedFolderID):
                    database = updatedDatabase
                    destinationFolderID = resolvedFolderID
                    importedCount += 1
                    importedPhotoIDs.append(photo.id)
                    if database.deletesOriginalAfterImport {
                        if let identifier = imported.photoLibraryIdentifier {
                            identifiersToDelete.append(identifier)
                        } else {
                            // 削除対象を特定できない場合も黙って成功扱いにせず、取り込み後に通知します。
                            hasMissingDeletionIdentifier = true
                        }
                    }
                case .duplicate(let updatedDatabase, _):
                    // 同じ元データは追加せず、旧DBへ補完したハッシュだけを画面へ反映します。
                    database = updatedDatabase
                    duplicateCount += 1
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            await refreshStorageUsage()
            enqueueOCRIndexing(photoIDs: importedPhotoIDs)
            return
        }

        // 保存完了後にのみ、設定に応じて元写真の削除確認をシステムへ依頼します。
        if database.deletesOriginalAfterImport {
            do {
                if !identifiersToDelete.isEmpty {
                    if storageLocation == .iCloud {
                        let status = try await repository.cloudStatus()
                        guard status.allowsOriginalDeletion else { throw LocalRestartError.uploadUnconfirmed }
                    }
                    try await PhotoDeletionService.requestDeletion(identifiers: identifiersToDelete)
                }
                if hasMissingDeletionIdentifier {
                    throw PhotoVaultError.photoLibraryAssetNotFound
                }
            } catch {
                errorMessage = "アルバムへの保存は完了しましたが、元写真は削除されませんでした。\n\(error.localizedDescription)"
            }
        }
        if exceededFreeLimit {
            presentSubscriptionOffer()
        } else if duplicateCount > 0, errorMessage == nil {
            errorMessage = duplicateImportMessage(imported: importedCount, skipped: duplicateCount)
        }
        await refreshStorageUsage()
        enqueueOCRIndexing(photoIDs: importedPhotoIDs)
    }

    func importFileURLs(_ urls: [URL], into folderID: UUID?) async {
        guard !urls.isEmpty, let repository else { return }
        guard canEditVault else {
            errorMessage = PhotoVaultError.iCloudIndexNotReady.localizedDescription
            return
        }
        guard hasPremiumAccess || database.photos.count < Self.freePhotoLimit else {
            presentSubscriptionOffer()
            return
        }
        isWorking = true
        defer { isWorking = false }
        var destinationFolderID = folderID
        var importedCount = 0
        var duplicateCount = 0
        var exceededFreeLimit = false
        var importedPhotoIDs: [UUID] = []

        do {
            for url in urls {
                guard hasPremiumAccess || database.photos.count < Self.freePhotoLimit else {
                    exceededFreeLimit = true
                    break
                }
                let imported = try ImageImportService.load(url)
                let outcome = try await repository.importImage(imported, into: destinationFolderID)
                switch outcome {
                case .imported(let updatedDatabase, let photo, let resolvedFolderID):
                    database = updatedDatabase
                    destinationFolderID = resolvedFolderID
                    importedCount += 1
                    importedPhotoIDs.append(photo.id)
                case .duplicate(let updatedDatabase, _):
                    database = updatedDatabase
                    duplicateCount += 1
                }
            }
            if exceededFreeLimit {
                presentSubscriptionOffer()
            } else if duplicateCount > 0, errorMessage == nil {
                errorMessage = duplicateImportMessage(imported: importedCount, skipped: duplicateCount)
            }
            await refreshStorageUsage()
            enqueueOCRIndexing(photoIDs: importedPhotoIDs)
        } catch {
            errorMessage = error.localizedDescription
            await refreshStorageUsage()
            enqueueOCRIndexing(photoIDs: importedPhotoIDs)
        }
    }

    func restoreTrashedPhoto(id: UUID) async {
        guard hasPremiumAccess || database.photos.count < Self.freePhotoLimit else {
            presentSubscriptionOffer()
            return
        }
        await maintainVault { repository in
            try await repository.restoreTrashedPhoto(id: id, photoLimit: self.hasPremiumAccess ? nil : Self.freePhotoLimit)
        }
    }

    func permanentlyDeletePhotos(ids: Set<UUID>) async {
        await maintainVault { try await $0.permanentlyDelete(ids: ids) }
    }

    func purgeExpiredTrash() async {
        guard canEditVault, let repository else { return }
        do {
            let result = try await repository.purgeExpiredTrash()
            guard self.repository === repository else { return }
            database = result
        } catch {
            let latest = await repository.snapshot()
            guard self.repository === repository else { return }
            database = latest
            errorMessage = error.localizedDescription
        }
    }

    private func maintainVault(_ operation: (VaultRepository) async throws -> VaultDatabase) async {
        guard canEditVault, let repository, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await operation(repository)
            guard self.repository === repository else { return }
            database = result
            imageDataCache.removeAllObjects()
            retryImageLoading()
            await refreshStorageUsage()
        } catch {
            let latest = await repository.snapshot()
            guard self.repository === repository else { return }
            database = latest
            errorMessage = error.localizedDescription
        }
    }

    func deletePhoto(id: UUID) async {
        await withRepository { repository in
            self.database = try await repository.deletePhoto(id: id)
        }
        removeCachedImageData(for: id)
        await refreshStorageUsage()
    }

    func setFeaturedPhoto(id: UUID?, folderID: UUID) async {
        await updateRepositoryWithoutBlockingUI { repository in
            self.database = try await repository.setFeaturedPhoto(id: id, folderID: folderID)
        }
    }

    func setAlbumLayout(_ layout: AlbumLayout) async {
        await updateRepositoryWithoutBlockingUI { repository in
            self.database = try await repository.updateSettings(layout: layout)
        }
    }

    func setPhotoSortOrder(_ order: PhotoSortOrder) async {
        await updateRepositoryWithoutBlockingUI { repository in
            self.database = try await repository.updateSettings(photoSortOrder: order)
        }
    }

    /// フォルダ一覧の並び替え設定を現在のアルバムDBへ保存します。
    func setFolderSortOrder(_ order: FolderSortOrder) async {
        await updateRepositoryWithoutBlockingUI { repository in
            self.database = try await repository.updateSettings(folderSortOrder: order)
        }
    }

    func setSlideshowEnabled(_ enabled: Bool) async {
        await updateRepositoryWithoutBlockingUI { repository in
            self.database = try await repository.updateSettings(slideshowEnabled: enabled)
        }
    }

    func setDeletesOriginalAfterImport(_ enabled: Bool) async {
        await updateRepositoryWithoutBlockingUI { repository in
            self.database = try await repository.updateSettings(deletesOriginalAfterImport: enabled)
        }
    }

    @Published private(set) var isCompletelyResetting = false
    @Published private(set) var completeResetMessage: String?

    func completelyResetIncludingICloud() async {
        guard !isWorking, !isCompletelyResetting else { return }
        isWorking = true
        isCompletelyResetting = true
        completeResetMessage = nil
        var deletionStarted = false
        defer {
            if deletionStarted { CompleteVaultReset.end() }
            isWorking = false
            isCompletelyResetting = false
        }
        do {
            let expectedIdentity = try CompleteVaultReset.currentIdentity()
            try await authentication.authorizeCompleteReset()
            cancelCredentialRecovery()
            lock()
            lockState = .locked
            CompleteVaultReset.begin()
            deletionStarted = true
            try await Task.detached { try CompleteVaultReset.erase(expectedIdentity: expectedIdentity) }.value
            if let bundleIdentifier = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            }
            InstallationLifecycleService().resetIdentityForCurrentInstallation()
            iCloudAccountIssue = nil
            isRecoveringFromICloud = false
            errorMessage = nil
            passwordEnabled = true
            subVaultEnabled = false
            mainPINConfigured = false
            subPINConfigured = false
            biometricsEnabled = false
            biometricUnlockDestination = .chooseEveryTime
            autoLockInterval = .immediately
            legacyCredentialMode = false
            selectionWasBiometric = false
            saveSecurityPreferences()
            refreshPINWaitState()
            lockState = .needsSetup
            showsLocalRestartConfirmation = false
            errorMessage = "端末とiCloudのアルバムの削除操作が完了しました。ほかの端末への削除の反映には時間がかかる場合があります。新しく初期設定を行ってください。"
        } catch {
            completeResetMessage = (deletionStarted
                ? "完全初期化を完了できませんでした。途中まで削除された可能性があります。iCloudファイルの削除に失敗した場合は、復元用の鍵を削除せず保持しています。\n"
                : "完全初期化を開始できませんでした。データは変更していません。\n")
                + CloudRestoreDiagnostics.message(for: error)
        }
    }

    /// アプリを削除する前に、両アルバムのDB・写真・認証情報・設定をまとめて消去します。
    func deleteAllApplicationData() async {
        cloudRefreshTask?.cancel()
        cloudRefreshTask = nil
        for request in imageRequests.values { request.task.cancel() }
        imageRequests.removeAll()
        isRefreshingCloud = false
        isWorking = true
        defer { isWorking = false }

        await repository?.cancelAutomaticBackup()
        do {
            // ファイルの削除が失敗した場合に認証鍵だけが失われないよう、DBを先に消去します。
            try await Task.detached {
                try VaultFileStore.removeAllApplicationData()
            }.value
            resetLoadingSession()
            authentication.deleteAllCredentials()
            try PINAttemptLimiter().reset()

            let restartNamespace = LocalRestartState.namespace
            if let bundleIdentifier = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            }
            if let restartNamespace {
                UserDefaults.standard.set(restartNamespace, forKey: LocalRestartState.namespaceKey)
            }

            // UserDefaultsの全消去で失われたインストール識別子を再登録します。
            // これにより、同じインストール内での次回起動を「再インストール」と誤認しません。
            InstallationLifecycleService().resetIdentityForCurrentInstallation()

            repository = nil
            sessionMasterKey = nil
            ocrIndexingTask?.cancel()
            ocrIndexingTask = nil
            pendingOCRPhotoIDs.removeAll()
            isOCRIndexing = false
            ocrIndexProgress = 0
            imageDataCache.removeAllObjects()
            currentVaultKind = nil
            database = .empty
            passwordEnabled = true
            subVaultEnabled = false
            mainPINConfigured = false
            subPINConfigured = false
            biometricsEnabled = false
            biometricUnlockDestination = .chooseEveryTime
            autoLockInterval = .immediately
            currentVaultStorageBytes = 0
            legacyCredentialMode = false
            selectionWasBiometric = false
            lockState = .needsSetup
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func imageData(for photoID: UUID, thumbnail: Bool) async -> Data? {
        try? await loadImageData(for: photoID, thumbnail: thumbnail)
    }

    /// 同じ画像の要求をまとめ、前のアルバムの取得結果を新しい画面へ戻しません。
    func loadImageData(for photoID: UUID, thumbnail: Bool) async throws -> Data {
        try ICloudAccountGuard().validateBoundAccount()
        try Task.checkCancellation()
        guard let repository else { throw CancellationError() }
        let sessionID = vaultSessionID
        let cacheKey = imageCacheKey(photoID: photoID, thumbnail: thumbnail)
        if let cached = imageDataCache.object(forKey: cacheKey) {
            return Data(referencing: cached)
        }
        let request: ImageRequest
        if let pending = imageRequests[cacheKey] {
            request = pending
        } else {
            request = ImageRequest(task: Task {
                try await repository.imageData(for: photoID, thumbnail: thumbnail)
            })
            imageRequests[cacheKey] = request
        }
        defer {
            if imageRequests[cacheKey]?.id == request.id { imageRequests[cacheKey] = nil }
        }
        let data = try await request.task.value
        try ICloudAccountGuard().validateBoundAccount()
        try Task.checkCancellation()
        guard vaultSessionID == sessionID, self.repository === repository,
              database.photos.contains(where: { $0.id == photoID }) else { throw CancellationError() }
        imageDataCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        return data
    }

    /// 選択した共有方式で一時ファイルを作ります。元画質は保存バイト列を一切変更しません。
    func makeTemporaryShareFile(
        for photo: PhotoRecord,
        mode: PhotoShareMode
    ) async -> URL? {
        guard let data = await imageData(for: photo.id, thumbnail: false) else {
            errorMessage = PhotoVaultError.sharePreparationFailed.localizedDescription
            return nil
        }

        do {
            return try await Task.detached(priority: .userInitiated) {
                let outputData: Data
                let outputType: UTType
                switch mode {
                case .original:
                    outputData = data
                    outputType = UTType(photo.contentTypeIdentifier) ?? .data
                case .removingMetadata:
                    let sanitized = try ImagePrivacyService.removingMetadata(
                        from: data,
                        originalType: UTType(photo.contentTypeIdentifier) ?? .image
                    )
                    outputData = sanitized.data
                    outputType = sanitized.contentType
                }

                let filename = Self.safeShareFilename(
                    for: photo,
                    contentType: outputType,
                    marksMetadataRemoval: mode == .removingMetadata
                )
                let fileManager = FileManager.default
                let directory = fileManager.temporaryDirectory
                    .appendingPathComponent("PhotoVaultShare", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(filename, isDirectory: false)
                try outputData.write(to: url, options: [.atomic])
                try (url as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
#if os(iOS)
                // 端末がロックされている間は、復号済みの共有用一時ファイルも保護します。
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: url.path
                )
#endif
                return url
            }.value
        } catch let error as PhotoVaultError {
            errorMessage = error.localizedDescription
            return nil
        } catch {
            errorMessage = PhotoVaultError.sharePreparationFailed.localizedDescription
            return nil
        }
    }

    /// 旧写真の詳細情報を補完し、未解析であればOCR索引も作成します。
    func analyzePhotoIfNeeded(photoID: UUID) async {
        guard canEditVault else { return }
        guard let repository,
              let photo = database.photos.first(where: { $0.id == photoID }),
              photo.ocrText == nil else { return }
        guard let data = await imageData(for: photoID, thumbnail: false) else { return }

        let metadata = ImageMetadataService.read(from: data)
        let text = await ImageOCRService.recognizeText(in: data)
        guard !Task.isCancelled, self.repository === repository else { return }
        do {
            database = try await repository.updateAnalysis(
                photoID: photoID,
                metadata: metadata,
                ocrText: text
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// OCR検索画面から呼び出し、まだ索引のない旧写真を順番に解析します。
    func indexAllPhotosForOCR() {
        enqueueOCRIndexing(photoIDs: database.photos.filter { $0.ocrText == nil }.map(\.id))
    }

    /// 暗号化された現在アルバムの実ディスク使用量を更新します。
    func refreshStorageUsage() async {
        guard let repository else {
            currentVaultStorageBytes = 0
            return
        }
        if storageLocation == .iCloud {
            // 未取得の全ファイルを走査せず、一覧にある元画像の合計を使います。
            currentVaultStorageBytes = database.totalOriginalByteCount
        } else {
            let bytes = try? await repository.storedByteCount()
            guard self.repository === repository else { return }
            currentVaultStorageBytes = bytes ?? database.totalOriginalByteCount
        }
    }

    func automaticBackupStatusText() async -> String {
        guard let repository else { return "アルバムを開いてください" }
        return await repository.automaticBackupStatus
    }

    func refreshAutomaticBackupSchedule() async {
        await repository?.refreshAutomaticBackupSchedule()
    }

    func retainAutomaticBackup() async {
        guard let repository else { return }
        do { try await repository.retainCurrentAutomaticBackup() }
        catch { errorMessage = "完成した自動バックアップを保管できませんでした。保存状況を確認してください。\n" + error.localizedDescription }
    }

    func retainedAutomaticBackups() async throws -> [RetainedBackupSummary] {
        guard let repository else { return [] }
        return try await repository.retainedAutomaticBackups()
    }

    /// 現在のアルバム全体を、指定パスワードで暗号化した可搬バックアップにします。
    func makeEncryptedBackup(password: String, useAutomaticBackup: Bool = false,
                             retainedBackupID: String? = nil) async -> VaultBackupDocument? {
        guard let repository else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let payload = try await (useAutomaticBackup ? repository.automaticBackupPayload(retainedID: retainedBackupID) : repository.backupPayload())
            let data = try await Task.detached(priority: .userInitiated) {
                try VaultBackupCodec.seal(payload, password: password)
            }.value
            return VaultBackupDocument(data: data)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 選択したバックアップを検証し、成功したときだけ現在のアルバム全体を置き換えます。
    @discardableResult
    func restoreEncryptedBackup(from url: URL, password: String) async -> Bool {
        guard canEditVault else {
            errorMessage = PhotoVaultError.iCloudIndexNotReady.localizedDescription
            return false
        }
        guard let repository else { return false }
        isWorking = true
        defer { isWorking = false }
        let previousOCRTask = ocrIndexingTask
        previousOCRTask?.cancel()
        ocrIndexingTask = nil
        pendingOCRPhotoIDs.removeAll()
        isOCRIndexing = false
        ocrIndexProgress = 0
        await previousOCRTask?.value

        do {
            let backupData = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                // セキュリティスコープを閉じた後も復号できるよう、ここでメモリへ読み切ります。
                return try Data(contentsOf: url)
            }.value
            let payload = try await Task.detached(priority: .userInitiated) {
                try VaultBackupCodec.open(backupData, password: password)
            }.value

            guard let currentVaultKind,
                  payload.sourceVaultKind == currentVaultKind else {
                throw PhotoVaultError.invalidBackup
            }
            guard hasPremiumAccess || payload.database.photos.count <= Self.freePhotoLimit else {
                presentSubscriptionOffer()
                return false
            }

            database = try await repository.restoreBackup(payload)
            for request in imageRequests.values { request.task.cancel() }
            imageRequests.removeAll()
            vaultSessionID = UUID()
            retryImageLoading()
            imageDataCache.removeAllObjects()
            await refreshStorageUsage()
            enqueueOCRIndexing(photoIDs: database.photos.filter { $0.ocrText == nil }.map(\.id))
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// システム共有画面を閉じたら、復号済みの一時ファイルをフォルダごと削除します。
    func removeTemporaryShareFile(at url: URL) {
        let directory = url.deletingLastPathComponent()
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// 現在画像の前後を先読みし、スワイプ後の待ち時間を短くします。
    func preloadImageData(for photoIDs: [UUID], thumbnail: Bool) async {
        for photoID in photoIDs {
            guard !Task.isCancelled else { return }
            _ = await imageData(for: photoID, thumbnail: thumbnail)
        }
    }

    func makeArchive(folderID: UUID?) async -> ArchiveDocument? {
        guard let repository else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let entries = try await repository.exportEntries(folderID: folderID)
            return ArchiveDocument(data: try ZipArchive.make(entries: entries))
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func retryVaultLoading() async {
        guard !isWorking else { return }
        if storageLocation == .iCloud {
            retryCloudLoading()
        } else if let kind = currentVaultKind, let key = sessionMasterKey {
            await perform { try await self.open(UnlockedVault(kind: kind, masterKey: key)) }
        }
    }

    func recoverAutomaticBackupToSeparateLocal() async {
        guard !isWorking, !isRefreshingCloud, !hasLoadedVaultIndex,
              let kind = currentVaultKind, let key = sessionMasterKey, let repository else { return }
        let oldLocation = storageLocation(for: kind)
        let sessionID = vaultSessionID
        let recoveryID = UUID()
        do {
            isWorking = true
            defer { isWorking = false }
            let root = try VaultFileStore.recoveryRoot(id: recoveryID)
            do {
                try await repository.recoverAutomaticBackupToLocal(root: root,
                    photoLimit: hasPremiumAccess ? nil : Self.freePhotoLimit)
                try ICloudAccountGuard().validateBoundAccount()
                guard vaultSessionID == sessionID, lockState == .unlocked else { throw CancellationError() }
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
            UserDefaults.standard.set(recoveryID.uuidString, forKey: VaultFileStore.recoveryDirectoryKey(kind))
            UserDefaults.standard.set(StorageLocation.local.rawValue, forKey: storageKey(for: kind))
            if oldLocation == .iCloud {
                UserDefaults.standard.set(true, forKey: "vault.separate-recovery.\(kind.rawValue)")
            }
            try await open(UnlockedVault(kind: kind, masterKey: key))
            isRecoveringFromICloud = false
            UserDefaults.standard.removeObject(forKey: InstallationLifecycleService.recoveryPendingKey)
        } catch {
            errorMessage = "自動バックアップから復元できませんでした。元のアルバムは変更していません。\n" + error.localizedDescription
        }
    }

    /// 復元待ちのiCloudと端末アルバムを別々に保持している状態です。
    var keepsSeparateRecoveryAlbum: Bool {
        guard let kind = currentVaultKind else { return false }
        return UserDefaults.standard.bool(forKey: "vault.separate-recovery.\(kind.rawValue)")
    }

    var canStartLocalRecoveryAlbum: Bool {
        storageLocation == .iCloud && !hasLoadedVaultIndex && !isRefreshingCloud
            && !isWorking && sessionMasterKey != nil && iCloudAccountIssue == nil
    }

    func startLocalRecoveryAlbum() async {
        guard canStartLocalRecoveryAlbum, let kind = currentVaultKind,
              let key = sessionMasterKey else { return }
        let sessionID = vaultSessionID
        await perform {
            // 認証プロファイルと鍵を再作成しないため、以前のiCloudの復号能力も維持します。
            // 既存の端末アルバムがあればopenで読み、空データで置き換えません。
            let local = try VaultRepository(kind: kind, masterKey: key, location: .local)
            _ = try await local.open()
            guard self.vaultSessionID == sessionID, self.lockState == .unlocked else { throw CancellationError() }
            try ICloudAccountGuard().validateBoundAccount()
            UserDefaults.standard.set(true, forKey: "vault.separate-recovery.\(kind.rawValue)")
            UserDefaults.standard.set(StorageLocation.local.rawValue, forKey: self.storageKey(for: kind))
            try await self.open(UnlockedVault(kind: kind, masterKey: key))
            self.isRecoveringFromICloud = false
            UserDefaults.standard.removeObject(forKey: InstallationLifecycleService.recoveryPendingKey)
        }
    }

    /// 現在のアルバムを端末内部とiCloudの間で安全に移行します。
    func changeStorage(to newLocation: StorageLocation) async {
        if newLocation == .iCloud && LocalRestartState.isActive {
            errorMessage = LocalRestartError.localOnly.localizedDescription
            return
        }
        guard !isWorking, let kind = currentVaultKind,
              let masterKey = sessionMasterKey,
              newLocation != storageLocation else { return }
        if keepsSeparateRecoveryAlbum {
            await perform {
                // 移行せず切り替える。片方の写真で他方を上書き・削除しません。
                UserDefaults.standard.set(newLocation.rawValue, forKey: self.storageKey(for: kind))
                do { try await self.open(UnlockedVault(kind: kind, masterKey: masterKey)) }
                catch {
                    UserDefaults.standard.set((newLocation == .local ? StorageLocation.iCloud : .local).rawValue,
                                              forKey: self.storageKey(for: kind))
                    throw error
                }
            }
            return
        }
        guard canEditVault else {
            errorMessage = PhotoVaultError.iCloudIndexNotReady.localizedDescription
            return
        }
        await perform {
            let oldLocation = self.storageLocation(for: kind)
            let sourceIsEmpty = self.database.allStoredPhotos.isEmpty && self.database.folders.isEmpty
            try await Task.detached {
                try VaultFileStore.migrate(
                    kind: kind,
                    from: oldLocation,
                    to: newLocation,
                    sourceIsEmpty: sourceIsEmpty
                )
            }.value
            UserDefaults.standard.set(newLocation.rawValue, forKey: self.storageKey(for: kind))
            try await self.open(UnlockedVault(kind: kind, masterKey: masterKey))
            if newLocation == .iCloud {
                let authentication = self.authentication
                try await Task.detached { try authentication.publishProfilesToICloud() }.value
            }
            self.objectWillChange.send()
        }
    }

    func setTheme(_ newTheme: AppTheme) {
        theme = newTheme
        UserDefaults.standard.set(newTheme.rawValue, forKey: "app.theme")
    }

    func setBiometricsEnabled(_ enabled: Bool) {
        biometricsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "auth.biometrics-enabled")
    }

    /// 生体認証後の遷移先を保存し、次回の認証から反映します。
    func setBiometricUnlockDestination(_ destination: BiometricUnlockDestination) {
        guard destination != .sub || canAccessSubVault else { return }
        biometricUnlockDestination = destination
        UserDefaults.standard.set(destination.rawValue, forKey: "auth.biometric-destination")
    }

    func setIconStyle(_ style: AppIconStyle) async {
        do {
            guard UIApplication.shared.supportsAlternateIcons else { return }
            try await UIApplication.shared.setAlternateIconName(style.alternateIconName)
            iconStyle = style
            UserDefaults.standard.set(style.rawValue, forKey: "app.icon")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 現在の設定から、次回ロック解除時に表示する認証画面を決定します。
    private func prepareEntryState() {
        selectionWasBiometric = false
        if passwordEnabled || biometricsEnabled {
            lockState = .locked
        } else if canAccessSubVault {
            lockState = .choosingVault
        } else {
            lockState = .unlocking
        }
    }

    /// 復号済みマスター鍵を使って対象アルバムの管理DBを開きます。
    private func open(_ unlocked: UnlockedVault) async throws {
        try ICloudAccountGuard().validateBoundAccount()
        resetLoadingSession()
        self.repository = nil
        ocrIndexingTask?.cancel()
        ocrIndexingTask = nil
        pendingOCRPhotoIDs.removeAll()
        let sessionID = vaultSessionID
        imageDataCache.removeAllObjects()
        let location = storageLocation(for: unlocked.kind)
        let repository = try VaultRepository(
            kind: unlocked.kind,
            masterKey: unlocked.masterKey,
            location: location
        )
        // iCloudでは先に操作可能な画面を出し、キャッシュを含む取得全体を監視します。
        let openedDatabase: VaultDatabase
        let loaded: Bool
        var localReadError: String?
        if location == .iCloud {
            openedDatabase = .empty
            loaded = false
        } else {
            do {
                openedDatabase = try await repository.open()
                loaded = await repository.hasLoadedDatabase
            } catch PhotoVaultError.databaseCorrupted {
                openedDatabase = .empty
                loaded = false
                localReadError = "管理データを読み取れませんでした。元のデータは変更していません。自動バックアップから別の端末アルバムへ復元できます。"
            }
        }
        try ICloudAccountGuard().validateBoundAccount()
        try Task.checkCancellation()
        guard vaultSessionID == sessionID else { throw CancellationError() }
        database = openedDatabase
        self.repository = repository
        sessionMasterKey = unlocked.masterKey
        currentVaultKind = unlocked.kind
        currentVaultStorageBytes = database.totalOriginalByteCount
        hasLoadedVaultIndex = loaded
        canEditVault = location == .local && loaded
        cloudLoadMessage = localReadError
        selectionWasBiometric = false
        lockState = .unlocked
        if location == .local && loaded { await purgeExpiredTrash() }
        if location == .iCloud {
            startCloudIndexObservation()
            retryCloudLoading()
        }
    }

    private func resetLoadingSession() {
        if let repository { Task { await repository.cancelAutomaticBackup() } }
        vaultSessionID = UUID()
        cloudLoadRequestID = UUID()
        cloudLoadWatchdog?.cancel()
        cloudLoadWatchdog = nil
        cloudLoadStage = ""
        cloudRefreshTask?.cancel()
        cloudRefreshTask = nil
        cloudMetadataQuery?.stop()
        cloudMetadataQuery = nil
        for observer in cloudMetadataObservers { NotificationCenter.default.removeObserver(observer) }
        cloudMetadataObservers.removeAll()
        for request in imageRequests.values { request.task.cancel() }
        imageRequests.removeAll()
        isRefreshingCloud = false
        cloudLoadMessage = nil
        hasLoadedVaultIndex = false
        canEditVault = false
        imageReloadToken = UUID()
    }

    func retryImageLoading() {
        imageReloadToken = UUID()
    }

    /// ファイル本体より先に届くiCloudの一覧メタデータを監視します。
    /// 未取得状態で一度タイムアウトしても、ファイルの到着通知で読み込みを再開できます。
    private func startCloudIndexObservation() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, "vault-index.pvdb")
        query.notificationBatchingInterval = 1
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.lockState == .unlocked, !self.canEditVault, self.cloudLoadMessage == nil else { return }
                    self.retryCloudLoading()
                }
            }
            cloudMetadataObservers.append(observer)
        }
        cloudMetadataQuery = query
        _ = query.start()
    }

    /// 一覧は維持し、初回取得だけを裏で再試行します。失敗時も空DBで置き換えません。
    func cancelCloudLoading() {
        cloudLoadRequestID = UUID()
        cloudRefreshTask?.cancel()
        cloudRefreshTask = nil
        cloudLoadWatchdog?.cancel()
        cloudLoadWatchdog = nil
        isRefreshingCloud = false
        cloudLoadMessage = "読み込みを中止しました。既存の写真は変更していません。再読み込みできます。"
    }

    func retryCloudLoading() {
        guard storageLocation == .iCloud, !canEditVault, let repository, cloudRefreshTask == nil else { return }
        let sessionID = vaultSessionID
        let requestID = UUID()
        cloudLoadRequestID = requestID
        isRefreshingCloud = true
        cloudLoadMessage = nil
        cloudLoadStage = "端末内の保存済み一覧を確認中"
        cloudLoadWatchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.cloudLoadRequestID == requestID else { return }
            let stage = self.cloudLoadStage
            self.cancelCloudLoading()
            self.cloudLoadMessage = "[PV-RESTORE-TIMEOUT] \(stage)のまま30秒が経過したため、読み込みを終了しました。再読み込みするか、このエラー内容をコピーしてお問い合わせください。既存の写真は変更していません。"
        }
        cloudRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.cloudLoadRequestID == requestID {
                    self.cloudLoadWatchdog?.cancel()
                    self.cloudLoadWatchdog = nil
                    self.isRefreshingCloud = false
                    self.cloudRefreshTask = nil
                }
            }
            do {
                if !self.hasLoadedVaultIndex {
                    let cached = try await repository.open()
                    let loaded = await repository.hasLoadedDatabase
                    try Task.checkCancellation()
                    guard self.cloudLoadRequestID == requestID else { return }
                    if loaded {
                        self.database = cached
                        self.hasLoadedVaultIndex = true
                    }
                }
                self.cloudLoadStage = "iCloudの管理データを取得・確認中"
                let refreshed = try await repository.refreshFromCloud()
                let writable = await repository.canWrite
                try Task.checkCancellation()
                guard self.cloudLoadRequestID == requestID, self.vaultSessionID == sessionID,
                      self.repository === repository else { return }
                self.database = refreshed
                self.hasLoadedVaultIndex = true
                self.canEditVault = writable
                self.cloudLoadMessage = writable ? nil : "ダウンロード済みの一覧を表示しています。最新版の確認が終わるまで追加・編集はできません。しばらくして再試行してください。"
                self.currentVaultStorageBytes = refreshed.totalOriginalByteCount
                self.isRecoveringFromICloud = false
                UserDefaults.standard.removeObject(forKey: InstallationLifecycleService.recoveryPendingKey)
                self.retryImageLoading()
                // 復元成功の表示を、期限切れゴミ箱の削除待ちに引きずられないようにします。
                self.cloudLoadWatchdog?.cancel()
                self.cloudLoadWatchdog = nil
                self.isRefreshingCloud = false
                if writable { Task { [weak self] in await self?.purgeExpiredTrash() } }
            } catch is CancellationError { }
            catch {
                guard self.cloudLoadRequestID == requestID, self.vaultSessionID == sessionID,
                      self.repository === repository else { return }
                self.cloudLoadMessage = CloudRestoreDiagnostics.message(for: error)
            }
        }
    }

    private func withRepository(_ operation: (VaultRepository) async throws -> Void) async {
        guard canEditVault else {
            errorMessage = PhotoVaultError.iCloudIndexNotReady.localizedDescription
            return
        }
        guard let repository else { return }
        await perform {
            try await operation(repository)
        }
    }

    /// 軽量な設定保存では全画面ローディングを出さず、操作アニメーションを止めません。
    private func updateRepositoryWithoutBlockingUI(
        _ operation: (VaultRepository) async throws -> Void
    ) async {
        guard canEditVault else {
            errorMessage = PhotoVaultError.iCloudIndexNotReady.localizedDescription
            return
        }
        guard let repository else { return }
        do {
            try await operation(repository)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func imageCacheKey(photoID: UUID, thumbnail: Bool) -> NSString {
        "\(photoID.uuidString)-\(thumbnail ? "thumbnail" : "full")" as NSString
    }

    private func removeCachedImageData(for photoID: UUID) {
        imageDataCache.removeObject(forKey: imageCacheKey(photoID: photoID, thumbnail: true))
        imageDataCache.removeObject(forKey: imageCacheKey(photoID: photoID, thumbnail: false))
    }

    /// OCR要求を1本のキューへまとめ、複数の取り込みや検索開始が重なっても同じ画像を並列解析しません。
    private func enqueueOCRIndexing(photoIDs: [UUID]) {
        guard canEditVault else { return }
        pendingOCRPhotoIDs.formUnion(photoIDs)
        guard !pendingOCRPhotoIDs.isEmpty, ocrIndexingTask == nil else { return }
        ocrIndexingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.processOCRQueue()
        }
    }

    private func processOCRQueue() async {
        let sessionID = vaultSessionID
        isOCRIndexing = true
        ocrIndexProgress = 0
        var completedCount = 0

        while let photoID = pendingOCRPhotoIDs.first {
            guard !Task.isCancelled, let repository else { break }
            pendingOCRPhotoIDs.remove(photoID)

            if let current = database.photos.first(where: { $0.id == photoID }),
               current.ocrText == nil,
               let data = await imageData(for: photoID, thumbnail: false) {
                let metadata = ImageMetadataService.read(from: data)
                let text = await ImageOCRService.recognizeText(in: data)
                guard !Task.isCancelled, self.repository === repository else { break }
                do {
                    database = try await repository.updateAnalysis(
                        photoID: photoID,
                        metadata: metadata,
                        ocrText: text
                    )
                } catch {
                    errorMessage = error.localizedDescription
                    break
                }
            }

            completedCount += 1
            let total = completedCount + pendingOCRPhotoIDs.count
            ocrIndexProgress = total == 0 ? 1 : Double(completedCount) / Double(total)
            await Task.yield()
        }

        guard vaultSessionID == sessionID else { return }
        isOCRIndexing = false
        ocrIndexProgress = pendingOCRPhotoIDs.isEmpty ? 1 : 0
        await refreshStorageUsage()
        ocrIndexingTask = nil
        // 処理終了直前に追加された要求が残っていれば、新しいタスクとして継続します。
        if !Task.isCancelled && !pendingOCRPhotoIDs.isEmpty {
            enqueueOCRIndexing(photoIDs: [])
        }
    }

    /// 共通の処理中表示とエラー通知を付けて非同期処理を実行します。
    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveSecurityPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(legacyCredentialMode, forKey: "auth.legacy-credential-mode")
        defaults.set(passwordEnabled, forKey: "auth.pin-enabled")
        defaults.set(subVaultEnabled, forKey: "vault.sub-enabled")
        defaults.set(mainPINConfigured, forKey: "auth.main-pin-configured")
        defaults.set(subPINConfigured, forKey: "auth.sub-pin-configured")
        defaults.set(2, forKey: "auth.credential-format")
    }

    private func storageLocation(for kind: VaultKind) -> StorageLocation {
        let raw = UserDefaults.standard.string(forKey: storageKey(for: kind))
        return StorageLocation(rawValue: raw ?? "") ?? .local
    }

    private func storageKey(for kind: VaultKind) -> String {
        "vault.storage.\(kind.rawValue)"
    }

    /// 重複を省いた結果を、取り込み完了後に分かりやすく通知します。
    private func duplicateImportMessage(imported: Int, skipped: Int) -> String {
        if imported == 0 {
            return "選択した写真はすでに保存済みです。重複して追加しませんでした。"
        }
        return "\(imported)枚を追加しました。保存済みの\(skipped)枚は重複して追加しませんでした。"
    }

    /// 共有先で扱いやすい安全な名前へ整え、拡張子がなければ元形式から補います。
    private nonisolated static func safeShareFilename(
        for photo: PhotoRecord,
        contentType: UTType,
        marksMetadataRemoval: Bool
    ) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:\n\r\0")
        var filename = photo.displayFilename
            .components(separatedBy: invalidCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if filename.isEmpty {
            filename = "photo"
        }
        let url = URL(fileURLWithPath: filename)
        var stem = url.deletingPathExtension().lastPathComponent
        if stem.isEmpty { stem = "photo" }
        if marksMetadataRemoval {
            stem += "-privacy"
        }
        let fileExtension = contentType.preferredFilenameExtension
            ?? (filename as NSString).pathExtension
        return fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
    }

    private static func removeStaleShareFiles() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoVaultShare", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// PINが半角数字4〜6桁であることを確認します。
    private static func validatePIN(_ pin: String) throws {
        guard (4...6).contains(pin.count),
              pin.allSatisfy({ $0.isASCII && $0.wholeNumberValue != nil }) else {
            throw PhotoVaultError.passwordTooShort
        }
    }

    private static func internalPassword() -> String {
        UUID().uuidString + UUID().uuidString
    }

}
