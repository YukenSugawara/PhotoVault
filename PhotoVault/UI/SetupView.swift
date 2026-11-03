import SwiftUI

/// 初回起動時に保存先とメインアルバムのPINを設定する画面です。
struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedStorage: StorageLocation = .local
    @State private var usesPIN = true
    @State private var mainPIN = ""
    @State private var currentPINInput = ""
    @State private var pinStep: PINStep = .newPIN
    @State private var validationMessage = ""

    private enum PINStep: Equatable {
        case newPIN
        case confirmation
    }

    var body: some View {
        GeometryReader { geometry in
            // 縦画面は高さに応じて自動縮小し、横画面は説明とキーパッドを左右に分けます。
            // 保存先の説明が小さな画面でも欠けないようスクロールを許可します。
            let isLandscape = geometry.size.width > geometry.size.height
            let isCompact = geometry.size.height < 740

            ScrollView {
                if isLandscape {
                    landscapeLayout
                } else {
                    portraitLayout(compact: isCompact)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: usesPIN) { _, _ in
            // PINの使用有無を切り替えた場合は、途中まで入力した値を持ち越しません。
            mainPIN = ""
            currentPINInput = ""
            pinStep = .newPIN
            validationMessage = ""
        }
    }

    /// 縦画面では高さが小さい端末だけ、余白とキーを縮めて全項目を収めます。
    private func portraitLayout(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 14) {
            welcomeHeader(compact: compact)
            storagePicker
            pinUsageToggle(compact: compact)

            if usesPIN {
                initialPINKeypad(compact: compact)
            } else {
                Spacer(minLength: compact ? 6 : 18)
                createAlbumButton(pin: "")
                Spacer(minLength: compact ? 6 : 18)
            }

            securityNote(compact: compact)
            recoveryButton(compact: compact)
        }
        .padding(.horizontal, compact ? 16 : 24)
        .padding(.vertical, compact ? 8 : 16)
        .frame(maxWidth: 600, maxHeight: .infinity)
    }

    /// 横画面では上下方向を節約するため、案内と入力欄を左右へ配置します。
    private var landscapeLayout: some View {
        HStack(spacing: 18) {
            VStack(spacing: 12) {
                welcomeHeader(compact: true)
                storagePicker
                pinUsageToggle(compact: true)
                if !usesPIN {
                    createAlbumButton(pin: "")
                }
                securityNote(compact: true)
                recoveryButton(compact: true)
            }
            .frame(maxWidth: 300)

            if usesPIN {
                landscapePINKeypad
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: 920, maxHeight: .infinity)
    }

    private func welcomeHeader(compact: Bool) -> some View {
        VStack(spacing: compact ? 3 : 6) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: compact ? 34 : 46))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.theme.tint)

            Text("ようこそ")
                .font(compact ? .title2.bold() : .title.bold())
            Text("写真を安全に暗号化して、アルバムごとに管理します。")
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }

    private var storagePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("写真の保存先").font(.subheadline.bold())
            Picker("写真の保存先", selection: $selectedStorage) {
                Text("端末保存").tag(StorageLocation.local)
                Text("iCloud保存").tag(StorageLocation.iCloud)
                    .disabled(!model.isICloudAvailableInThisBuild)
            }
            .pickerStyle(.segmented)
            if model.isLocalRestartMode {
                Text("初期化後は端末保存専用です。以前のiCloudデータは変更しません。").font(.caption)
            }
            Text(selectedStorage == .local
                 ? "この端末に保存します。保存先は後から設定で変更できます。"
                 : "自分のApple AccountのiCloudに保存します。以前のアルバムがある場合は、下の復元を選んでください。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pinUsageToggle(compact: Bool) -> some View {
        Toggle("起動時に数字PINを使用", isOn: $usesPIN)
            .font(compact ? .subheadline : .body)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 8 : 11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: compact ? 14 : 18))
    }

    /// 初回PINもログイン画面と同じ丸表示・数字配列で入力します。
    private func initialPINKeypad(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 10) {
            Label("メインアルバム", systemImage: VaultKind.main.symbolName)
                .font(.headline)

            VStack(spacing: 2) {
                Text(pinStep == .newPIN ? "新しいPINを入力" : "PINをもう一度入力")
                    .font(compact ? .headline : .title3.bold())
                Text(pinStep == .newPIN ? "4〜6桁の数字で設定してください" : "確認のため同じPINを入力してください")
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            PINIndicatorView(digitCount: currentPINInput.count, tint: model.theme.tint)

            Text(validationMessage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .frame(height: 16)

            NumericPINKeypad(
                value: $currentPINInput,
                tint: model.theme.tint,
                keyDiameter: compact ? 48 : 58,
                rowSpacing: compact ? 5 : 8,
                columnSpacing: compact ? 16 : 18,
                onValueChange: { _ in validationMessage = "" }
            )

            pinProgressButton
        }
        .padding(compact ? 10 : 15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: compact ? 15 : 18))
    }

    /// 横画面専用では、PINの案内と数字キーを横並びにして高さを抑えます。
    private var landscapePINKeypad: some View {
        HStack(spacing: 18) {
            VStack(spacing: 9) {
                Label("メインアルバム", systemImage: VaultKind.main.symbolName)
                    .font(.headline)
                Text(pinStep == .newPIN ? "新しいPINを入力" : "PINをもう一度入力")
                    .font(.headline)
                Text(pinStep == .newPIN ? "4〜6桁で設定" : "同じPINを再入力")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PINIndicatorView(digitCount: currentPINInput.count, tint: model.theme.tint)
                Text(validationMessage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(height: 14)
                pinProgressButton
            }
            .frame(width: 220)

            NumericPINKeypad(
                value: $currentPINInput,
                tint: model.theme.tint,
                keyDiameter: 44,
                rowSpacing: 5,
                columnSpacing: 13,
                onValueChange: { _ in validationMessage = "" }
            )
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var pinProgressButton: some View {
        if pinStep == .newPIN {
            Button("次へ") { moveToPINConfirmation() }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid(currentPINInput))
        } else {
            Button("アルバムを作成") { confirmPINAndCreateAlbum() }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid(currentPINInput))
        }
    }

    private func securityNote(compact: Bool) -> some View {
        Label(
            usesPIN
                ? "PINを忘れると、このアルバムを開けません。"
                : "PINを使わない場合も、写真と管理DBは暗号化されます。",
            systemImage: usesPIN ? "exclamationmark.triangle.fill" : "lock.shield.fill"
        )
        .font(compact ? .caption2 : .footnote)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
    }

    /// 再インストール時は新しい鍵を作らず、既存の同期済み認証情報を先に探します。
    private func recoveryButton(compact: Bool) -> some View {
        VStack(spacing: 8) {
            if model.isRecoveringCredentials {
                ProgressView("iCloudの復元情報を確認中…")
                Button("確認をキャンセル") { model.cancelCredentialRecovery() }
            } else {
                Button {
                    Task { await model.recoverExistingICloudVault() }
                } label: {
                    Label("既存のiCloudアルバムを復元", systemImage: "icloud.and.arrow.down")
                }
            }
        }
        .buttonStyle(.bordered)
        .disabled(model.isLocalRestartMode)
        .controlSize(compact ? .mini : .small)
        .font(compact ? .caption2 : .caption)
    }

    private func isValid(_ pin: String) -> Bool {
        (4...6).contains(pin.count)
            && pin.allSatisfy { $0.isASCII && $0.wholeNumberValue != nil }
    }

    private func moveToPINConfirmation() {
        guard isValid(currentPINInput) else { return }
        mainPIN = currentPINInput
        currentPINInput = ""
        validationMessage = ""
        withAnimation(.easeInOut(duration: 0.18)) {
            pinStep = .confirmation
        }
    }

    /// 確認入力が一致した場合だけ、暗号化領域の初期作成を開始します。
    private func confirmPINAndCreateAlbum() {
        guard currentPINInput == mainPIN else {
            validationMessage = "PINが一致しません。もう一度入力してください。"
            currentPINInput = ""
            return
        }
        createAlbum(using: mainPIN)
    }

    private func createAlbumButton(pin: String) -> some View {
        Button {
            createAlbum(using: pin)
        } label: {
            Text("アルバムを作成")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func createAlbum(using pin: String) {
        Task {
            await model.setup(
                passwordEnabled: usesPIN,
                mainPIN: pin,
                initialStorage: selectedStorage
            )
        }
    }
}

/// PIN入力を半角数字だけの最大6桁へ整えます。
extension View {
    @ViewBuilder
    func numericPINInput(_ text: Binding<String>) -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
            .textContentType(.newPassword)
            .onChange(of: text.wrappedValue) { _, newValue in
                text.wrappedValue = String(
                    newValue.filter { $0.isASCII && $0.wholeNumberValue != nil }.prefix(6)
                )
            }
        #else
        onChange(of: text.wrappedValue) { _, newValue in
            text.wrappedValue = String(
                newValue.filter { $0.isASCII && $0.wholeNumberValue != nil }.prefix(6)
            )
        }
        #endif
    }
}
