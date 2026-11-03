import Foundation
import LocalAuthentication

/// 認証成功後にだけ生成される、対象アルバムと復号用マスター鍵の組です。
struct UnlockedVault: Sendable {
    let kind: VaultKind
    let masterKey: Data
}

/// PIN照合、生体認証、Keychain上の鍵管理を担当します。
struct AuthenticationService {
    private let keychain = KeychainStore()
    private var localProfilesAccount: String { LocalRestartState.account("vault-profiles-local-v1") }
    private let synchronizedProfilesAccount = "vault-profiles-v1"
    private let ubiquitousProfilesKey = "PhotoVault.vault-profiles-v1"

    /// 起動時は端末内だけを確認し、iCloudの同期・ネットワークを待ちません。
    var hasLocalProfiles: Bool {
        (try? keychain.read(account: localProfilesAccount, synchronizable: false)) != nil
    }

    var hasProfiles: Bool { hasLocalProfiles }

    /// 復元を選んだ場合だけバックグラウンドで呼びます。端末の鍵はまだ変更しません。
    func findRecoveryProfiles() throws -> Data? {
        try LocalRestartState.requireCloudAccess()
        try ICloudAccountGuard().validateBoundAccount()
        if let data = try keychain.read(account: localProfilesAccount, synchronizable: false) { return data }
        if let data = try keychain.read(account: synchronizedProfilesAccount, synchronizable: true) {
            try ICloudAccountGuard().validateBoundAccount()
            _ = try JSONDecoder().decode([VaultProfile].self, from: data)
            return data
        }
        #if !DEBUG
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()
        if let data = store.data(forKey: ubiquitousProfilesKey) {
            try ICloudAccountGuard().validateBoundAccount()
            _ = try JSONDecoder().decode([VaultProfile].self, from: data)
            return data
        }
        #endif
        return nil
    }

    /// キャンセル・別操作開始の確認後にだけ呼び、遅れて届いた結果で鍵を上書きしません。
    func acceptRecoveryProfiles(_ data: Data) throws {
        try LocalRestartState.requireCloudAccess()
        try ICloudAccountGuard().validateBoundAccount()
        let profiles = try JSONDecoder().decode([VaultProfile].self, from: data)
        guard !profiles.isEmpty, Set(profiles.map(\.kind)).count == profiles.count else {
            throw PhotoVaultError.credentialsMissing
        }
        try keychain.save(data, account: localProfilesAccount, synchronizable: false)
    }

    func publishProfilesToICloud() throws {
        try LocalRestartState.requireCloudAccess()
        try ICloudAccountGuard().validateBoundAccount()
        let encoded = try profilesData()
        try keychain.save(encoded, account: synchronizedProfilesAccount, synchronizable: true)
        #if !DEBUG
        NSUbiquitousKeyValueStore.default.set(encoded, forKey: ubiquitousProfilesKey)
        NSUbiquitousKeyValueStore.default.synchronize()
        #endif
    }

    /// 初回設定用に2つの独立したマスター鍵と認証プロファイルを作成します。
    func createProfiles(mainPassword: String, subPassword: String) throws -> [UnlockedVault] {
        guard !mainPassword.isEmpty, !subPassword.isEmpty else {
            throw PhotoVaultError.passwordTooShort
        }
        guard mainPassword != subPassword else {
            throw PhotoVaultError.passwordsMustDiffer
        }

        let main = try makeProfile(kind: .main, password: mainPassword)
        let sub = try makeProfile(kind: .sub, password: subPassword)
        // 初回作成は端末内に限定し、まだ確認していない既存iCloudの鍵を上書きしません。
        try saveProfiles([main.profile, sub.profile], syncToCloud: false)

        try saveDeviceKey(main.masterKey, for: .main)
        try saveDeviceKey(sub.masterKey, for: .sub)
        return [
            UnlockedVault(kind: .main, masterKey: main.masterKey),
            UnlockedVault(kind: .sub, masterKey: sub.masterKey)
        ]
    }

    /// 入力値を各プロファイルと照合し、一致したアルバムの鍵だけを復号します。
    func unlock(password: String, automatically: Bool = false, forAccountRecovery: Bool = false) throws -> UnlockedVault {
        let profiles: [VaultProfile]
        if forAccountRecovery {
            // 再接続の証明に使う鍵だけを取り出します。同期鍵の取得・公開はしません。
            guard let data = try keychain.read(account: localProfilesAccount, synchronizable: false) else {
                throw PhotoVaultError.credentialsMissing
            }
            profiles = try JSONDecoder().decode([VaultProfile].self, from: data)
        } else {
            profiles = try loadProfiles()
        }
        if automatically {
            try PINAttemptLimiter().beginAutomaticCheck()
        } else {
            try PINAttemptLimiter().beginAttempt()
        }
        for profile in profiles {
            let derived = try KeyDerivation.deriveKey(password: password, salt: profile.salt)
            let verifier = KeyDerivation.verifier(for: derived)
            guard KeyDerivation.securelyMatches(verifier, profile.passwordVerifier) else {
                continue
            }
            let masterKey = try CryptoBox.open(profile.wrappedMasterKey, using: derived)
            if !forAccountRecovery { try saveDeviceKey(masterKey, for: profile.kind) }
            try PINAttemptLimiter().reset()
            return UnlockedVault(kind: profile.kind, masterKey: masterKey)
        }
        throw PhotoVaultError.invalidPassword
    }

    /// LocalAuthenticationを使ってFace ID／Touch IDの本人確認を行います。
    func authenticateBiometrics() async throws {
        let context = LAContext()
        context.localizedCancelTitle = "キャンセル"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw PhotoVaultError.biometricUnavailable
        }
        let reason = "写真を開くために本人確認を行います。"
        let succeeded = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )
        guard succeeded else { throw PhotoVaultError.biometricUnavailable }
        try PINAttemptLimiter().reset()
    }

    func unlockWithDeviceKey(kind: VaultKind) throws -> UnlockedVault {
        try ICloudAccountGuard().validateBoundAccount()
        guard let key = try keychain.read(account: deviceKeyAccount(kind), synchronizable: false) else {
            throw PhotoVaultError.biometricKeyMissing
        }
        return UnlockedVault(kind: kind, masterKey: key)
    }

    /// マスター鍵は変更せず、PINで包む部分だけを新しい値へ更新します。
    func setPassword(_ password: String, for kind: VaultKind) throws {
        guard !password.isEmpty else { throw PhotoVaultError.passwordTooShort }
        var profiles = try loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.kind == kind }) else {
            throw PhotoVaultError.credentialsMissing
        }

        for profile in profiles where profile.kind != kind {
            let derived = try KeyDerivation.deriveKey(password: password, salt: profile.salt)
            let verifier = KeyDerivation.verifier(for: derived)
            if KeyDerivation.securelyMatches(verifier, profile.passwordVerifier) {
                throw PhotoVaultError.passwordsMustDiffer
            }
        }

        let unlocked = try unlockWithDeviceKey(kind: kind)
        profiles[index] = try makeProfile(
            kind: kind,
            password: password,
            masterKey: unlocked.masterKey
        )
        try saveProfiles(profiles)
    }

    func availableBiometryName() -> String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "生体認証"
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "生体認証"
        }
    }

    /// 端末にFace IDまたはTouch IDが登録され、現在利用できるかを返します。
    func biometricsAreAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func authorizeCompleteReset() async throws {
        let context = LAContext()
        let authorized = try await context.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: "iCloudを含むアルバムの完全初期化を確認します")
        guard authorized else { throw LAError(.authenticationFailed) }
    }

    /// 設定画面から全データ消去を実行した時に、2つの認証プロファイルと端末専用鍵を削除します。
    func deleteAllCredentials() {
        keychain.delete(account: localProfilesAccount)
        if !LocalRestartState.isActive { keychain.delete(account: synchronizedProfilesAccount) }
        for kind in VaultKind.allCases {
            keychain.delete(account: deviceKeyAccount(kind))
        }
        if !LocalRestartState.isActive {
            NSUbiquitousKeyValueStore.default.removeObject(forKey: ubiquitousProfilesKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    private func loadProfiles() throws -> [VaultProfile] {
        let data = try profilesData()
        return try JSONDecoder().decode([VaultProfile].self, from: data)
    }

    private func profilesData() throws -> Data {
        try ICloudAccountGuard().validateBoundAccount()
        guard let data = try keychain.read(account: localProfilesAccount, synchronizable: false) else {
            throw PhotoVaultError.credentialsMissing
        }
        return data
    }

    private func saveProfiles(_ profiles: [VaultProfile], syncToCloud: Bool? = nil) throws {
        try ICloudAccountGuard().validateBoundAccount()
        let encoded = try JSONEncoder().encode(profiles)
        try keychain.save(encoded, account: localProfilesAccount, synchronizable: false)
        let usesCloud = syncToCloud ?? VaultKind.allCases.contains {
            UserDefaults.standard.string(forKey: "vault.storage.\($0.rawValue)") == StorageLocation.iCloud.rawValue
        }
        if usesCloud { try publishProfilesToICloud() }
    }

    private func makeProfile(kind: VaultKind, password: String) throws -> (profile: VaultProfile, masterKey: Data) {
        let masterKey = try CryptoBox.randomData(count: 32)
        let profile = try makeProfile(kind: kind, password: password, masterKey: masterKey)
        return (profile, masterKey)
    }

    private func makeProfile(kind: VaultKind, password: String, masterKey: Data) throws -> VaultProfile {
        let salt = try CryptoBox.randomData(count: 16)
        let derived = try KeyDerivation.deriveKey(password: password, salt: salt)
        return VaultProfile(
            kind: kind,
            salt: salt,
            passwordVerifier: KeyDerivation.verifier(for: derived),
            wrappedMasterKey: try CryptoBox.seal(masterKey, using: derived),
            createdAt: .now
        )
    }

    private func saveDeviceKey(_ key: Data, for kind: VaultKind) throws {
        try keychain.save(key, account: deviceKeyAccount(kind), synchronizable: false)
    }

    private func deviceKeyAccount(_ kind: VaultKind) -> String {
        LocalRestartState.account("device-master-key-\(kind.rawValue)-v1")
    }
}
