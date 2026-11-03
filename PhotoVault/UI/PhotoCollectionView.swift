import Foundation
import SwiftUI

/// 実フォルダ内の写真を、設定された一覧形式で表示します。
struct PhotoCollectionView: View {
    @EnvironmentObject private var model: AppModel
    let folder: AlbumFolder
    let onRenameFolder: (AlbumFolder) -> Void
    let onMoveFolder: (AlbumFolder) -> Void
    let onExportFolder: (AlbumFolder) -> Void
    let onDeleteFolder: (AlbumFolder) -> Void

    var body: some View {
        PhotoBrowserView(
            title: folder.name,
            photos: model.database.photos(in: folder.id),
            folderID: folder.id,
            subfolders: model.database.childFolders(of: folder.id),
            onRenameFolder: onRenameFolder,
            onMoveFolder: onMoveFolder,
            onExportFolder: onExportFolder,
            onDeleteFolder: onDeleteFolder
        )
    }
}

/// スマートフォルダ条件に一致する写真を、実フォルダと同じ操作感で表示します。
struct SmartPhotoCollectionView: View {
    @EnvironmentObject private var model: AppModel
    let filter: SmartFolderFilter

    var body: some View {
        PhotoBrowserView(
            title: filter.displayName,
            photos: model.database.photos(matching: filter),
            folderID: nil
        )
    }
}

/// 年／月、画像形式、容量から動的に作られる仮想フォルダの一覧です。
struct SmartFoldersView: View {
    @EnvironmentObject private var model: AppModel

    private var years: [SmartFolderFilter] {
        let calendar = Calendar.current
        return Set(model.database.photos.map {
            SmartFolderFilter.year(calendar.component(.year, from: $0.effectiveCaptureDate))
        }).sorted { $0.displayName > $1.displayName }
    }

    private var months: [SmartFolderFilter] {
        let calendar = Calendar.current
        return Set(model.database.photos.map { photo in
            let values = calendar.dateComponents([.year, .month], from: photo.effectiveCaptureDate)
            return SmartFolderFilter.month(year: values.year ?? 0, month: values.month ?? 0)
        }).sorted { first, second in
            guard case .month(let firstYear, let firstMonth) = first,
                  case .month(let secondYear, let secondMonth) = second else { return false }
            return firstYear == secondYear ? firstMonth > secondMonth : firstYear > secondYear
        }
    }

    private var formats: [SmartFolderFilter] {
        Set(model.database.photos.map { SmartFolderFilter.format($0.contentTypeIdentifier) })
            .sorted { $0.displayName < $1.displayName }
    }

    private var sizes: [SmartFolderFilter] {
        PhotoSizeCategory.allCases
            .map(SmartFolderFilter.size)
            .filter { !model.database.photos(matching: $0).isEmpty }
    }

    var body: some View {
        List {
            smartSection("年", filters: years)
            smartSection("月", filters: months)
            smartSection("画像形式", filters: formats)
            smartSection("容量", filters: sizes)
        }
        .overlay {
            if model.database.photos.isEmpty {
                ContentUnavailableView(
                    "写真がありません",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("写真を追加すると条件別に自動整理されます。")
                )
            }
        }
        .navigationTitle("スマートフォルダ")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        // 旧DBの写真も撮影日時へ分類できるよう、未解析分をバックグラウンド索引へ送ります。
        .task { model.indexAllPhotosForOCR() }
    }

    @ViewBuilder
    private func smartSection(_ title: String, filters: [SmartFolderFilter]) -> some View {
        if !filters.isEmpty {
            Section(title) {
                ForEach(filters, id: \.self) { filter in
                    NavigationLink(value: MainRoute.smartFolder(filter)) {
                        HStack(spacing: 12) {
                            Image(systemName: filter.symbolName)
                                .foregroundStyle(model.theme.tint)
                                .frame(width: 30)
                            Text(filter.displayName)
                            Spacer()
                            Text("\(model.database.photos(matching: filter).count)枚")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Visionで保存したOCR文字列を検索し、そのまま全画面表示・共有へ進める画面です。
struct OCRSearchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    private var results: [PhotoRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return model.database.photos(in: nil).filter { photo in
            photo.ocrText?.localizedCaseInsensitiveContains(trimmed) == true
                || photo.displayFilename.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("画像内の文字を検索", systemImage: "text.viewfinder")
                } description: {
                    Text("画像から認識した日本語・英語の文字を検索できます。")
                }
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                PhotoBrowserView(title: "OCR検索", photos: results, folderID: nil)
            }
        }
        .searchable(text: $query, prompt: "画像内の文字")
        .navigationTitle("OCR検索")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .safeAreaInset(edge: .top) {
            if model.isOCRIndexing {
                VStack(spacing: 4) {
                    ProgressView(value: model.ocrIndexProgress)
                    Text("既存写真の文字を解析しています…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.regularMaterial)
            }
        }
        .task { model.indexAllPhotosForOCR() }
    }
}

/// 実フォルダ、スマートフォルダ、OCR結果で共用する写真ブラウザです。
private struct PhotoBrowserView: View {
    @EnvironmentObject private var model: AppModel
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    let title: String
    let photos: [PhotoRecord]
    let folderID: UUID?
    let subfolders: [AlbumFolder]
    let onRenameFolder: ((AlbumFolder) -> Void)?
    let onMoveFolder: ((AlbumFolder) -> Void)?
    let onExportFolder: ((AlbumFolder) -> Void)?
    let onDeleteFolder: ((AlbumFolder) -> Void)?
    @State private var selectedPhoto: PhotoRecord?
    @State private var showsSlideshow = false
    @State private var photoToMove: PhotoRecord?
    @State private var photoToDelete: PhotoRecord?
    @State private var detailPhotoID: UUID?
    @State private var shareRequest: PhotoShareRequest?

    init(
        title: String,
        photos: [PhotoRecord],
        folderID: UUID?,
        subfolders: [AlbumFolder] = [],
        onRenameFolder: ((AlbumFolder) -> Void)? = nil,
        onMoveFolder: ((AlbumFolder) -> Void)? = nil,
        onExportFolder: ((AlbumFolder) -> Void)? = nil,
        onDeleteFolder: ((AlbumFolder) -> Void)? = nil
    ) {
        self.title = title
        self.photos = photos
        self.folderID = folderID
        self.subfolders = subfolders
        self.onRenameFolder = onRenameFolder
        self.onMoveFolder = onMoveFolder
        self.onExportFolder = onExportFolder
        self.onDeleteFolder = onDeleteFolder
    }

    private var featuredPhotoID: UUID? {
        guard let folderID else { return nil }
        return model.database.folderFeaturedPhotoIDs?[folderID]
    }

    var body: some View {
        Group {
            if photos.isEmpty && subfolders.isEmpty {
                ContentUnavailableView(
                    folderID == nil ? "写真がありません" : "フォルダが空です",
                    systemImage: folderID == nil ? "photo.on.rectangle.angled" : "folder",
                    description: Text(folderID == nil ? "この条件に一致する写真はありません。" : "右上の＋からサブフォルダまたは写真を追加できます。")
                )
            } else {
                ScrollView {
                    if !subfolders.isEmpty {
                        subfolderGrid
                    }

                    if !photos.isEmpty {
                        switch model.database.albumLayout {
                        case .comfortableGrid:
                            photoGrid(columnCount: comfortableColumnCount, spacing: 6)
                        case .compactGrid:
                            photoGrid(columnCount: compactColumnCount, spacing: 3)
                        case .list:
                            photoList
                        }
                    }
                }
            }
        }
        .background(model.theme.tint.opacity(0.035))
        .navigationTitle(title)
        .toolbar {
            if model.database.effectiveSlideshowEnabled && photos.count > 1 {
                ToolbarItem {
                    Button {
                        showsSlideshow = true
                    } label: {
                        Label("スライドショー", systemImage: "play.rectangle.fill")
                    }
                }
            }
        }
        // iPhone・iPadでは写真を端末いっぱいに表示します。
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoViewer(photos: photos, initialPhotoID: photo.id)
        }
        .sheet(isPresented: $showsSlideshow) {
            SlideshowView(photos: photos)
        }
        .sheet(item: $photoToMove) { photo in
            FolderDestinationPicker(
                title: "写真の移動先",
                folders: model.database.sortedFolders,
                excludedFolderIDs: [],
                allowsRoot: false,
                currentDestinationID: photo.folderID
            ) { destinationID in
                guard let destinationID else { return }
                await model.movePhoto(id: photo.id, toFolderID: destinationID)
            }
        }
        .sheet(isPresented: Binding(
            get: { detailPhotoID != nil },
            set: { if !$0 { detailPhotoID = nil } }
        )) {
            if let detailPhotoID {
                PhotoDetailView(photoID: detailPhotoID)
            }
        }
        .photoSharing(request: $shareRequest)
        .confirmationDialog(
            "この写真をゴミ箱へ移動しますか？",
            isPresented: Binding(
                get: { photoToDelete != nil },
                set: { if !$0 { photoToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("ゴミ箱へ移動", role: .destructive) {
                guard let photo = photoToDelete else { return }
                photoToDelete = nil
                Task { await model.deletePhoto(id: photo.id) }
            }
            Button("キャンセル", role: .cancel) { photoToDelete = nil }
        }
    }

    /// 通常グリッドはiPhoneで4列、iPadで6列にします。
    private var comfortableColumnCount: Int {
        horizontalSizeClass == .compact ? 4 : 6
    }

    private var compactColumnCount: Int {
        horizontalSizeClass == .compact ? 6 : 8
    }

    /// 現在のフォルダ直下にあるサブフォルダを、最上位と同じコンパクトなカードで表示します。
    private var subfolderGrid: some View {
        let photoCounts = model.database.photoCountsByFolderTree
        let featuredPhotos = model.database.featuredPhotosByFolder

        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96, maximum: 132), spacing: 8)],
            spacing: 8
        ) {
            ForEach(subfolders) { folder in
                ZStack(alignment: .topTrailing) {
                    NavigationLink(value: MainRoute.folder(folder.id)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay { subfolderArtwork(folder, featuredPhotos: featuredPhotos) }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
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
                    .contextMenu { subfolderMenu(folder) }

                    Menu {
                        subfolderMenu(folder)
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
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func subfolderArtwork(
        _ folder: AlbumFolder,
        featuredPhotos: [UUID: PhotoRecord]
    ) -> some View {
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

    /// サブフォルダも最上位フォルダと同じ管理操作を利用します。
    @ViewBuilder
    private func subfolderMenu(_ folder: AlbumFolder) -> some View {
        if let onRenameFolder {
            Button("名前を変更", systemImage: "pencil") { onRenameFolder(folder) }
        }
        if let onMoveFolder {
            Button("移動", systemImage: "arrow.right") { onMoveFolder(folder) }
        }
        if let onExportFolder {
            Button("ZIPで出力", systemImage: "square.and.arrow.up") { onExportFolder(folder) }
        }
        if onDeleteFolder != nil { Divider() }
        if let onDeleteFolder {
            Button("削除", systemImage: "trash", role: .destructive) { onDeleteFolder(folder) }
        }
    }

    private func photoGrid(columnCount: Int, spacing: CGFloat) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: spacing), count: columnCount),
            spacing: spacing
        ) {
            ForEach(photos) { photo in
                photoTile(photo, isFeatured: featuredPhotoID == photo.id)
            }
        }
        .padding()
    }

    private var photoList: some View {
        LazyVStack(spacing: 8) {
            ForEach(photos) { photo in
                Button { selectedPhoto = photo } label: {
                    HStack(spacing: 14) {
                        AsyncVaultImage(photoID: photo.id)
                            .frame(width: 76, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(photo.displayFilename).font(.headline).lineLimit(1)
                            Text(photo.effectiveCaptureDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: photo.originalByteCount, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .contextMenu { photoMenu(photo) }
            }
        }
        .padding()
    }

    private func photoTile(_ photo: PhotoRecord, isFeatured: Bool) -> some View {
        Button { selectedPhoto = photo } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    AsyncVaultImage(photoID: photo.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if isFeatured {
                        Image(systemName: "star.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, model.theme.tint)
                            .font(.title2)
                            .padding(7)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu { photoMenu(photo) }
    }

    /// 長押し／右クリックには、共有方法の選択、詳細、既存の管理操作をまとめます。
    @ViewBuilder
    private func photoMenu(_ photo: PhotoRecord) -> some View {
        Menu("共有", systemImage: "square.and.arrow.up") {
            ForEach([PhotoShareMode.original, .removingMetadata]) { mode in
                Button(mode.displayName, systemImage: mode.symbolName) {
                    shareRequest = PhotoShareRequest(photo: photo, mode: mode)
                }
            }
        }
        Button("詳細情報", systemImage: "info.circle") {
            detailPhotoID = photo.id
        }
        Button("別のフォルダへ移動", systemImage: "arrow.right") {
            photoToMove = photo
        }
        if let folderID {
            Button("フォルダ画像に設定", systemImage: "star.fill") {
                Task { await model.setFeaturedPhoto(id: photo.id, folderID: folderID) }
            }
        }
        Divider()
        Button("削除", systemImage: "trash", role: .destructive) {
            photoToDelete = photo
        }
    }
}

/// ユーザーが必要とする基本ファイル情報と主要なカメラ情報だけを簡潔に表示します。
struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let photoID: UUID

    private var photo: PhotoRecord? {
        model.database.photos.first { $0.id == photoID }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let photo {
                    Section("ファイル") {
                        LabeledContent("名前", value: photo.displayFilename)
                        LabeledContent("形式", value: photo.displayFormat)
                        LabeledContent("解像度", value: "\(photo.pixelWidth) × \(photo.pixelHeight) px")
                        LabeledContent(
                            "容量",
                            value: ByteCountFormatter.string(fromByteCount: photo.originalByteCount, countStyle: .file)
                        )
                        LabeledContent(
                            "撮影日時",
                            value: photo.capturedAt?.formatted(date: .long, time: .standard) ?? "情報なし"
                        )
                    }

                    Section("カメラ") {
                        detailRow("メーカー／機種", value: photo.cameraDescription)
                        detailRow("ISO", value: photo.isoSpeed.map { String($0) })
                    }
                } else {
                    ContentUnavailableView("写真がありません", systemImage: "photo")
                }
            }
            .navigationTitle("写真の詳細")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func detailRow(_ title: String, value: String?) -> some View {
        if let value {
            LabeledContent(title, value: value)
        } else {
            LabeledContent(title, value: "情報なし")
                .foregroundStyle(.secondary)
        }
    }
}
