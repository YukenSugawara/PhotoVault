import SwiftUI

/// 1回のドラッグ中に確定した操作を保持し、ページ送り・終了・拡大画像移動の競合を防ぎます。
private enum ViewerDragMode: Equatable {
    case horizontalPage
    case verticalDismiss
    case zoomedImage
}

/// 写真を全画面表示し、拡大縮小、滑らかな左右送り、下スワイプ終了、詳細、共有を提供します。
struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let photos: [PhotoRecord]
    @State private var selectedPhotoID: UUID
    @State private var isZoomed = false
    @State private var showsShareOptions = false
    @State private var shareRequest: PhotoShareRequest?
    @State private var detailPhotoID: UUID?
    @State private var showsControls = true
    @State private var controlVisibilityTask: Task<Void, Never>?

    init(photos: [PhotoRecord], initialPhotoID: UUID) {
        self.photos = photos
        _selectedPhotoID = State(initialValue: initialPhotoID)
    }

    private var currentIndex: Int {
        photos.firstIndex { $0.id == selectedPhotoID } ?? 0
    }

    private var currentPhoto: PhotoRecord? {
        photos.indices.contains(currentIndex) ? photos[currentIndex] : nil
    }

    /// 次に表示する可能性が高い前後の写真だけを先読みします。
    private var adjacentPhotoIDs: [UUID] {
        guard !photos.isEmpty else { return [] }
        return [currentIndex - 1, currentIndex + 1]
            .filter { photos.indices.contains($0) }
            .map { photos[$0].id }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            SmoothPhotoPager(
                photos: photos,
                selection: $selectedPhotoID,
                isZoomed: $isZoomed,
                onDismiss: { dismiss() },
                onSingleTap: { showControlsTemporarily() }
            )

            controls
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)
                .animation(.easeInOut(duration: 0.22), value: showsControls)
        }
        // 現在画像を優先してから前後だけを復号し、ページ送り後の待ち時間を抑えます。
        .task(id: selectedPhotoID) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await model.preloadImageData(for: adjacentPhotoIDs, thumbnail: false)
        }
        .confirmationDialog(
            "共有方法を選択",
            isPresented: $showsShareOptions,
            titleVisibility: .visible
        ) {
            ForEach([PhotoShareMode.original, .removingMetadata]) { mode in
                Button(mode.displayName) {
                    guard let currentPhoto else { return }
                    shareRequest = PhotoShareRequest(photo: currentPhoto, mode: mode)
                }
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("元画質は保存データをそのまま共有します。プライバシー共有は位置情報・撮影日時・カメラ情報を除いたコピーを作ります。")
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
        // 表示直後は操作方法を確認できるようにし、3秒後に写真だけの表示へ切り替えます。
        .onAppear { showControlsTemporarily() }
        .onDisappear { controlVisibilityTask?.cancel() }
#if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
#endif
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                viewerButton("閉じる", systemImage: "xmark") { dismiss() }

                Spacer()

                if let currentPhoto {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(currentIndex + 1) / \(photos.count)")
                            .font(.subheadline.weight(.semibold))
                        Text(currentPhoto.displayFilename)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.58), in: Capsule())
                }

                viewerButton("詳細情報", systemImage: "info.circle") {
                    detailPhotoID = currentPhoto?.id
                }
                .disabled(currentPhoto == nil)

                viewerButton("共有", systemImage: "square.and.arrow.up") {
                    showsShareOptions = true
                }
                .disabled(currentPhoto == nil)
            }
            .foregroundStyle(.white)

            Spacer()

            Text(viewerHint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.48), in: Capsule())
                .allowsHitTesting(false)
        }
        .padding()
    }

    private var viewerHint: String {
        if isZoomed {
            return "ドラッグで移動・ピンチまたはダブルタップで縮小"
        }
        if photos.count > 1 {
            return "ピンチで拡大・左右にスワイプ・下にスワイプして閉じる"
        }
        return "ピンチで拡大・下にスワイプして閉じる"
    }

    /// 操作ボタンを表示して自動非表示タイマーを更新します。画像タップのたびに3秒へ戻ります。
    private func showControlsTemporarily() {
        controlVisibilityTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            showsControls = true
        }

        controlVisibilityTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.28)) {
                showsControls = false
            }
        }
    }

    private func viewerButton(
        _ accessibilityLabel: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.58), in: Circle())
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

/// 現在画像と前後画像だけを保持し、ページ位置へ必ず吸着する軽量ページャーです。
private struct SmoothPhotoPager: View {
    let photos: [PhotoRecord]
    @Binding var selection: UUID
    @Binding var isZoomed: Bool
    let onDismiss: () -> Void
    let onSingleTap: () -> Void

    // ドラッグ中の移動量はGestureStateに隔離し、親画面や操作ボタンを毎フレーム再描画しません。
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var gestureMagnification: CGFloat = 1
    @State private var horizontalOffset: CGFloat = 0
    @State private var verticalOffset: CGFloat = 0
    @State private var dragMode: ViewerDragMode?
    @State private var isSettling = false
    @State private var settlingTask: Task<Void, Never>?
    @State private var zoomScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var zoomPanStartOffset: CGSize = .zero

    private let maximumZoomScale: CGFloat = 4

    private var currentIndex: Int {
        photos.firstIndex { $0.id == selection } ?? 0
    }

    private var nearbyIndices: [Int] {
        [currentIndex - 1, currentIndex, currentIndex + 1]
            .filter { photos.indices.contains($0) }
    }

    private var effectiveZoomScale: CGFloat {
        min(max(zoomScale * gestureMagnification, 1), maximumZoomScale)
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.size
            let liveHorizontalOffset = displayedHorizontalOffset
            let liveVerticalOffset = displayedVerticalOffset
            let displayedZoomOffset = clampedZoomOffset(
                liveZoomOffset,
                viewport: viewport,
                scale: effectiveZoomScale
            )

            ZStack {
                ForEach(nearbyIndices, id: \.self) { index in
                    let isCurrentPage = index == currentIndex
                    AsyncVaultImage(
                        photoID: photos[index].id,
                        thumbnail: false,
                        contentMode: .fit
                    )
                    .frame(width: viewport.width, height: viewport.height)
                    .scaleEffect(isCurrentPage ? effectiveZoomScale : 1)
                    .offset(
                        x: CGFloat(index - currentIndex) * viewport.width
                            + liveHorizontalOffset
                            + (isCurrentPage ? displayedZoomOffset.width : 0),
                        y: isCurrentPage ? displayedZoomOffset.height : 0
                    )
                }
            }
            .frame(width: viewport.width, height: viewport.height)
            // 下ドラッグ時は画像レイヤーだけを動かすため、ゆっくり操作しても背景全体が点滅しません。
            .offset(y: liveVerticalOffset)
            .scaleEffect(1 - min(liveVerticalOffset / 2_500, 0.04))
            .opacity(1 - min(Double(liveVerticalOffset / 900), 0.28))
            .contentShape(Rectangle())
            .gesture(pageGesture(viewport: viewport))
            .simultaneousGesture(magnificationGesture(viewport: viewport))
            // 操作部品が消えているときも、画像を1回タップすれば再表示できます。
            .onTapGesture(count: 1, perform: onSingleTap)
            .onTapGesture(count: 2) { toggleZoom(viewport: viewport) }
            .clipped()
        }
        .onDisappear { settlingTask?.cancel() }
    }

    private var displayedHorizontalOffset: CGFloat {
        guard dragMode == .horizontalPage, !isSettling else { return horizontalOffset }
        return horizontalOffset + resistedHorizontalOffset(dragTranslation.width)
    }

    private var displayedVerticalOffset: CGFloat {
        guard dragMode == .verticalDismiss, !isSettling else { return verticalOffset }
        return verticalOffset + max(dragTranslation.height, 0)
    }

    private var liveZoomOffset: CGSize {
        guard dragMode == .zoomedImage, !isSettling else { return zoomOffset }
        return CGSize(
            width: zoomPanStartOffset.width + dragTranslation.width,
            height: zoomPanStartOffset.height + dragTranslation.height
        )
    }

    private func pageGesture(viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onChanged { value in
                guard !isSettling, dragMode == nil else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard max(abs(horizontal), abs(vertical)) >= 4 else { return }
                if effectiveZoomScale > 1.01 {
                    dragMode = .zoomedImage
                    zoomPanStartOffset = zoomOffset
                } else {
                    dragMode = abs(horizontal) > abs(vertical) * 1.08
                        ? .horizontalPage
                        : .verticalDismiss
                }
            }
            .onEnded { value in
                guard !isSettling else { return }
                let completedMode = dragMode
                dragMode = nil

                // GestureStateがゼロへ戻る前に最終位置を通常Stateへ引き継ぎ、1フレームの跳ねを防ぎます。
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    switch completedMode {
                    case .horizontalPage:
                        horizontalOffset += resistedHorizontalOffset(value.translation.width)
                    case .verticalDismiss:
                        verticalOffset += max(value.translation.height, 0)
                    case .zoomedImage:
                        zoomOffset = clampedZoomOffset(
                            CGSize(
                                width: zoomPanStartOffset.width + value.translation.width,
                                height: zoomPanStartOffset.height + value.translation.height
                            ),
                            viewport: viewport,
                            scale: effectiveZoomScale
                        )
                    case nil:
                        break
                    }
                }

                switch completedMode {
                case .horizontalPage:
                    finishHorizontalDrag(value, width: max(viewport.width, 1))
                case .verticalDismiss:
                    finishVerticalDrag(value, height: max(viewport.height, 1))
                case .zoomedImage:
                    settleZoomOffset(viewport: viewport)
                case nil:
                    resetPageOffsets()
                }
            }
    }

    private func magnificationGesture(viewport: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .updating($gestureMagnification) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                let proposedScale = min(max(zoomScale * value.magnification, 1), maximumZoomScale)
                let settledScale: CGFloat = proposedScale < 1.04 ? 1 : proposedScale
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    zoomScale = settledScale
                    zoomOffset = settledScale == 1
                        ? .zero
                        : clampedZoomOffset(zoomOffset, viewport: viewport, scale: settledScale)
                    isZoomed = settledScale > 1.01
                }
            }
    }

    /// 先頭と末尾を越えるドラッグだけに抵抗を付けます。
    private func resistedHorizontalOffset(_ proposed: CGFloat) -> CGFloat {
        guard !photos.isEmpty else { return 0 }
        let isBeyondFirst = currentIndex == photos.startIndex && proposed > 0
        let isBeyondLast = currentIndex == photos.index(before: photos.endIndex) && proposed < 0
        return isBeyondFirst || isBeyondLast ? proposed * 0.22 : proposed
    }

    private func finishHorizontalDrag(_ value: DragGesture.Value, width: CGFloat) {
        guard !photos.isEmpty else {
            resetPageOffsets()
            return
        }
        let threshold = min(max(width * 0.16, 56), 120)
        let translation = value.translation.width
        let predicted = value.predictedEndTranslation.width

        if (translation < -threshold || predicted < -width * 0.32),
           currentIndex < photos.index(before: photos.endIndex) {
            settlePage(direction: 1, width: width)
        } else if (translation > threshold || predicted > width * 0.32), currentIndex > 0 {
            settlePage(direction: -1, width: width)
        } else {
            resetPageOffsets()
        }
    }

    private func finishVerticalDrag(_ value: DragGesture.Value, height: CGFloat) {
        let predicted = value.predictedEndTranslation.height
        if verticalOffset > 105 || predicted > 185 {
            isSettling = true
            settlingTask?.cancel()
            withAnimation(.easeOut(duration: 0.18)) {
                verticalOffset = max(height * 1.05, verticalOffset)
            }
            settlingTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
                onDismiss()
            }
        } else {
            resetPageOffsets()
        }
    }

    /// 隣画像を中央まで動かした後、アニメーションなしで新ページを基準位置にします。
    private func settlePage(direction: Int, width: CGFloat) {
        let nextIndex = currentIndex + direction
        guard photos.indices.contains(nextIndex) else {
            resetPageOffsets()
            return
        }

        isSettling = true
        settlingTask?.cancel()
        withAnimation(.easeOut(duration: 0.20)) {
            horizontalOffset = direction > 0 ? -width : width
        }

        settlingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selection = photos[nextIndex].id
                horizontalOffset = 0
                verticalOffset = 0
                zoomScale = 1
                zoomOffset = .zero
                isZoomed = false
                isSettling = false
            }
        }
    }

    private func resetPageOffsets() {
        withAnimation(.spring(response: 0.27, dampingFraction: 0.9)) {
            horizontalOffset = 0
            verticalOffset = 0
        }
    }

    private func settleZoomOffset(viewport: CGSize) {
        withAnimation(.spring(response: 0.27, dampingFraction: 0.9)) {
            zoomOffset = clampedZoomOffset(zoomOffset, viewport: viewport, scale: effectiveZoomScale)
        }
    }

    /// ダブルタップでは見やすい2.5倍と等倍を切り替えます。
    private func toggleZoom(viewport: CGSize) {
        guard !isSettling else { return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
            if effectiveZoomScale > 1.01 {
                zoomScale = 1
                zoomOffset = .zero
                isZoomed = false
            } else {
                zoomScale = 2.5
                zoomOffset = .zero
                isZoomed = true
            }
        }
    }

    /// aspectFit後の画像サイズを基に、拡大画像の外側へ空白が出ない範囲へ移動量を制限します。
    private func clampedZoomOffset(_ proposed: CGSize, viewport: CGSize, scale: CGFloat) -> CGSize {
        guard photos.indices.contains(currentIndex), scale > 1 else { return .zero }
        let photo = photos[currentIndex]
        let sourceSize = CGSize(
            width: max(CGFloat(photo.pixelWidth), 1),
            height: max(CGFloat(photo.pixelHeight), 1)
        )
        let fitRatio = min(viewport.width / sourceSize.width, viewport.height / sourceSize.height)
        let fittedSize = CGSize(width: sourceSize.width * fitRatio, height: sourceSize.height * fitRatio)
        let maximumX = max(0, (fittedSize.width * scale - viewport.width) / 2)
        let maximumY = max(0, (fittedSize.height * scale - viewport.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY)
        )
    }
}
