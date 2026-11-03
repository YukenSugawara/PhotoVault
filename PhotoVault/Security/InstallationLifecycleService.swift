import Foundation

/// アプリ専用コンテナとKeychainの識別子を比較し、再インストールを安全に検知します。
///
/// iOS／iPadOSでは、アプリを削除すると端末内コンテナとUserDefaultsは消えますが、
/// KeychainやiCloud上の暗号化データは残る場合があります。
/// 再インストール時は残存データを消去せず、既存の認証情報とiCloud保管庫を復元対象にします。
struct InstallationLifecycleService {
    /// AppModelと画面側が「iCloudからの復元中」を判定するための共通キーです。
    static let recoveryPendingKey = "installation.icloud-recovery-pending-v1"

    private let keychain = KeychainStore()
    private let authentication = AuthenticationService()

    private let keychainAccount = "installation-identity-v1"
    private let defaultsIdentityKey = "installation.identity-v1"
    /// 旧版が残した自動消去予約を無効化するため、キー名だけ維持します。
    private let legacyPendingCleanupKey = "installation.residual-cleanup-pending-v1"

    /// AppModelが設定や認証情報を読み込む前に、一度だけ呼び出します。
    func prepareForLaunch() {
        let defaults = UserDefaults.standard
        if LocalRestartState.isActive {
            for kind in VaultKind.allCases {
                defaults.set(StorageLocation.local.rawValue, forKey: "vault.storage.\(kind.rawValue)")
            }
            defaults.removeObject(forKey: Self.recoveryPendingKey)
            return
        }
        let keychainIdentity = try? keychain.read(
            account: keychainAccount,
            synchronizable: false
        )
        let containerIdentity = defaults.data(forKey: defaultsIdentityKey)

        // 旧版で消去再試行が予約されていても、この版ではiCloudデータを削除しません。
        defaults.removeObject(forKey: legacyPendingCleanupKey)

        switch (keychainIdentity, containerIdentity) {
        case (nil, nil):
            // 完全な新規インストールと、新しい端末での復元開始の両方が該当します。
            // 同期済み認証プロファイルが見つかる場合だけ、iCloud復元を優先します。
            if authentication.hasLocalProfiles {
                configureICloudRecovery(defaults: defaults)
            }
            registerNewInstallationIdentity(defaults: defaults)

        case let (keychainIdentity?, containerIdentity?) where keychainIdentity == containerIdentity:
            // 両方が一致する場合は通常起動またはアプリ更新です。
            break

        case let (keychainIdentity?, _):
            // Keychain側だけ残っている場合は、同じ端末への再インストールです。
            // 識別子・認証情報・iCloudデータを維持して復元へ進みます。
            defaults.set(keychainIdentity, forKey: defaultsIdentityKey)
            configureICloudRecovery(defaults: defaults)

        case (nil, _?):
            // Keychain識別子だけが消えていても、暗号化データは削除しません。
            if authentication.hasLocalProfiles {
                configureICloudRecovery(defaults: defaults)
            }
            registerNewInstallationIdentity(defaults: defaults)
        }
    }

    /// ユーザーが設定画面から「全データを消去」を実行した後、現在のインストールを登録し直します。
    func resetIdentityForCurrentInstallation() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: legacyPendingCleanupKey)
        defaults.removeObject(forKey: Self.recoveryPendingKey)
        registerNewInstallationIdentity(defaults: defaults)
    }

    /// 再インストールで失われた保存先設定をiCloudへ戻します。
    /// 既に値がある通常アップデートでは、ユーザーの設定を変更しません。
    private func configureICloudRecovery(defaults: UserDefaults) {
        for kind in VaultKind.allCases {
            let key = "vault.storage.\(kind.rawValue)"
            if defaults.object(forKey: key) == nil {
                defaults.set(StorageLocation.iCloud.rawValue, forKey: key)
            }
        }
        defaults.set(true, forKey: Self.recoveryPendingKey)
    }

    /// 同じランダム値をアプリ領域と端末専用Keychainへ保存します。
    private func registerNewInstallationIdentity(defaults: UserDefaults) {
        let identity = Data(UUID().uuidString.utf8)
        do {
            try keychain.save(identity, account: keychainAccount, synchronizable: false)
            defaults.set(identity, forKey: defaultsIdentityKey)
        } catch {
            // Keychainへ保存できない場合は片側だけを残さず、次回起動時に改めて登録します。
            defaults.removeObject(forKey: defaultsIdentityKey)
        }
    }
}
