import SwiftUI

/// iPhoneのパスコード入力に近い数字キーでアルバムを開く画面です。
struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var showsInvalidPassword = false
    @State private var invalidPasswordSequence = 0
    @State private var now = Date()
    @FocusState private var legacyPasswordFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                loginContent.frame(minHeight: geometry.size.height)
            }
        }
    }

    private var loginContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.theme.tint)

            if model.legacyCredentialMode {
                legacyLogin
            } else if model.passwordEnabled {
                passcodeLogin
            } else {
                biometricOnlyLogin
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            legacyPasswordFocused = model.legacyCredentialMode
        }
        .task {
            model.refreshPINWaitState()
            while !Task.isCancelled {
                now = .now
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .task(id: password) {
            let candidate = password
            guard !candidate.isEmpty, !isInputLocked,
                  model.legacyCredentialMode || candidate.count >= 4 else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            // 前の入力の照合が終わるまで待ち、最後に入力された値を取りこぼしません。
            while model.isAutomaticallyCheckingCredential {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard !Task.isCancelled, password == candidate, !isInputLocked else { return }
            await model.unlock(credential: candidate, automatically: true)
        }
        .onChange(of: model.authenticationFailureCount) { _, _ in
            displayInvalidPassword()
        }
    }

    private var passcodeLogin: some View {
        VStack(spacing: 22) {
            VStack(spacing: 7) {
                Text("パスコードを入力")
                    .font(.title2.bold())
                Text("PINが一致すると自動で開きます")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            PINIndicatorView(digitCount: password.count, tint: model.theme.tint)

            invalidPasswordMessage

            // PIN設定画面と共通の数字キーパッドを使い、入力感を揃えます。
            NumericPINKeypad(
                value: $password,
                tint: model.theme.tint,
                isDisabled: isInputLocked,
                leadingSystemImage: model.biometricsEnabled ? model.biometrySymbolName : nil,
                leadingAccessibilityLabel: "\(model.biometryName)で開く",
                onLeadingAction: model.biometricsEnabled ? { authenticateBiometrics() } : nil
            )
            Button("開く") { submitLegacyPassword() }
                .buttonStyle(.borderedProminent)
                .disabled(password.count < 4 || isInputLocked || model.isWorking)
            pinWaitMessage
        }
    }

    private var legacyLogin: some View {
        VStack(spacing: 16) {
            Text(model.isRecoveringFromICloud ? "iCloudのアルバムを復元"
                 : (model.hasConfirmedRecoveredCredential ? "パスワードを入力" : "以前のパスワードを入力"))
                .font(.title2.bold())
            Text(model.isRecoveringFromICloud
                ? "以前設定したPINまたはパスワードを入力してください。認証後、iCloudから写真を読み込みます。"
                : (model.hasConfirmedRecoveredCredential
                   ? "PIN・パスワードが一致すると自動で開きます。"
                   : "ログイン後、設定から4〜6桁の数字PINへ変更してください"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField(model.isRecoveringFromICloud ? "以前のPIN／パスワード"
                        : (model.hasConfirmedRecoveredCredential ? "PIN／パスワード" : "以前のパスワード"), text: $password)
                .focused($legacyPasswordFocused)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitLegacyPassword() }
                .disabled(isInputLocked)

            invalidPasswordMessage
            pinWaitMessage

            Button("開く") { submitLegacyPassword() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(password.isEmpty || isInputLocked || model.isWorking)

            if model.biometricsEnabled {
                biometricButton
            }
        }
        .padding(22)
        .frame(maxWidth: 430)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var biometricOnlyLogin: some View {
        VStack(spacing: 18) {
            Text("本人確認")
                .font(.title2.bold())
            biometricButton
        }
    }

    private var biometricButton: some View {
        Button {
            authenticateBiometrics()
        } label: {
            Label("\(model.biometryName)で開く", systemImage: biometricSymbol)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isInputLocked)
    }

    private var biometricSymbol: String {
        model.biometrySymbolName
    }

    private var invalidPasswordMessage: some View {
        Text("PINが違います")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
            .opacity(showsInvalidPassword ? 1 : 0)
            .frame(height: 16)
            .accessibilityHidden(!showsInvalidPassword)
    }

    private var isInputLocked: Bool {
        isSubmitting || (model.isWorking && !model.isAutomaticallyCheckingCredential)
            || remainingSeconds > 0 || model.pinStateUnavailable
    }

    private var remainingSeconds: Int {
        max(0, Int(ceil((model.pinBlockedUntil ?? .distantPast).timeIntervalSince(now))))
    }

    @ViewBuilder private var pinWaitMessage: some View {
        if remainingSeconds > 0 {
            Text("入力を一時停止しています。あと\(remainingSeconds)秒お待ちください。")
                .font(.footnote).foregroundStyle(.orange)
        }
        if model.pinStateUnavailable {
            Text("入力制限の状態を確認できません。端末のロック解除後に再確認してください。")
                .font(.footnote)
            Button("再確認") { model.refreshPINWaitState() }
        }
    }

    /// PIN不一致をポップアップではなく画面内へ短時間だけ表示します。
    private func displayInvalidPassword() {
        invalidPasswordSequence += 1
        let sequence = invalidPasswordSequence
        withAnimation(.easeInOut(duration: 0.15)) {
            showsInvalidPassword = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard invalidPasswordSequence == sequence else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                showsInvalidPassword = false
            }
        }
    }

    private func submitLegacyPassword() {
        guard !password.isEmpty, !isInputLocked, !model.isWorking else { return }
        legacyPasswordFocused = false
        let submitted = password
        password = ""
        isSubmitting = true
        Task {
            await model.unlock(credential: submitted)
            isSubmitting = false
        }
    }

    private func authenticateBiometrics() {
        guard !isInputLocked, !model.isWorking else { return }
        isSubmitting = true
        Task {
            await model.authenticateWithBiometrics()
            isSubmitting = false
        }
    }
}
