import SwiftUI

/// 生体認証またはPINなし起動後に、開くアルバムを選択する画面です。
struct VaultSelectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(model.theme.tint)
                Text(model.selectionWasBiometric ? "本人確認が完了しました" : "アルバムを選択")
                    .font(.title.bold())
                Text("開くアルバムを選択してください")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                ForEach(model.availableVaultKinds) { kind in
                    Button {
                        Task { await model.selectVault(kind) }
                    } label: {
                        VStack(spacing: 14) {
                            Image(systemName: kind.symbolName)
                                .font(.system(size: 38))
                            Text(kind.displayName)
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 130)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 560)

            if model.canCancelVaultSelection {
                Button("キャンセル", role: .cancel) {
                    model.cancelVaultSelection()
                }
            }
        }
        .padding(28)
    }
}
