import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// フォルダ一覧を起点に、写真一覧と設定へ移動するメイン画面です。
struct MainSplitView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var advertising: AdvertisingService
    @State private var showsLocalRecoveryConfirmation = false
    @State private var showsAutomaticRecoveryConfirmation = false
    @State private var path: [MainRoute] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showsPhotosPicker = false
    @State private var photoImportFolderID: UUID?
    @State private var showsFileImporter = false
    @State private var showsAddFolder = false
    @State private var folderCreationParentID: UUID?
    @State private var folderToRename: AlbumFolder?
    @State private var folderToMove: AlbumFolder?
    @State private var folderToDelete: AlbumFolder?
    @State private var archiveDocument = ArchiveDocument()
    @State private var showsExporter = false
    @State private var exportFilename = "写真"

    var body: some View {
        NavigationStack(path: $path) {
            // ログイン後はメニューを挟まず、フォルダカードをルート画面として表示します。
            mainScreen
                .navigationDestination(for: MainRoute.self) { route in
                    destination(for: route)
                }
        }
        .alert("自動バックアップから復元しますか？", isPresented: $showsAutomaticRecoveryConfirmation) {
            Button("別の端末アルバムへ復元") { Task { await model.recoverAutomaticBackupToSeparateLocal() } }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("この端末に保存された完成済みの自動バックアップから、別の端末アルバムを作ります。元のアルバムは上書きしません。復元後の写真は自動でiCloudへ同期されません。")
        }
        .alert("端末内のアルバムを使いますか？", isPresented: $showsLocalRecoveryConfirmation) {
            Button("端末内で使い始める") { Task { await model.startLocalRecoveryAlbum() } }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("以前と同じPIN／パスワードで使えます。iCloudの写真と復元用の認証情報は保持します。端末に保存した写真は自動でiCloudへ同期されません。設定の保存場所から以前のiCloudアルバムへ戻れます。端末内に既存のアルバムがあれば、そのまま開きます。")
        }
#if os(iOS)
        // 無料版ではログイン後の各画面下部へ広告を固定し、本文との重なりをsafeAreaInsetで防ぎます。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if shouldShowBanner && advertising.canRequestAds {
                Divider()
                PhotoVaultBannerAdView()
            }
        }
#endif
        // iOS標準の写真選択画面を使用します。選択完了後に、開いた時点のフォルダへ取り込みます。
        .onChange(of: pickerItems.count) { _, count in
            guard count > 0 else { return }
            let items = pickerItems
            let folderID = photoImportFolderID
            pickerItems = []
            Task { await model.importPickerItems(items, into: folderID) }
        }
        .photosPicker(
            isPresented: $showsPhotosPicker,
            selection: $pickerItems,
            maxSelectionCount: nil,
            matching: .images,
            preferredItemEncoding: .current,
            photoLibrary: PHPhotoLibrary.shared()
        )
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await model.importFileURLs(urls, into: selectedFolderID) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showsExporter,
            document: archiveDocument,
            contentType: .zip,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsAddFolder, onDismiss: { folderCreationParentID = nil }) {
            FolderNameSheet(title: folderCreationParentID == nil ? "新しいフォルダ" : "新しいサブフォルダ") { name in
                await model.createFolder(named: name, parentID: folderCreationParentID)
            }
        }
        .sheet(item: $folderToRename) { folder in
            FolderNameSheet(title: "フォルダ名を変更", initialName: folder.name) { name in
                await model.renameFolder(id: folder.id, to: name)
            }
        }
        .sheet(item: $folderToMove) { folder in
            // 自分自身と配下は移動先から除外し、階層の循環を画面上でも防ぎます。
            FolderDestinationPicker(
                title: "フォルダの移動先",
                folders: model.database.sortedFolders,
                excludedFolderIDs: model.database.folderIDs(includingDescendantsOf: folder.id),
                allowsRoot: true,
                currentDestinationID: folder.parentID
            ) { destinationID in
                await model.moveFolder(id: folder.id, toParentID: destinationID)
            }
        }
        .confirmationDialog(
            "「\(folderToDelete?.name ?? "")」を削除しますか？",
            isPresented: Binding(
                get: { folderToDelete != nil },
                set: { if !$0 { folderToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("フォルダを削除・写真をゴミ箱へ", role: .destructive) {
                guard let folder = folderToDelete else { return }
                folderToDelete = nil
                Task { await model.deleteFolder(id: folder.id) }
            }
            Button("キャンセル", role: .cancel) { folderToDelete = nil }
        } message: {
            Text("フォルダ構造は削除されます。中の写真はゴミ箱へ移動し、30日間復元できます。")
        }
    }

#if os(iOS)
    /// 無料利用中だけ広告を表示します。Debug版ではGoogle公式テスト広告が使われるため、
    /// ローカルStoreKitで購入前／購入後の表示切り替えも安全に確認できます。
    private var shouldShowBanner: Bool {
        !model.hasPremiumAccess
    }
#endif

    /// SwiftUIのツールバー更新状態に依存しない、フォルダ一覧専用のルート画面です。
    private var mainScreen: some View {
        VStack(spacing: 0) {
            mainActionBar
            Divider()
            // iCloudの状態表示はナビゲーション全体の上へ重ねず、ルート画面内だけに置きます。
            // これにより設定画面やフォルダ画面の戻るボタン・タイトルが隠れません。
            if shouldShowCloudStatusBar {
                cloudStatusBar
                Divider()
            }
            if model.hasLoadedVaultIndex {
                albumUsageBar
                folderOverview
            } else {
                ContentUnavailableView {
                    Label(
                        model.isRecoveringFromICloud && model.isRefreshingCloud
                            ? "iCloudからアルバムを復元中"
                            : (model.isRefreshingCloud ? "アルバムを読み込み中" : "読み込みを完了できませんでした"),
                        systemImage: "icloud.and.arrow.down"
                    )
                } description: {
                    if model.isRefreshingCloud {
                        Text("\(model.cloudLoadStage)。取得でき次第、自動で表示されます。")
                    } else {
                        Text(model.cloudLoadMessage ?? "通信状態とiCloud Driveを確認して再読み込みしてください。既存の写真は変更していません。")
                    }
                } actions: {
                    if model.isRefreshingCloud {
                        ProgressView()
                        Button("読み込みを中止") { model.cancelCloudLoading() }
                    } else {
                        Button("再読み込み") { Task { await model.retryVaultLoading() } }
                            .buttonStyle(.borderedProminent)
                        Button("自動バックアップから復元") { showsAutomaticRecoveryConfirmation = true }
                        if model.canStartLocalRecoveryAlbum {
                            Button("端末内のアルバムを使う") { showsLocalRecoveryConfirmation = true }
                        }
                        Button("設定を初期化して新しく始める", role: .destructive) {
                            model.showsLocalRestartConfirmation = true
                        }
                        if let message = model.cloudLoadMessage {
                            Button("エラー内容をコピー", systemImage: "doc.on.doc") {
                                copyCloudError(message)
                            }
                        }
                    }
                }
            }
        }
        // 子Viewが必要以上の横幅を要求しても、画面全体を端末幅からはみ出させません。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func copyCloudError(_ message: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "不明"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "不明"
        UIPasteboard.general.string = "PhotoVault \(version) / build \(build)\n対象：\(model.currentVaultKind?.rawValue ?? "不明")\n\(message)"
    }

    /// 正常時は表示せず、iCloudの一覧をまだ編集可能な状態まで取得できていない時だけ表示します。
    private var shouldShowCloudStatusBar: Bool {
        model.storageLocation == .iCloud && model.hasLoadedVaultIndex && !model.canEditVault
    }

    /// フォルダ一覧の上にだけ状態を表示し、他画面のナビゲーション領域を塞ぎません。
    private var cloudStatusBar: some View {
        HStack(spacing: 10) {
            if model.isRefreshingCloud {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "icloud.and.arrow.down")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isRefreshingCloud ? "iCloudの一覧を読み込み中" : "iCloudの読み込み待ち")
                    .font(.caption.weight(.semibold))
                if let message = model.cloudLoadMessage {
                    Text(message).font(.caption2)
                    Button("エラー内容をコピー") { copyCloudError(message) }
                        .font(.caption2)
                } else {
                    Text("保存済みの一覧を表示しています。写真の追加・編集は読み込み完了後に利用できます。")
                        .font(.caption2)
                }
            }
            Spacer(minLength: 0)
            Button("再試行") {
                model.retryImageLoading()
                model.retryCloudLoading()
            }
            .font(.caption)
            .disabled(model.isRefreshingCloud)
            if model.isRefreshingCloud {
                Button("中止") { model.cancelCloudLoading() }.font(.caption)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    /// 設定・整理・追加の3系統だけを表示する、画面幅を超えない上部操作バーです。
    private var mainActionBar: some View {
        HStack(spacing: 8) {
            // メイン／サブのどちらでも設定入口を表示します。
            // 遷移先で現在のアルバム種別を判定し、サブ側には必要な項目だけを表示します。
            Button {
                path.append(.settings)
            } label: {
                Label("設定", systemImage: "gearshape.fill")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(model.currentVaultKind == .sub ? "サブアルバム設定" : "設定")

            // 利用頻度が低い整理機能は1つのメニューへまとめ、横方向のはみ出しを防ぎます。
            Menu {
                Button("新しいフォルダ", systemImage: "folder.badge.plus") {
                    presentFolderCreation(parentID: nil)
                }
                .disabled(!model.canEditVault)
                Divider()
                Button("スマートフォルダ", systemImage: "sparkles.rectangle.stack") {
                    path.append(.smartFolders)
                }
                Button("画像内の文字を検索", systemImage: "text.viewfinder") {
                    path.append(.ocrSearch)
                }
                Divider()
                Button("画像を再読み込み", systemImage: "arrow.clockwise") {
                    model.retryImageLoading()
                }
            } label: {
                Label("整理", systemImage: "ellipsis.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("整理メニュー")

            mainPhotoImportMenu
                .disabled(!model.canEditVault)
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }

    /// DB内の元写真合計を表示し、起動時の全ファイル走査を省きます。
    private var albumUsageBar: some View {
        HStack {
            Label("\(model.database.photos.count)枚", systemImage: "photo.stack")
            Spacer()
            Label(
                "元写真 " + ByteCountFormatter.string(
                    fromByteCount: model.database.totalOriginalByteCount,
                    countStyle: .file
                ),
                systemImage: "internaldrive"
            )
            .accessibilityLabel("元写真の合計サイズ")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(model.theme.tint.opacity(0.035))
    }

    /// ナビゲーションのルートとして常時表示するフォルダ一覧です。
    private var folderOverview: some View {
        FolderOverviewView(
            // DB内の保存順ではなく、設定画面で選んだ日付順／名前順を一覧へ反映します。
            folders: model.database.childFolders(of: nil),
            photoCounts: model.database.photoCountsByFolderTree,
            featuredPhotos: model.database.featuredPhotosByFolder,
            onSelect: { path.append(.folder($0)) },
            onAdd: { presentFolderCreation(parentID: nil) },
            onImport: openPhotoLibraryPicker,
            onRename: { folderToRename = $0 },
            onMove: { folderToMove = $0 },
            onExport: { export(folder: $0) },
            onDelete: { folderToDelete = $0 }
        )
    }

    /// 選択したフォルダまたは設定を、フォルダ一覧の次の画面として表示します。
    @ViewBuilder
    private func destination(for route: MainRoute) -> some View {
        switch route {
        case .folder(let id):
            if let folder = model.database.folders.first(where: { $0.id == id }) {
                PhotoCollectionView(
                    folder: folder,
                    onRenameFolder: { folderToRename = $0 },
                    onMoveFolder: { folderToMove = $0 },
                    onExportFolder: { export(folder: $0) },
                    onDeleteFolder: { folderToDelete = $0 }
                )
                    .toolbar {
                        ToolbarItem { folderAddMenu(parentID: folder.id) }
                    }
            } else {
                ContentUnavailableView("フォルダがありません", systemImage: "folder")
            }
        case .smartFolders:
            SmartFoldersView()
        case .smartFolder(let filter):
            SmartPhotoCollectionView(filter: filter)
        case .ocrSearch:
            OCRSearchView()
        case .settings:
            switch model.currentVaultKind {
            case .some(.main):
                SettingsView()
            case .some(.sub):
                // メイン側の契約・外観・全データ操作は見せず、サブDB固有の設定だけを表示します。
                SubVaultSettingsView()
            case .none:
                ContentUnavailableView("アルバムを開けません", systemImage: "lock.fill")
            }
        }
    }

    /// フォルダ内の追加操作を1つにまとめ、サブフォルダ作成と写真取り込みを選べるようにします。
    private func folderAddMenu(parentID: UUID) -> some View {
        Menu {
            Button("サブフォルダを作成", systemImage: "folder.badge.plus") {
                presentFolderCreation(parentID: parentID)
            }
            Divider()
            Button("写真ライブラリから", systemImage: "photo.on.rectangle") {
                openPhotoLibraryPicker()
            }
            Button("ファイルから", systemImage: "folder") {
                showsFileImporter = true
            }
        } label: {
            Label("追加", systemImage: "plus")
                .labelStyle(.iconOnly)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("サブフォルダまたは写真を追加")
        .disabled(!model.canEditVault)
    }

    /// メイン画面では文字も表示し、写真追加の場所を一目で判断できるようにします。
    private var mainPhotoImportMenu: some View {
        Menu {
            Button {
                openPhotoLibraryPicker()
            } label: {
                Label("写真ライブラリから", systemImage: "photo.on.rectangle")
            }
            Button {
                showsFileImporter = true
            } label: {
                Label("ファイルから", systemImage: "folder")
            }
        } label: {
            Label("追加", systemImage: "plus")
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("写真を追加")
    }

    /// 写真の追加先となる、現在選択中のフォルダIDです。
    private var selectedFolderID: UUID? {
        if let route = path.last, case .folder(let id) = route { return id }
        return nil
    }

    /// 選択画面を開いた時点のフォルダを保持し、画面終了アニメーション中の遷移に影響されないようにします。
    private func openPhotoLibraryPicker() {
        photoImportFolderID = selectedFolderID
        guard model.database.deletesOriginalAfterImport else {
            showsPhotosPicker = true
            return
        }

        // 取り込み後削除を使う場合だけ読み書き権限を先に確認します。
        // 権限が許可されなくても、iOS標準ピッカーから写真を選ぶ機能自体は利用できます。
        Task {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            showsPhotosPicker = true
        }
    }

    /// nilなら最上位、IDがあればそのフォルダ直下に新しいフォルダを作成します。
    private func presentFolderCreation(parentID: UUID?) {
        folderCreationParentID = parentID
        showsAddFolder = true
    }

    private func export(folder: AlbumFolder) {
        Task {
            if let document = await model.makeArchive(folderID: folder.id) {
                archiveDocument = document
                exportFilename = folder.name
                showsExporter = true
            }
        }
    }

}

/// ログイン直後に表示するフォルダカードの一覧です。
private struct FolderOverviewView: View {
    @EnvironmentObject private var model: AppModel
    let folders: [AlbumFolder]
    let photoCounts: [UUID: Int]
    let featuredPhotos: [UUID: PhotoRecord]
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void
    let onImport: () -> Void
    let onRename: (AlbumFolder) -> Void
    let onMove: (AlbumFolder) -> Void
    let onExport: (AlbumFolder) -> Void
    let onDelete: (AlbumFolder) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 96, maximum: 132), spacing: 8)
    ]

    var body: some View {
        Group {
            if folders.isEmpty {
                ContentUnavailableView {
                    Label("フォルダがありません", systemImage: "folder")
                } description: {
                    Text("最初のフォルダを作成して、写真を整理しましょう。")
                } actions: {
                    HStack {
                        Button("写真を追加", systemImage: "photo.badge.plus", action: onImport)
                            .buttonStyle(.borderedProminent)
                        Button("フォルダを作成", systemImage: "folder.badge.plus", action: onAdd)
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(folders) { folder in
                            ZStack(alignment: .topTrailing) {
                                Button {
                                    onSelect(folder.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Color.clear
                                            .aspectRatio(1, contentMode: .fit)
                                            .overlay {
                                                if let photo = featuredPhotos[folder.id] {
                                                    AsyncVaultImage(photoID: photo.id)
                                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                        .clipped()
                                                } else {
                                                    ZStack {
                                                        model.theme.tint.opacity(0.12)
                                                        Image(systemName: "folder.fill")
                                                            .font(.system(size: 32))
                                                            .foregroundStyle(model.theme.tint)
                                                    }
                                                }
                                            }
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                            .overlay(alignment: .bottomTrailing) {
                                                Image(systemName: "folder.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.white)
                                                    .padding(5)
                                                    .background(model.theme.tint, in: Circle())
                                                    .padding(5)
                                            }
                                        Text(folder.name)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                        Text("\(photoCounts[folder.id, default: 0])枚")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .contextMenu { folderMenu(folder) }

                                Menu {
                                    folderMenu(folder)
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .frame(width: 30, height: 30)
                                        .background(.regularMaterial, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .padding(13)
                                .accessibilityLabel("\(folder.name)の操作")
                            }
                        }
                    }
                    // ナビゲーションバー直下の余白をなくし、左右と下だけに間隔を設けます。
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    // カードが少ない場合も左端を基準に配置し、画面外へ中心寄せされるのを防ぎます。
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(model.theme.tint.opacity(0.035))
    }

    /// フォルダカードの長押しと操作ボタンで共用するメニューです。
    @ViewBuilder
    private func folderMenu(_ folder: AlbumFolder) -> some View {
        Button("名前を変更", systemImage: "pencil") {
            onRename(folder)
        }
        Button("移動", systemImage: "arrow.right") {
            onMove(folder)
        }
        Button("ZIPで出力", systemImage: "square.and.arrow.up") {
            onExport(folder)
        }
        Divider()
        Button("削除", systemImage: "trash", role: .destructive) {
            onDelete(folder)
        }
    }

}

/// フォルダの新規作成と名前変更で共用する入力画面です。
private struct FolderNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initialName: String
    let onSave: (String) async -> Void
    @State private var name: String
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    init(title: String, initialName: String = "", onSave: @escaping (String) async -> Void) {
        self.title = title
        self.initialName = initialName
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("フォルダ名", text: $name)
                    .focused($isFocused)
                    .disabled(isSaving)
                    .onSubmit { Task { await save() } }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(
                            isSaving
                            || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }
        .frame(minHeight: 180)
        .onAppear { isFocused = true }
    }

    /// 保存完了を待ってから閉じ、初回作成時のシート終了とDB更新の競合を防ぎます。
    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving else { return }
        isFocused = false
        isSaving = true
        await onSave(trimmed)
        isSaving = false
        dismiss()
    }
}

/// フォルダ移動と写真移動で共用する、階層表示付きの移動先選択画面です。
/// 渡された配列の順番を保つため、設定画面の日付順／名前順がここにも反映されます。
struct FolderDestinationPicker: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let folders: [AlbumFolder]
    let excludedFolderIDs: Set<UUID>
    let allowsRoot: Bool
    let currentDestinationID: UUID?
    let onSelect: (UUID?) async -> Void
    @State private var isMoving = false

    /// 親子関係を表示用の1次元配列へ変換します。visitedにより、壊れた旧DBに循環があっても停止します。
    private var destinationRows: [FolderDestinationRow] {
        var rows: [FolderDestinationRow] = []
        var visited = Set<UUID>()

        func appendChildren(of parentID: UUID?, depth: Int) {
            for folder in folders where folder.parentID == parentID {
                guard !excludedFolderIDs.contains(folder.id),
                      visited.insert(folder.id).inserted else { continue }
                rows.append(FolderDestinationRow(folder: folder, depth: depth))
                appendChildren(of: folder.id, depth: depth + 1)
            }
        }

        appendChildren(of: nil, depth: 0)
        return rows
    }

    var body: some View {
        NavigationStack {
            List {
                if allowsRoot {
                    destinationButton(
                        name: "最上位（フォルダ一覧）",
                        systemImage: "tray.full",
                        destinationID: nil,
                        depth: 0
                    )
                }

                ForEach(destinationRows) { row in
                    destinationButton(
                        name: row.folder.name,
                        systemImage: "folder.fill",
                        destinationID: row.folder.id,
                        depth: row.depth
                    )
                }
            }
            .overlay {
                if destinationRows.isEmpty && !allowsRoot {
                    ContentUnavailableView(
                        "移動先がありません",
                        systemImage: "folder",
                        description: Text("先に別のフォルダを作成してください。")
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(isMoving)
                }
            }
        }
    }

    /// 現在の保存先にはチェックを表示して選択不可にし、同じ場所への不要な保存を防ぎます。
    private func destinationButton(
        name: String,
        systemImage: String,
        destinationID: UUID?,
        depth: Int
    ) -> some View {
        let isCurrentDestination = destinationID == currentDestinationID
        return Button {
            move(to: destinationID)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
                if isCurrentDestination {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(depth) * 20)
        }
        .disabled(isMoving || isCurrentDestination)
    }

    /// DB保存が完了してから画面を閉じ、移動先一覧と背後の一覧表示が競合しないようにします。
    private func move(to destinationID: UUID?) {
        guard !isMoving else { return }
        isMoving = true
        Task {
            await onSelect(destinationID)
            isMoving = false
            dismiss()
        }
    }
}

/// 移動先フォルダと、その階層の深さをまとめた表示専用データです。
private struct FolderDestinationRow: Identifiable {
    let folder: AlbumFolder
    let depth: Int
    var id: UUID { folder.id }
}
