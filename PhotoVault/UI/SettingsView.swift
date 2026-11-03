import Foundation
import StoreKit
import SwiftUI

/// 保存場所、ロック、表示、テーマなどを変更する設定画面です。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var advertising: AdvertisingService
    @Environment(\.requestReview) private var requestReview
    @State private var showsFullDataDeletion = false

    var body: some View {
        Form {
            // 個人用ではすべての機能が常時有効なため、料金案内を表示しません。
            if AppDistribution.usesSubscriptions {
                Section {
                    premiumOverviewCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                Picker("写真と管理データ", selection: storageBinding) {
                    ForEach(StorageLocation.allCases) { location in
                        Label(location.displayName, systemImage: location.symbolName)
                            .tag(location)
                            .disabled(location == .iCloud && !model.isICloudAvailableInThisBuild)
                    }
                }
            } header: {
                SettingsSectionHeader("保存場所", systemImage: "externaldrive.fill")
            } footer: {
#if DEBUG
                Label("デバッグ版ではiCloudを無効にしています。Release版で利用できます。", systemImage: "hammer.fill")
                    .font(.footnote)
#else
                Text(model.isLocalRestartMode ? LocalRestartError.localOnly.localizedDescription : model.keepsSeparateRecoveryAlbum ? "端末内と以前のiCloudアルバムを切り替えます。写真は別々に保持され、自動で統合・同期されません。" : "変更すると、暗号化された写真と管理データを新しい保存場所へ安全に移行します。")
#endif
            }

            Section {
                Toggle("取り込み後に元写真を削除", isOn: deleteOriginalBinding)
            } header: {
                SettingsSectionHeader("写真の取り込み", systemImage: "square.and.arrow.down.fill")
            } footer: {
                Text("写真ライブラリからの取り込みだけが対象です。保存成功後にApple標準の削除確認が表示されます。ファイルから選んだ元画像は削除しません。")
            }

            Section {
                Picker("一覧の表示形式", selection: layoutBinding) {
                    ForEach(AlbumLayout.allCases) { layout in
                        Label(layout.displayName, systemImage: layout.symbolName)
                            .tag(layout)
                    }
                }

                Picker("写真の並び替え", selection: sortOrderBinding) {
                    ForEach(PhotoSortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }

                Picker("フォルダの並び替え", selection: folderSortOrderBinding) {
                    ForEach(FolderSortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }

                Toggle("スライドショーを使用", isOn: slideshowBinding)
            } header: {
                SettingsSectionHeader("表示と並び替え", systemImage: "rectangle.grid.2x2.fill")
            } footer: {
                Text("写真は追加日時または元ファイル名、フォルダは作成日時または名前で並べ替えます。フォルダ画像は、フォルダ内の写真を長押しして設定できます。")
            }

            Section {
                NavigationLink {
                    SecuritySettingsView()
                } label: {
                    SettingsNavigationRow(
                        title: "セキュリティ設定",
                        subtitle: securitySummary,
                        systemImage: "lock.shield.fill",
                        tint: model.theme.tint
                    )
                }
            } header: {
                SettingsSectionHeader("セキュリティ", systemImage: "lock.shield.fill")
            } footer: {
                Text("数字PIN、生体認証、認証後に開くアルバム、サブアルバムの設定をまとめています。PINは5回連続失敗すると30秒待機し、以後の失敗で最大5分まで延長します。写真の自動消去は行いません。")
            }

            Section {
                Picker("背景テーマ", selection: themeBinding) {
                    ForEach(AppTheme.allCases) { theme in
                        HStack {
                            Circle().fill(theme.tint).frame(width: 13, height: 13)
                            Text(theme.displayName)
                        }
                        .tag(theme)
                    }
                }

                Picker("アプリアイコン", selection: iconBinding) {
                    ForEach(AppIconStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            } header: {
                SettingsSectionHeader("外観", systemImage: "paintpalette.fill")
            }

            Section {
                Link(destination: AppExternalLinks.x) {
                    ExternalLinkRow(title: "Xを開く", systemImage: "bubble.left.and.bubble.right.fill")
                }
                Link(destination: AppExternalLinks.instagram) {
                    ExternalLinkRow(title: "Instagramを開く", systemImage: "camera.fill")
                }
                if !AppDistribution.isPersonalEdition {
                    Button {
                        requestReview()
                    } label: {
                        Label("アプリのレビューを書く", systemImage: "star.bubble.fill")
                    }
                }

                // 個人用では料金画面を表示しないため、法的文書はサポート欄からも確認できます。
                Link(destination: AppLegalLinks.privacyPolicy) {
                    ExternalLinkRow(title: "プライバシーポリシー", systemImage: "hand.raised.fill")
                }
                Link(destination: AppLegalLinks.termsOfUse) {
                    ExternalLinkRow(title: "利用規約（EULA）", systemImage: "doc.text.fill")
                }
            } header: {
                SettingsSectionHeader("サポート", systemImage: "person.crop.circle.badge.questionmark")
            } footer: {
                Text("レビュー画面の表示はAppleの基準により制御されます。")
            }

            Section {
                LabeledContent("アプリ", value: AppDistribution.displayName)
                LabeledContent("バージョン", value: appVersion)

#if os(iOS)
                if AppDistribution.showsAdvertising && advertising.privacyOptionsRequired {
                    Button("広告のプライバシー設定", systemImage: "hand.raised.fill") {
                        advertising.presentPrivacyOptions()
                    }
                }
#endif

                VStack(alignment: .leading, spacing: 6) {
                    Label("対応画像形式", systemImage: "photo.on.rectangle.angled")
                        .font(.subheadline.weight(.semibold))
                    Text("JPEG、HEIF／HEIC、PNG、GIF、TIFF、WebP、BMP、端末が認識するRAW画像などを元形式のまま暗号化保存します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            } header: {
                SettingsSectionHeader("アプリ情報", systemImage: "info.circle.fill")
            }

            Section {
                NavigationLink { VaultCloudStatusView() } label: {
                    Label("バックアップ・復元の状態", systemImage: "icloud.and.arrow.up")
                }
                NavigationLink { VaultTrashView() } label: { Label("ゴミ箱", systemImage: "trash") }
                NavigationLink { VaultDuplicatesView() } label: { Label("重複写真を整理", systemImage: "square.on.square") }
                NavigationLink { VaultSimilarPhotosView() } label: { Label("類似写真を確認", systemImage: "photo.on.rectangle.angled") }
                NavigationLink { VaultStorageView() } label: { Label("容量を確認", systemImage: "internaldrive") }
                NavigationLink {
                    BackupManagementView()
                } label: {
                    SettingsNavigationRow(
                        title: "暗号化バックアップ",
                        subtitle: "アルバム全体を保存・復元",
                        systemImage: "externaldrive.badge.timemachine",
                        tint: model.theme.tint
                    )
                }

                Button("初期化の案内（iCloudを含む）", role: .destructive) {
                    model.showsLocalRestartConfirmation = true
                }
                Button("アプリ削除前に全データを消去", systemImage: "exclamationmark.triangle.fill", role: .destructive) {
                    showsFullDataDeletion = true
                }
            } header: {
                SettingsSectionHeader("データ管理", systemImage: "externaldrive.badge.xmark")
            } footer: {
                Text(fullDataDeletionDescription)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(model.theme.tint.opacity(0.035))
        .navigationTitle("設定")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .confirmationDialog(
            "すべてのデータを消去しますか？",
            isPresented: $showsFullDataDeletion,
            titleVisibility: .visible
        ) {
            Button("全データを消去", role: .destructive) {
                Task { await model.deleteAllApplicationData() }
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("この操作は取り消せません。完了後は初回設定画面に戻ります。")
        }
    }

    /// プレミアムの内容・状態・料金を最初に確認できるカードです。
    private var premiumOverviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "crown.fill")
                    .font(.title2)
                    .foregroundStyle(model.theme.tint)
                    .frame(width: 42, height: 42)
                    .background(model.theme.tint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("プレミアム")
                        .font(.headline)
                    Text(premiumStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.database.photos.count)枚")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                alignment: .leading,
                spacing: 10
            ) {
                Label("枚数無制限", systemImage: "photo.stack.fill")
                Label("サブアルバム", systemImage: "rectangle.stack.fill")
                Label("広告なし", systemImage: "rectangle.slash.fill")
            }
            .font(.subheadline)

            HStack {
                Text("月額150円 ／ 年額1,500円")
                    .font(.footnote.weight(.semibold))
                Spacer()
                if model.hasPremiumAccess {
                    Label("利用中", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            if model.hasPremiumAccess {
                HStack {
                    Button("購入情報を復元") {
                        Task { await model.restoreSubscriptions() }
                    }
                    Spacer()
                    Link(
                        "契約を管理",
                        destination: URL(string: "https://apps.apple.com/account/subscriptions")!
                    )
                }
                .font(.subheadline)
            } else {
                Button {
                    model.presentSubscriptionOffer()
                } label: {
                    Label("料金プランを見る", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [model.theme.tint.opacity(0.18), model.theme.tint.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(model.theme.tint.opacity(0.20), lineWidth: 1)
        }
    }

    private var premiumStatusText: String {
        model.hasPremiumAccess ? "プレミアムプランを利用中" : "無料版は写真100枚まで"
    }

    /// 一覧画面では現在有効な認証方法だけを短く表示します。
    private var securitySummary: String {
        var items: [String] = []
        if model.passwordEnabled { items.append("数字PIN") }
        if model.biometricsEnabled { items.append(model.biometryName) }
        if model.canAccessSubVault { items.append("サブアルバム") }
        return items.isEmpty ? "ロックとアルバム切り替えを設定" : items.joined(separator: "・")
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return version
    }

    /// デバッグ版ではiCloudを使用しないため、実際の消去範囲を明示します。
    private var fullDataDeletionDescription: String {
        if model.isICloudAvailableInThisBuild {
            return "端末とiCloudにある2つのアルバム、写真DB、認証情報、設定をすべて削除します。再インストール時にも残存データを自動消去します。サブスクリプションの解約は行いません。"
        }
        return "端末にある2つのアルバム、写真DB、認証情報、設定をすべて削除します。デバッグ版ではiCloudは対象外です。再インストール時にも残存データを自動消去します。サブスクリプションの解約は行いません。"
    }

    // 各Bindingは画面上の変更をAppModelの保存処理へ中継します。
    private var storageBinding: Binding<StorageLocation> {
        Binding(
            get: { model.storageLocation },
            set: { newValue in Task { await model.changeStorage(to: newValue) } }
        )
    }

    private var deleteOriginalBinding: Binding<Bool> {
        Binding(
            get: { model.database.deletesOriginalAfterImport },
            set: { value in Task { await model.setDeletesOriginalAfterImport(value) } }
        )
    }

    private var layoutBinding: Binding<AlbumLayout> {
        Binding(
            get: { model.database.albumLayout },
            set: { value in Task { await model.setAlbumLayout(value) } }
        )
    }

    private var sortOrderBinding: Binding<PhotoSortOrder> {
        Binding(
            get: { model.database.effectivePhotoSortOrder },
            set: { value in Task { await model.setPhotoSortOrder(value) } }
        )
    }

    private var folderSortOrderBinding: Binding<FolderSortOrder> {
        Binding(
            get: { model.database.effectiveFolderSortOrder },
            set: { value in Task { await model.setFolderSortOrder(value) } }
        )
    }

    private var slideshowBinding: Binding<Bool> {
        Binding(
            get: { model.database.effectiveSlideshowEnabled },
            set: { value in Task { await model.setSlideshowEnabled(value) } }
        )
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { model.theme },
            set: { model.setTheme($0) }
        )
    }

    private var iconBinding: Binding<AppIconStyle> {
        Binding(
            get: { model.iconStyle },
            set: { value in Task { await model.setIconStyle(value) } }
        )
    }
}

/// サブアルバムを開いている間だけ表示する、アルバム固有の簡易設定画面です。
///
/// メイン設定にある料金・外観・サポート・全データ消去などは表示しません。
/// 取り込み後削除を含むDB別設定は、現在開いているサブアルバムのDBへ保存されます。
struct SubVaultSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsSubPINConfiguration = false

    var body: some View {
        Form {
            Section {
                LabeledContent("写真", value: "\(model.database.photos.count)枚")
                LabeledContent(
                    model.storageLocation == .iCloud ? "元写真の合計サイズ" : "暗号化データ使用量",
                    value: ByteCountFormatter.string(
                        fromByteCount: model.currentVaultStorageBytes,
                        countStyle: .file
                    )
                )
            } header: {
                SettingsSectionHeader("サブアルバム", systemImage: "rectangle.stack.fill")
            }

            Section {
                Picker("写真と管理データ", selection: storageBinding) {
                    ForEach(StorageLocation.allCases) { location in
                        Label(location.displayName, systemImage: location.symbolName)
                            .tag(location)
                            .disabled(location == .iCloud && !model.isICloudAvailableInThisBuild)
                    }
                }
            } header: {
                SettingsSectionHeader("保存場所", systemImage: "externaldrive.fill")
            } footer: {
#if DEBUG
                Label("デバッグ版ではiCloudを無効にしています。Release版で利用できます。", systemImage: "hammer.fill")
                    .font(.footnote)
#else
                Text(model.isLocalRestartMode ? LocalRestartError.localOnly.localizedDescription : model.keepsSeparateRecoveryAlbum ? "端末内と以前のiCloudアルバムを切り替えます。写真は別々に保持され、自動で統合・同期されません。" : "サブアルバムの暗号化データだけを選択した保存場所へ移行します。")
#endif
            }

            Section {
                // この値はメイン設定とは共有せず、サブアルバムのVaultDatabaseへ保存します。
                Toggle("取り込み後に元写真を削除", isOn: deleteOriginalBinding)
            } header: {
                SettingsSectionHeader("写真の取り込み", systemImage: "square.and.arrow.down.fill")
            } footer: {
                Text("サブアルバムへ正常に保存できた後、Apple標準の削除確認を表示します。ファイルから選んだ画像は削除しません。")
            }

            Section {
                Picker("一覧の表示形式", selection: layoutBinding) {
                    ForEach(AlbumLayout.allCases) { layout in
                        Label(layout.displayName, systemImage: layout.symbolName)
                            .tag(layout)
                    }
                }

                Picker("写真の並び替え", selection: sortOrderBinding) {
                    ForEach(PhotoSortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }

                Picker("フォルダの並び替え", selection: folderSortOrderBinding) {
                    ForEach(FolderSortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }

                Toggle("スライドショーを使用", isOn: slideshowBinding)
            } header: {
                SettingsSectionHeader("表示と並び替え", systemImage: "rectangle.grid.2x2.fill")
            } footer: {
                Text("ここで変更した内容はサブアルバムだけに適用されます。")
            }

            Section {
                NavigationLink("バックアップ設定と復元") { BackupManagementView() }
            } footer: {
                Text("自動バックアップの時刻設定はメインと共通です。バックアップされるのは開いているアルバムです。")
            }

            if model.passwordEnabled && !model.legacyCredentialMode {
                Section {
                    Button(
                        model.subPINConfigured ? "サブアルバムのPINを変更" : "サブアルバムのPINを設定",
                        systemImage: "number.square.fill"
                    ) {
                        showsSubPINConfiguration = true
                    }
                } header: {
                    SettingsSectionHeader("セキュリティ", systemImage: "lock.shield.fill")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(model.theme.tint.opacity(0.035))
        .navigationTitle("サブアルバム設定")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task { await model.refreshStorageUsage() }
        .sheet(isPresented: $showsSubPINConfiguration) {
            SubPINConfigurationSheet { pin in
                Task { await model.configureSubPIN(pin) }
            }
        }
    }

    // MARK: - サブアルバムDBへ保存するBinding

    private var storageBinding: Binding<StorageLocation> {
        Binding(
            get: { model.storageLocation },
            set: { newValue in Task { await model.changeStorage(to: newValue) } }
        )
    }

    private var deleteOriginalBinding: Binding<Bool> {
        Binding(
            get: { model.database.deletesOriginalAfterImport },
            set: { enabled in Task { await model.setDeletesOriginalAfterImport(enabled) } }
        )
    }

    private var layoutBinding: Binding<AlbumLayout> {
        Binding(
            get: { model.database.albumLayout },
            set: { layout in Task { await model.setAlbumLayout(layout) } }
        )
    }

    private var sortOrderBinding: Binding<PhotoSortOrder> {
        Binding(
            get: { model.database.effectivePhotoSortOrder },
            set: { order in Task { await model.setPhotoSortOrder(order) } }
        )
    }

    private var folderSortOrderBinding: Binding<FolderSortOrder> {
        Binding(
            get: { model.database.effectiveFolderSortOrder },
            set: { order in Task { await model.setFolderSortOrder(order) } }
        )
    }

    private var slideshowBinding: Binding<Bool> {
        Binding(
            get: { model.database.effectiveSlideshowEnabled },
            set: { enabled in Task { await model.setSlideshowEnabled(enabled) } }
        )
    }
}

/// 現在開いているアルバム全体の暗号化バックアップ作成と復元を管理します。
struct BackupManagementView: View {
    @EnvironmentObject private var model: AppModel
    @State private var backupDocument = VaultBackupDocument()
    @State private var usesAutomaticBackup = false
    @State private var automaticStatus = "確認中"
    @AppStorage(DailyBackupSchedule.enabledKey) private var automaticBackupEnabled = true
    @AppStorage(DailyBackupSchedule.minuteKey) private var automaticBackupMinute = DailyBackupSchedule.defaultMinute
    @State private var retainedBackups: [RetainedBackupSummary] = []
    @State private var retainedBackupID: String?
    @State private var retainedListError: String?
    @State private var backupVaultKind: VaultKind?
    @State private var showsExporter = false
    @State private var showsImporter = false
    @State private var passwordOperation: BackupPasswordOperation?
    @State private var exportsAfterPasswordSheetCloses = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("写真", value: "\(model.database.photos.count)枚")
                LabeledContent(
                    model.storageLocation == .iCloud ? "元写真の合計サイズ" : "暗号化データ使用量",
                    value: ByteCountFormatter.string(
                        fromByteCount: model.currentVaultStorageBytes,
                        countStyle: .file
                    )
                )
                LabeledContent(
                    "元画像の合計",
                    value: ByteCountFormatter.string(
                        fromByteCount: model.database.totalOriginalByteCount,
                        countStyle: .file
                    )
                )
            } header: {
                SettingsSectionHeader("現在のアルバム", systemImage: "internaldrive.fill")
            }

            Section {
                Button("暗号化バックアップを作成", systemImage: "lock.doc.fill") {
                    usesAutomaticBackup = false
                    retainedBackupID = nil
                    passwordOperation = .create
                }
                Button("バックアップから復元", systemImage: "arrow.counterclockwise.icloud.fill") {
                    showsImporter = true
                }
            } header: {
                SettingsSectionHeader("バックアップと復元", systemImage: "externaldrive.badge.timemachine")
            } footer: {
                Text("バックアップ専用パスワードでアルバム全体（ゴミ箱を含む）をAES-GCM暗号化します。端末のKeychainに依存しないため、再インストール後にも同じ種類のアルバムへ復元できます。パスワードを忘れた場合は復元できません。")
            }

            Section("自動バックアップの設定") {
                Toggle("毎日自動でバックアップ", isOn: $automaticBackupEnabled)
                if automaticBackupEnabled {
                    DatePicker("実行時刻", selection: automaticBackupTimeBinding, displayedComponents: .hourAndMinute)
                }
                Text(automaticStatus)
                Button("自動バックアップを端末外へ書き出す") {
                    usesAutomaticBackup = true
                    retainedBackupID = nil
                    passwordOperation = .create
                }
                Text("1日1回、指定時刻以降に、圧縮可能なデータを圧縮して端末内のアプリ専用領域に暗号化保存します。アプリを開き、対象のアルバムがロック解除されている間に実行します。メインとサブはそれぞれ開く必要があります。指定時刻に実行できなかった場合は、次にアルバムを開いたときに実行します。最新版に加え、写真の削除などを検出した際は更新前の完成済みバックアップを保管します。自動バックアップはファイルアプリから直接表示されません。書き出したファイルは選択した場所に表示されます。アプリ削除や端末故障には備えられないため、端末外にも書き出してください。").font(.footnote)
            }
            .onChange(of: automaticBackupEnabled) { _, _ in
                Task { await model.refreshAutomaticBackupSchedule() }
            }
            .onChange(of: automaticBackupMinute) { _, _ in
                Task { await model.refreshAutomaticBackupSchedule() }
            }
            .task {
                while !Task.isCancelled {
                    automaticStatus = await model.automaticBackupStatusText()
                    do {
                        retainedBackups = try await model.retainedAutomaticBackups()
                        retainedListError = nil
                    } catch { retainedListError = "保管一覧を読み込めませんでした：\(error.localizedDescription)" }
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }

            Section("復旧用の保管フォルダ") {
                Button("最新の完成済みバックアップを保管") {
                    Task { await model.retainAutomaticBackup() }
                }
                if let retainedListError { Text(retainedListError).foregroundStyle(.red) }
                if retainedBackups.isEmpty { Text("保管済みのバックアップはありません") }
                ForEach(retainedBackups) { backup in
                    Button {
                        usesAutomaticBackup = true
                        retainedBackupID = backup.id
                        passwordOperation = .create
                    } label: {
                        VStack(alignment: .leading) {
                            Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text("写真\(backup.photoCount)枚（ゴミ箱を含む）・書き出して復元")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("保管分は自動では削除しません。選んだ日時のデータを書き出し、上の「バックアップから復元」で戻せます。復元は現在のアルバムを置き換えるため、必要なら現在のデータも先に書き出してください。端末容量を使用し、全データ消去・アプリ削除では失われます。").font(.footnote)
            }

            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section {
                Label("復元すると、現在開いているアルバムのフォルダ・写真・設定をバックアップ内容で置き換えます。検証または保存に失敗した場合、現在のデータは変更しません。", systemImage: "exclamationmark.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(model.theme.tint.opacity(0.035))
        .navigationTitle("暗号化バックアップ")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task { await model.refreshStorageUsage() }
        .fileExporter(
            isPresented: $showsExporter,
            document: backupDocument,
            contentType: .photoVaultBackup,
            defaultFilename: backupFilename
        ) { result in
            switch result {
            case .success:
                if let kind = backupVaultKind { model.recordBackupExport(for: kind) }
                statusMessage = "暗号化バックアップを保存しました。"
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.photoVaultBackup],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    passwordOperation = .restore(url)
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $passwordOperation, onDismiss: presentPendingExporter) { operation in
            BackupPasswordSheet(operation: operation) { password in
                switch operation {
                case .create:
                    backupVaultKind = model.currentVaultKind
                    guard let document = await model.makeEncryptedBackup(password: password, useAutomaticBackup: usesAutomaticBackup, retainedBackupID: retainedBackupID) else {
                        return false
                    }
                    backupDocument = document
                    exportsAfterPasswordSheetCloses = true
                    return true
                case .restore(let url):
                    let restored = await model.restoreEncryptedBackup(from: url, password: password)
                    if restored {
                        statusMessage = "バックアップを復元しました。"
                    }
                    return restored
                }
            }
        }
    }

    private var backupFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Album-\(formatter.string(from: .now))"
    }

    /// パスワードシートの閉じるアニメーション後にExporterを出し、シート同士の競合を防ぎます。
    private var automaticBackupTimeBinding: Binding<Date> {
        Binding(
            get: {
                let minute = (0..<1440).contains(automaticBackupMinute)
                    ? automaticBackupMinute : DailyBackupSchedule.defaultMinute
                return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60,
                                             second: 0, of: Date()) ?? Date()
            },
            set: { value in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
                automaticBackupMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func presentPendingExporter() {
        guard exportsAfterPasswordSheetCloses else { return }
        exportsAfterPasswordSheetCloses = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            showsExporter = true
        }
    }
}

/// バックアップ作成と復元で共用する、パスワード入力処理の種類です。
private enum BackupPasswordOperation: Identifiable {
    case create
    case restore(URL)

    var id: String {
        switch self {
        case .create: "create"
        case .restore(let url): "restore-\(url.absoluteString)"
        }
    }

    var title: String {
        switch self {
        case .create: "バックアップを暗号化"
        case .restore: "バックアップを復元"
        }
    }
}

/// バックアップ専用パスワードを入力し、作成時だけ入力一致も確認します。
private struct BackupPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let operation: BackupPasswordOperation
    let onSubmit: (String) async -> Bool
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isWorking = false

    private var canSubmit: Bool {
        password.count >= 8
            && (operation.isRestore || password == confirmation)
            && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("8文字以上のパスワード", text: $password)
                    if !operation.isRestore {
                        SecureField("パスワードを再入力", text: $confirmation)
                    }
                } footer: {
                    Text(operation.isRestore
                         ? "作成時に設定したバックアップ専用パスワードを入力してください。"
                         : "このパスワードは端末に保存されません。安全な場所に控えてください。")
                }

                if operation.isRestore {
                    Section {
                        Label("現在のアルバム内容は、復元した内容へ置き換わります。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if isWorking {
                    Section {
                        HStack {
                            ProgressView()
                            Text(operation.isRestore ? "検証して復元しています…" : "暗号化しています…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(operation.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if operation.isRestore {
                        Button("復元", role: .destructive) {
                            Task { await submit() }
                        }
                        .disabled(!canSubmit)
                    } else {
                        Button("作成") {
                            Task { await submit() }
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
        }
        .frame(minWidth: 340, minHeight: 270)
    }

    private func submit() async {
        guard canSubmit else { return }
        isWorking = true
        let succeeded = await onSubmit(password)
        isWorking = false
        if succeeded { dismiss() }
    }
}

private extension BackupPasswordOperation {
    var isRestore: Bool {
        if case .restore = self { return true }
        return false
    }
}

/// PIN・生体認証・サブアルバムを、設定トップより1階層深い画面へまとめます。
private struct SecuritySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsPINConfiguration = false
    @State private var showsSubPINConfiguration = false
    @State private var pinSheetIncludesSub = false

    var body: some View {
        Form {
            Section {
                if model.legacyCredentialMode {
                    Label("以前のパスワードを使用中です", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("4〜6桁の数字PINへ変更", systemImage: "number.square.fill") {
                        pinSheetIncludesSub = model.canAccessSubVault
                        showsPINConfiguration = true
                    }
                }

                Toggle("起動時に数字PINを使用", isOn: passwordBinding)

                if model.passwordEnabled && !model.legacyCredentialMode {
                    Button("PINを変更", systemImage: "number.square.fill") {
                        pinSheetIncludesSub = false
                        showsPINConfiguration = true
                    }
                }
            } header: {
                SettingsSectionHeader("数字PIN", systemImage: "number.square.fill")
            } footer: {
                Text("PINをオフにしても、写真・サムネイル・管理データの暗号化は維持されます。")
            }

            Section {
                Picker("自動ロック", selection: autoLockBinding) {
                    ForEach(AutoLockInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }

                Toggle("\(model.biometryName)を使用", isOn: biometricBinding)
                    .disabled(!model.biometricsAreAvailable && !model.biometricsEnabled)

                if model.biometricsEnabled {
                    Picker("認証後に開くアルバム", selection: biometricDestinationBinding) {
                        ForEach(BiometricUnlockDestination.allCases) { destination in
                            Text(destination.displayName)
                                .tag(destination)
                                .disabled(destination == .sub && !model.canAccessSubVault)
                        }
                    }
                }
            } header: {
                SettingsSectionHeader("自動ロックと生体認証", systemImage: model.biometrySymbolName)
            } footer: {
                Text("Face IDとTouch IDの両方に対応しています。自動ロック時間はアプリが画面から離れた時点から計測します。")
            }

            Section {
                Toggle("サブアルバムを使用", isOn: subVaultBinding)

                if model.passwordEnabled && model.canAccessSubVault && !model.legacyCredentialMode {
                    Button(
                        model.subPINConfigured ? "サブアルバムのPINを変更" : "サブアルバムのPINを設定",
                        systemImage: "number.square"
                    ) {
                        showsSubPINConfiguration = true
                    }
                }
            } header: {
                SettingsSectionHeader("サブアルバム", systemImage: "rectangle.stack.fill")
            } footer: {
                Text("プレミアム機能です。オフにしても保存済みの写真は削除されません。")
            }

            if model.passwordEnabled || model.biometricsEnabled || model.canAccessSubVault {
                Section {
                    Button(
                        model.passwordEnabled || model.biometricsEnabled ? "今すぐロック" : "アルバムを切り替える",
                        systemImage: model.passwordEnabled || model.biometricsEnabled ? "lock.fill" : "rectangle.2.swap"
                    ) {
                        model.lock()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(model.theme.tint.opacity(0.035))
        .navigationTitle("セキュリティ")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(isPresented: $showsPINConfiguration) {
            PINConfigurationSheet(includeSubPIN: pinSheetIncludesSub) { mainPIN, subPIN in
                Task { await model.configurePINs(mainPIN: mainPIN, subPIN: subPIN) }
            }
        }
        .sheet(isPresented: $showsSubPINConfiguration) {
            SubPINConfigurationSheet { pin in
                Task { await model.configureSubPIN(pin) }
            }
        }
    }

    private var biometricBinding: Binding<Bool> {
        Binding(
            get: { model.biometricsEnabled },
            set: { model.setBiometricsEnabled($0) }
        )
    }

    private var autoLockBinding: Binding<AutoLockInterval> {
        Binding(
            get: { model.autoLockInterval },
            set: { model.setAutoLockInterval($0) }
        )
    }

    private var biometricDestinationBinding: Binding<BiometricUnlockDestination> {
        Binding(
            get: { model.biometricUnlockDestination },
            set: { model.setBiometricUnlockDestination($0) }
        )
    }

    private var passwordBinding: Binding<Bool> {
        Binding(
            get: { model.passwordEnabled },
            set: { enabled in
                if enabled, !model.canEnablePasswordWithoutConfiguration {
                    pinSheetIncludesSub = model.canAccessSubVault
                    showsPINConfiguration = true
                } else {
                    model.setPasswordEnabled(enabled)
                }
            }
        )
    }

    private var subVaultBinding: Binding<Bool> {
        Binding(
            get: { model.canAccessSubVault },
            set: { enabled in
                if enabled, !model.hasPremiumAccess {
                    model.presentSubscriptionOffer()
                } else if enabled, model.passwordEnabled, model.legacyCredentialMode {
                    pinSheetIncludesSub = true
                    showsPINConfiguration = true
                } else if enabled, model.passwordEnabled, !model.subPINConfigured {
                    showsSubPINConfiguration = true
                } else {
                    model.setSubVaultEnabled(enabled)
                }
            }
        )
    }
}

/// 設定トップの階層項目に、内容の要約と統一アイコンを表示します。
private struct SettingsNavigationRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 外部サービスへ移動することが分かる、矢印付きリンク行です。
private struct ExternalLinkRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
    }
}

/// 公式SNSを開設した後、この2つのURLだけをアカウントのURLへ差し替えます。
private enum AppExternalLinks {
    static let x = URL(string: "https://x.com/")!
    static let instagram = URL(string: "https://www.instagram.com/")!
}

/// App Storeの審査およびサブスクリプション購入画面で使用する法的文書のURLです。
///
/// URLを画面内へ直接記述すると、将来の移転時に修正漏れが起きやすくなります。
/// プライバシーポリシーや利用規約の掲載先を変更する場合は、この定義だけを更新してください。
private enum AppLegalLinks {
    /// ログインなしで閲覧できる、本アプリ専用のプライバシーポリシーです。
    static let privacyPolicy = URL(
        string: "https://shashin-hokanko.yuyu0721-chito.chatgpt.site/privacy/"
    )!

    /// 本アプリが採用するApple標準利用規約（Standard EULA）です。
    static let termsOfUse = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    )!
}

/// 設定項目を探しやすくする、アイコン付きの統一セクション見出しです。
private struct SettingsSectionHeader: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
    }
}

/// 月額・年額プランの内容、購入、復元をまとめたプレミアム案内画面です。
struct PremiumSubscriptionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(model.theme.tint)

                    VStack(spacing: 8) {
                        Text("プレミアム")
                            .font(.largeTitle.bold())
                        Text("写真を枚数無制限で保存し、サブアルバムを利用できます。iPhone・iPadの広告も非表示になります。")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("写真を枚数無制限で保存", systemImage: "photo.stack.fill")
                        Label("サブアルバムを利用", systemImage: "rectangle.stack.fill")
                        Label("iPhone・iPadの広告を非表示", systemImage: "rectangle.slash.fill")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                    if model.hasPremiumAccess {
                        Label("プレミアムプランを利用中です", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                    } else if model.subscriptionProducts.isEmpty {
                        VStack(spacing: 10) {
                            fallbackPlan(title: "月額プラン", price: "月150円")
                            fallbackPlan(title: "年額プラン", price: "年1,500円")
                            Text("App Storeから商品情報を取得後に購入できます。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            // 商品登録直後や一時的な通信失敗から、画面を閉じずに復帰できるようにします。
                            Button {
                                Task { await model.prepareSubscriptions() }
                            } label: {
                                if model.isSubscriptionLoading {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Label("料金プランを再読み込み", systemImage: "arrow.clockwise")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isSubscriptionLoading)
                        }
                    } else {
                        ForEach(model.subscriptionProducts) { product in
                            Button {
                                Task { await model.purchaseSubscription(product) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(planTitle(for: product))
                                            .font(.headline)
                                        Text(product.displayPrice + planSuffix(for: product))
                                            .font(.title3.bold())
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .padding(16)
                                .background(model.theme.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isSubscriptionLoading)
                        }
                    }

                    if let message = model.subscriptionMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button("購入情報を復元") {
                        Task { await model.restoreSubscriptions() }
                    }
                    .disabled(model.isSubscriptionLoading)

                    Link(
                        "サブスクリプションを管理",
                        destination: URL(string: "https://apps.apple.com/account/subscriptions")!
                    )

                    // 自動更新サブスクリプションでは、購入前に利用規約と
                    // プライバシーポリシーを確認できる導線が必須です。
                    // Linkを使用することで、iPhone・iPadのどちらでも
                    // タップ時に標準ブラウザで確実に開けるようにしています。
                    VStack(spacing: 12) {
                        Divider()

                        Text("購入を続けることで、利用規約とプライバシーポリシーに同意したものとみなされます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        // 文字リンクだけにせず、行全体をタップ領域にすることで、
                        // 小さなiPhoneでもiPadでも押しやすい表示にしています。
                        legalDocumentLink(
                            title: "利用規約（EULA）",
                            systemImage: "doc.text",
                            destination: AppLegalLinks.termsOfUse
                        )

                        legalDocumentLink(
                            title: "プライバシーポリシー",
                            systemImage: "hand.raised",
                            destination: AppLegalLinks.privacyPolicy
                        )
                    }
                    .accessibilityElement(children: .contain)

                    Text("サブスクリプションは自動更新されます。解約しない限り、選択した期間ごとにApp Storeから請求されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("料金プラン")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 560)
        .task {
            // 起動直後の取得が失敗していても、料金画面を開いた時点でもう一度取得します。
            if model.subscriptionProducts.isEmpty {
                await model.prepareSubscriptions()
            }
        }
    }

    private func fallbackPlan(title: String, price: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text(price).font(.title3.bold())
        }
        .padding(16)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    /// 法的文書への導線を、十分なタップ領域を持つ統一デザインで表示します。
    private func legalDocumentLink(
        title: String,
        systemImage: String,
        destination: URL
    ) -> some View {
        Link(destination: destination) {
            HStack(spacing: 10) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 12)
                Image(systemName: "arrow.up.right.square")
                    .accessibilityHidden(true)
            }
            .font(.footnote.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(model.theme.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func planTitle(for product: Product) -> String {
        product.id == AppModel.yearlySubscriptionID ? "年額プラン" : "月額プラン"
    }

    private func planSuffix(for product: Product) -> String {
        product.id == AppModel.yearlySubscriptionID ? " / 年" : " / 月"
    }
}

/// 1つ目のPINと、必要に応じて2つ目のPINを登録・変更する画面です。
private struct PINConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let includeSubPIN: Bool
    let onSave: (String, String?) -> Void
    @State private var mainPIN = ""
    @State private var mainConfirmation = ""
    @State private var subPIN = ""
    @State private var subConfirmation = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("メインアルバム") {
                    SecureField("4〜6桁の数字PIN", text: $mainPIN)
                        .numericPINInput($mainPIN)
                    SecureField("PINを再入力", text: $mainConfirmation)
                        .numericPINInput($mainConfirmation)
                }

                if includeSubPIN {
                    Section("サブアルバム") {
                        SecureField("4〜6桁の数字PIN", text: $subPIN)
                            .numericPINInput($subPIN)
                        SecureField("PINを再入力", text: $subConfirmation)
                            .numericPINInput($subConfirmation)
                    }
                }

                Text("メインアルバムとサブアルバムには異なるPINを設定してください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("数字PINを設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(mainPIN, includeSubPIN ? subPIN : nil)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .frame(minHeight: 300)
    }

    private var canSave: Bool {
        guard isValid(mainPIN), mainPIN == mainConfirmation else { return false }
        guard includeSubPIN else { return true }
        return isValid(subPIN)
            && subPIN == subConfirmation
            && mainPIN != subPIN
    }

    private func isValid(_ pin: String) -> Bool {
        (4...6).contains(pin.count)
            && pin.allSatisfy { $0.isASCII && $0.wholeNumberValue != nil }
    }
}

/// サブアルバムを初めて有効にする際、iPhone風キーパッドでPINを2回入力する画面です。
private struct SubPINConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let onSave: (String) -> Void
    @State private var step: Step = .newPIN
    @State private var newPIN = ""
    @State private var currentInput = ""
    @State private var validationMessage = ""

    private enum Step: Equatable {
        case newPIN
        case confirmation
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 44))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(model.theme.tint)

                    VStack(spacing: 6) {
                        Text(step == .newPIN ? "新しいPINを入力" : "PINをもう一度入力")
                            .font(.title2.bold())
                        Text(step == .newPIN ? "4〜6桁の数字で設定してください" : "確認のため同じPINを入力してください")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    PINIndicatorView(digitCount: currentInput.count, tint: model.theme.tint)

                    Text(validationMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(height: 16)

                    NumericPINKeypad(
                        value: $currentInput,
                        tint: model.theme.tint,
                        onValueChange: { _ in validationMessage = "" }
                    )

                    Button(step == .newPIN ? "次へ" : "保存") {
                        advance()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 280)
                    .disabled(!isCurrentInputValid)

                    Text("メインアルバムとは異なるPINを設定してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("サブアルバムのPIN")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
#if os(iOS)
        .presentationDetents([.large])
#else
        .frame(minWidth: 420, minHeight: 620)
#endif
    }

    private var isCurrentInputValid: Bool {
        (4...6).contains(currentInput.count)
            && currentInput.allSatisfy { $0.isASCII && $0.wholeNumberValue != nil }
    }

    /// 1回目は確認画面へ進み、2回目が一致したときだけ保存します。
    private func advance() {
        guard isCurrentInputValid else { return }

        switch step {
        case .newPIN:
            newPIN = currentInput
            currentInput = ""
            validationMessage = ""
            withAnimation(.easeInOut(duration: 0.18)) {
                step = .confirmation
            }
        case .confirmation:
            guard currentInput == newPIN else {
                validationMessage = "PINが一致しません。もう一度入力してください。"
                currentInput = ""
                return
            }
            onSave(newPIN)
            dismiss()
        }
    }
}
