import SwiftUI

/// 写真を4秒間隔で自動送りし、手動操作にも対応するスライドショーです。
struct SlideshowView: View {
    @Environment(\.dismiss) private var dismiss
    let photos: [PhotoRecord]
    @State private var index = 0
    @State private var isPlaying = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !photos.isEmpty {
                AsyncVaultImage(
                    photoID: photos[index].id,
                    thumbnail: false,
                    contentMode: .fit
                )
                .id(photos[index].id)
                .transition(.opacity)
                .padding(24)
            }

            VStack {
                HStack {
                    Button("閉じる") { dismiss() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Text("\(min(index + 1, photos.count)) / \(photos.count)")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                Spacer()
                HStack(spacing: 24) {
                    Button { move(by: -1) } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button { isPlaying.toggle() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button { move(by: 1) } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .font(.title2)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        // 画面が閉じられるとTaskもキャンセルされ、自動再生ループを終了します。
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard isPlaying, !photos.isEmpty else { continue }
                withAnimation(.easeInOut(duration: 0.45)) { move(by: 1) }
            }
        }
    }

    private func move(by offset: Int) {
        guard !photos.isEmpty else { return }
        index = (index + offset + photos.count) % photos.count
    }
}
