import SwiftUI

struct VaultCloudStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("現在のアルバム") {
                Text(model.currentVaultKind?.displayName ?? "アルバム")
                LabeledContent("保存先", value: model.storageLocation.displayName)
                LabeledContent("この端末の認証情報", value: model.hasRecoveryCredentials ? "あり" : "未確認")
                LabeledContent("暗号化バックアップの最終書き出し",
                    value: model.lastBackupExportDate?.formatted(date: .abbreviated, time: .shortened) ?? "記録なし")
                Text("書き出し日時はこの端末の記録です。保存先でのファイルの存在や、その後の変更内容までは確認していません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.storageLocation == .local {
                Section {
                    Text("この端末だけに保存されています。アンインストールすると写真は失われます。暗号化バックアップを別の場所に保存してください。")
                    NavigationLink("暗号化バックアップを作成") { BackupManagementView() }
                }
            } else {
                Section("iCloudへの保存状況（ゴミ箱を含む）") {
                    if let status = model.cloudStatus {
                        LabeledContent("管理データ", value: status.index.title)
                        LabeledContent("アップロード済み", value: "\(status.uploadedPhotos)枚")
                        LabeledContent("同期中・待機中", value: "\(status.pendingPhotos)枚")
                        LabeledContent("未確認", value: "\(status.unknownPhotos)枚")
                        LabeledContent("エラー・競合あり", value: "\(status.failedPhotos)枚")
                        LabeledContent("最終確認", value: status.checkedAt.formatted(date: .abbreviated, time: .standard))
                    } else {
                        Text(model.cloudStatusError ?? "状態を確認中です。管理データの読み込み完了後に確認できます。")
                    }
                    Button("状態を再確認") { Task { await model.checkCloudStatus() } }
                }
                Section("復元に必要なもの") {
                    Text("同じApple Account、以前のPIN／パスワード、同期済みの認証情報が必要です。別端末への認証情報の同期完了は、この画面では確認できません。")
                    Text("表示は確認日時点でiOSが報告した状態です。オフラインでは最新とは限らず、復元の成功を保証するものではありません。独立した暗号化バックアップも保存してください。")
                    NavigationLink("暗号化バックアップ") { BackupManagementView() }
                }
            }
        }
        .navigationTitle("バックアップ・復元の状態")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.maintenanceRevision) { await model.checkCloudStatus() }
    }
}

struct VaultTrashView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleting: Set<UUID> = []
    @State private var showsConfirmation = false

    var body: some View {
        List {
            Section {
                Text("写真は削除から30日間保管されます。期限を過ぎた写真は、アルバムを開いたときに完全削除します。削除済みフォルダの写真は同じ名前のフォルダを作って復元します。")
                    .font(.footnote)
                Button("期限切れを整理") { Task { await model.purgeExpiredTrash() } }
                if !(model.database.trash ?? []).isEmpty {
                    Button("ゴミ箱を空にする", role: .destructive) {
                        deleting = Set((model.database.trash ?? []).map(\.id))
                        showsConfirmation = true
                    }
                }
            }
            if (model.database.trash ?? []).isEmpty { Text("ゴミ箱は空です") }
            ForEach((model.database.trash ?? []).sorted { $0.deletedAt > $1.deletedAt }) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if entry.deletionRequested != true {
                            AsyncVaultImage(photoID: entry.id)
                                .frame(width: 52, height: 52).clipped()
                        }
                        Text(entry.photo.displayFilename).font(.headline)
                    }
                    Text(entry.originalFolderName ?? "未分類").font(.caption).foregroundStyle(.secondary)
                    Text(entry.deletionRequested == true ? "完全削除を再試行します" : "復元期限：\(entry.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                    HStack {
                        Button("復元") { Task { await model.restoreTrashedPhoto(id: entry.id) } }
                            .disabled(!entry.canRestore())
                        Spacer()
                        Button("完全削除", role: .destructive) {
                            deleting = [entry.id]
                            showsConfirmation = true
                        }
                    }.buttonStyle(.bordered)
                }
            }
        }
        .disabled(!model.canEditVault || model.isWorking)
        .navigationTitle("ゴミ箱")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.purgeExpiredTrash() }
        .confirmationDialog("選択した\(deleting.count)枚を完全削除しますか？", isPresented: $showsConfirmation, titleVisibility: .visible) {
            Button("完全削除", role: .destructive) { Task { await model.permanentlyDeletePhotos(ids: deleting) } }
        } message: { Text("この操作は取り消せません。iCloud保存の場合は他の端末にも反映されます。") }
    }
}

struct VaultDuplicatesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Text("現在のアルバムの元ファイルを照合します。名前や見た目だけでは判定しません。iCloud上の写真はダウンロードするため通信量が増える場合があります。ゴミ箱の写真は対象外です。")
                    .font(.footnote)
                if model.isScanningDuplicates {
                    ProgressView("写真を照合中…")
                    Button("中止") { scanTask?.cancel() }
                } else {
                    Button("重複写真を確認") {
                        scanTask = Task { await model.scanDuplicatePhotos() }
                    }.disabled(!model.canEditVault || model.isWorking)
                }
            }
            if let result = model.duplicateScan {
                Section {
                    Text("確認済み：\(result.inspectedCount)枚 ／ 確認できなかった写真：\(result.failedCount)枚")
                    Text("重複：\(result.groups.count)組")
                    if result.failedCount > 0 { Text("読み込めなかった写真は判定していません。通信状態を確認して再実行してください。") }
                    if result.groups.isEmpty { Text("確認できた写真の中に重複はありませんでした。") }
                }
                ForEach(result.groups) { group in
                    DuplicateGroupSection(group: group)
                }
            }
        }
        .navigationTitle("重複写真を整理")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            scanTask?.cancel()
            model.resumeOCRAfterDuplicateReview()
        }
    }
}

private struct DuplicateGroupSection: View {
    @EnvironmentObject private var model: AppModel
    let group: DuplicatePhotoGroup
    @State private var keptID: UUID?
    @State private var confirmsRemoval = false

    var body: some View {
        Section("同じ内容の写真 \(group.photos.count)枚") {
            ForEach(group.photos) { photo in
                Button {
                    keptID = photo.id
                } label: {
                    HStack {
                        AsyncVaultImage(photoID: photo.id)
                            .frame(width: 48, height: 48).clipped()
                        VStack(alignment: .leading) {
                            Text(photo.displayFilename)
                            Text(model.database.folders.first { $0.id == photo.folderID }?.name ?? "未分類")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if (keptID ?? group.photos.first?.id) == photo.id {
                            Label("残す", systemImage: "checkmark.circle.fill")
                        }
                    }
                }.buttonStyle(.plain)
            }
            Text("完全削除後に減る元画像の容量：\(ByteCountFormatter.string(fromByteCount: group.recoverableBytes, countStyle: .file))")
                .font(.caption)
            Button("選択した1枚を残してゴミ箱へ", role: .destructive) { confirmsRemoval = true }
                .disabled(!model.canEditVault || model.isWorking)
        }
        .confirmationDialog("ほかの\(group.photos.count - 1)枚をゴミ箱へ移動しますか？", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("ゴミ箱へ移動", role: .destructive) {
                guard let id = keptID ?? group.photos.first?.id else { return }
                Task { await model.removeDuplicates(group, keeping: id) }
            }
        } message: { Text("30日以内ならゴミ箱から復元できます。移動後は再確認して次の組を整理してください。") }
    }
}

struct VaultStorageView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmsCacheRemoval = false

    private func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "未確認" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        List {
            Section(model.currentVaultKind?.displayName ?? "現在のアルバム") {
                LabeledContent("保存先", value: model.storageLocation.displayName)
                LabeledContent("写真", value: "\(model.database.photos.count)枚")
                LabeledContent("元写真", value: size(model.database.totalOriginalByteCount))
                LabeledContent("ゴミ箱", value: size(model.database.trashByteCount))
                if let status = model.storageStatus {
                    LabeledContent("暗号化写真（ゴミ箱を含む）", value: size(status.encryptedFileBytes))
                    LabeledContent("サムネイル", value: size(status.thumbnailBytes))
                    LabeledContent("管理データ", value: size(status.indexBytes))
                    LabeledContent("表示用ディスクキャッシュ", value: size(status.cacheBytes))
                    LabeledContent("確認日時", value: status.checkedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Button("容量を再確認") { Task { await model.checkStorageStatus() } }
            }
            Section {
                Text("現在開いているアルバムだけを表示しています。別のアルバムはロック画面から開いて確認してください。元写真の容量と暗号化写真の容量は同じ写真を別の基準で表した値です。")
                if model.storageLocation == .iCloud {
                    Text("iCloud上のサイズはファイルの論理サイズです。この端末へのダウンロード済み容量やiCloud契約全体の使用量とは異なります。取得できないサイズは未確認と表示します。")
                }
                Button("表示用キャッシュを削除") { confirmsCacheRemoval = true }
                    .disabled(model.isWorking)
            } footer: {
                Text("元写真・ゴミ箱・認証情報は削除しません。表示用のメモリと暗号化キャッシュを整理します。iCloudの写真は次に表示するとき再取得するため、通信が必要になる場合があります。")
            }
            Section("フォルダ別（直下の写真）") {
                ForEach(model.database.sortedFolders) { folder in
                    LabeledContent(folder.name, value: size(model.database.photos.filter { $0.folderID == folder.id }
                        .reduce(0) { $0 + max(0, $1.originalByteCount) }))
                }
            }
            Section("容量の大きい写真（上位20枚）") {
                ForEach(model.database.photos.sorted { $0.originalByteCount > $1.originalByteCount }.prefix(20)) { photo in
                    NavigationLink { PhotoDetailView(photoID: photo.id) } label: {
                        LabeledContent(photo.displayFilename, value: size(photo.originalByteCount))
                    }
                }
            }
        }
        .navigationTitle("容量を確認")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.maintenanceRevision) { await model.checkStorageStatus() }
        .confirmationDialog("表示用キャッシュを削除しますか？", isPresented: $confirmsCacheRemoval, titleVisibility: .visible) {
            Button("キャッシュを削除") { Task { await model.clearDisplayCache() } }
        } message: { Text("写真本体は残ります。オフライン中はiCloudの写真を再表示できなくなる場合があります。") }
    }
}

struct VaultSimilarPhotosView: View {
    @EnvironmentObject private var model: AppModel
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Text("現在のアルバムから、構図や明暗が近い写真を探します。完全に同じ写真も含みます。ゴミ箱は対象外です。iCloudの元写真を取得する場合は通信が発生します。")
                    .font(.footnote)
                Text("候補は同じ写真とは限りません。切り抜き・回転・色だけの違いなどは正しく判定できない場合があります。写真を開いて確認してください。自動では削除しません。")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.isScanningSimilarPhotos {
                    ProgressView("類似写真を確認中…")
                    Button("中止") { scanTask?.cancel() }
                } else {
                    Button("類似写真を確認") {
                        scanTask = Task { await model.scanSimilarPhotos() }
                    }.disabled(!model.canEditVault || model.isWorking || model.isScanningDuplicates)
                }
            }
            if let result = model.similarPhotoScan {
                Section {
                    Text("確認済み：\(result.inspectedCount)枚 ／ 確認できなかった写真：\(result.failedCount)枚")
                    Text("類似候補：\(result.groups.count)組")
                    if result.failedCount > 0 { Text("読み込めなかった写真は判定していません。通信状態を確認して再実行してください。") }
                    if result.groups.isEmpty { Text("確認できた写真の中に類似候補は見つかりませんでした。") }
                }
                ForEach(result.groups) { group in
                    Section("似ている可能性のある写真 \(group.photos.count)枚") {
                        ForEach(group.photos) { photo in
                            NavigationLink { PhotoDetailView(photoID: photo.id) } label: {
                                HStack {
                                    AsyncVaultImage(photoID: photo.id)
                                        .frame(width: 72, height: 72).clipped()
                                    Text(photo.displayFilename)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("類似写真を確認")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            scanTask?.cancel()
            model.resumeOCRAfterDuplicateReview()
        }
    }
}
