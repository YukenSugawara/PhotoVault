import SwiftUI

/// 長押しメニューや全画面ビューアから共通して発行する共有要求です。
struct PhotoShareRequest: Identifiable {
    let id = UUID()
    let photo: PhotoRecord
    let mode: PhotoShareMode
}

/// 復号済み一時ファイルと共有方式を、共有シートが閉じるまで保持します。
private struct PreparedPhotoShare: Identifiable {
    let id = UUID()
    let url: URL
    let filename: String
    let mode: PhotoShareMode
}

/// 共有要求を受けて一時ファイルを準備し、OS標準の共有画面と安全な後片付けを提供します。
private struct PhotoSharingModifier: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Binding var request: PhotoShareRequest?
    @State private var preparedShare: PreparedPhotoShare?
    @State private var shareURLToRemove: URL?
    @State private var preparationTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) { _, _ in
                guard let request else { return }
                prepare(request)
            }
            .sheet(item: $preparedShare, onDismiss: removeTemporaryFile) { item in
                SystemPhotoShareView(
                    url: item.url,
                    filename: item.filename,
                    mode: item.mode
                ) {
                    preparedShare = nil
                }
            }
            .onDisappear {
                preparationTask?.cancel()
                removeTemporaryFile()
            }
    }

    private func prepare(_ request: PhotoShareRequest) {
        preparationTask?.cancel()
        preparationTask = Task { @MainActor in
            guard let url = await model.makeTemporaryShareFile(
                for: request.photo,
                mode: request.mode
            ) else {
                self.request = nil
                return
            }
            guard !Task.isCancelled else {
                model.removeTemporaryShareFile(at: url)
                return
            }
            if let previousURL = shareURLToRemove {
                model.removeTemporaryShareFile(at: previousURL)
            }
            shareURLToRemove = url
            preparedShare = PreparedPhotoShare(
                url: url,
                filename: url.lastPathComponent,
                mode: request.mode
            )
            self.request = nil
        }
    }

    private func removeTemporaryFile() {
        guard let url = shareURLToRemove else { return }
        shareURLToRemove = nil
        model.removeTemporaryShareFile(at: url)
    }
}

extension View {
    /// 共有処理を各画面で重複実装せずに利用するための共通モディファイアです。
    func photoSharing(request: Binding<PhotoShareRequest?>) -> some View {
        modifier(PhotoSharingModifier(request: request))
    }
}

import UIKit

/// iPhone／iPadではファイルURLをUIActivityViewControllerへ直接渡します。
private struct SystemPhotoShareView: UIViewControllerRepresentable {
    let url: URL
    let filename: String
    let mode: PhotoShareMode
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async { coordinator.onComplete() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    final class Coordinator {
        let onComplete: () -> Void

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }
    }
}
