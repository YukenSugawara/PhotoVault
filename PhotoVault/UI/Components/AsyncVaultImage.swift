import ImageIO
import SwiftUI

/// 必要な画像だけを非同期で復号し、SwiftUI Imageとして表示します。
struct AsyncVaultImage: View {
    @EnvironmentObject private var model: AppModel
    let photoID: UUID
    var thumbnail = true
    var contentMode: ContentMode = .fill

    @State private var image: PlatformImage?
    @State private var preview: PlatformImage?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var retryCount = 0

    private var requestID: String {
        "\(model.imageReloadToken)-\(photoID)-\(thumbnail)-\(retryCount)"
    }

    var body: some View {
        ZStack {
            if let displayedImage = image ?? preview {
                displayedImage.swiftUIImage
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    Rectangle().fill(.secondary.opacity(0.10))
                }
            }
            if isLoading && image == nil {
                ProgressView()
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("写真を読み込み中")
            } else if let loadError {
                if thumbnail {
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("写真を取得できません。上部の画像を再読込から再試行できます。")
                } else {
                    VStack(spacing: 8) {
                        Text(loadError).font(.caption).multilineTextAlignment(.center)
                        Button("再読み込み") { retryCount += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: 320)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        // 原画像の取得と並行して、軽量なサムネイルを先に表示します。
        .task(id: requestID + "-preview") {
            preview = nil
            guard !thumbnail,
                  let data = try? await model.loadImageData(for: photoID, thumbnail: true),
                  !Task.isCancelled else { return }
            let decoded = await PlatformImage.decode(data, maximumPixelSize: 512)
            guard !Task.isCancelled else { return }
            preview = decoded
        }
        .task(id: requestID) {
            image = nil
            loadError = nil
            isLoading = true
            for attempt in 0..<2 {
                do {
                    let data = try await model.loadImageData(for: photoID, thumbnail: thumbnail)
                    try Task.checkCancellation()
                    let maximumPixelSize = thumbnail ? 512 : PlatformImage.fullResolutionLimit
                    let decoded = await PlatformImage.decode(data, maximumPixelSize: maximumPixelSize)
                    try Task.checkCancellation()
                    guard let decoded else { throw PhotoVaultError.invalidImage }
                    image = decoded
                    isLoading = false
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if attempt == 0 && model.storageLocation == .iCloud {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    } else {
                        loadError = error.localizedDescription
                        isLoading = false
                        return
                    }
                }
            }
        }
    }
}

import UIKit

/// iOSのUIImageをSwiftUI Imageへ変換します。
private struct PlatformImage: @unchecked Sendable {
    let image: UIImage
    static let fullResolutionLimit = 3_072

    init?(data: Data, maximumPixelSize: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if CGImageSourceGetCount(source) > 1, let animatedImage = UIImage(data: data) {
            image = animatedImage
            return
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let decodedImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        image = UIImage(cgImage: decodedImage)
    }
    var swiftUIImage: Image { Image(uiImage: image) }

    /// 大きな画像の生成をメインスレッド外で行い、操作中の引っ掛かりを減らします。
    static func decode(_ data: Data, maximumPixelSize: Int) async -> PlatformImage? {
        await Task.detached(priority: .userInitiated) {
            PlatformImage(data: data, maximumPixelSize: maximumPixelSize)
        }.value
    }
}
