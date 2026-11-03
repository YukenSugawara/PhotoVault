import SwiftUI

/// AppModelの認証状態に応じて、初期設定・ログイン・アルバム画面を切り替えます。
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var reconnectionPassword = ""
    @State private var restartConfirmation = ""
    @State private var completeResetConfirmation = ""
    @State private var acknowledgesCloudDeletion = false

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()

            // 認証前の画面と写真画面が同時に存在しないよう、状態ごとに入れ替えます。
            if let issue = model.iCloudAccountIssue {
                ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "icloud.slash").font(.largeTitle)
                    Text(issue).multilineTextAlignment(.center)
                    SecureField("以前のPIN／パスワード", text: $reconnectionPassword)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保管庫を確認して再接続") {
                        let credential = reconnectionPassword
                        reconnectionPassword = ""
                        Task { await model.reconnectICloudAccount(credential: credential) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(reconnectionPassword.isEmpty || model.isWorking)
                    Button("設定を初期化して新しく始める", role: .destructive) {
                        model.showsLocalRestartConfirmation = true
                    }.disabled(model.isWorking)
                    Button("再確認") { model.refreshICloudAccount() }
                        .disabled(model.isWorking)
                }.padding().frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                }
            } else {
            switch model.lockState {
            case .needsSetup:
                SetupView()
            case .locked:
                LoginView()
            case .choosingVault:
                VaultSelectionView()
            case .unlocking:
                VStack(spacing: 14) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(model.theme.tint)
                    ProgressView("アルバムを開いています…")
                }
                .task { await model.unlockAutomatically() }
            case .unlocked:
                MainSplitView()
            }

            }

            if model.isWorking && !model.isAutomaticallyCheckingCredential {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                ProgressView()
                    .controlSize(.large)
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .sheet(isPresented: $model.showsLocalRestartConfirmation) {
            NavigationStack {
                Form {
                    Section {
                        Text("以前の写真と認証情報は削除せず、別の端末アルバムを作るための初期設定へ戻ります。")
                        Text("初期化後は端末保存専用です。以前のアルバムは新しい画面には表示されず、自動で復元・統合されません。新しく保存した写真はバックアップを書き出してください。")
                        TextField("確認のため「初期化」と入力", text: $restartConfirmation)
                    }
                    Button("初期化して端末保存で始める", role: .destructive) {
                        reconnectionPassword = ""
                        model.restartLocally()
                    }.disabled(restartConfirmation != "初期化" || model.isWorking)
                    Section("最終手段：iCloudも含めて完全削除") {
                        Text("現在サインインしているApple Accountの、このアプリのメイン・サブアルバムをiCloudから削除します。同じアカウントの他の端末にも削除が反映されます。")
                        Text("この端末の写真・退避したアルバム・復元用の鍵も削除します。元に戻せません。Appleの写真ライブラリや、ほかのアプリのiCloudデータは対象外です。")
                        Toggle("削除対象と、復元できなくなることを理解しました", isOn: $acknowledgesCloudDeletion)
                        TextField("「iCloudも完全削除」と入力", text: $completeResetConfirmation)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("iCloudを含めて完全初期化", role: .destructive) {
                            Task { await model.completelyResetIncludingICloud() }
                        }.disabled(!acknowledgesCloudDeletion || completeResetConfirmation != "iCloudも完全削除" || model.isWorking)
                        Text("実行にはFace ID・Touch IDまたは端末のパスコード認証が必要です。iCloudのアクセス拒否が続く場合は削除も失敗する可能性があります。")
                            .font(.footnote)
                        if model.isCompletelyResetting {
                            ProgressView("削除処理中です…")
                        }
                        if let message = model.completeResetMessage {
                            Text(message).foregroundStyle(.red)
                            Button("エラー内容をコピー") { UIPasteboard.general.string = message }
                        }
                    }
                }
                .navigationTitle("端末設定の初期化")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { model.showsLocalRestartConfirmation = false }
                            .disabled(model.isWorking)
                    }
                }
            }
            .interactiveDismissDisabled(model.isWorking)
            .onAppear {
                restartConfirmation = ""
                completeResetConfirmation = ""
                acknowledgesCloudDeletion = false
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isWorking)
        .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in
            model.refreshICloudAccount()
        }
        .task { await model.prepareSubscriptions() }
        .task { await model.observeSubscriptionTransactions() }
        .sheet(isPresented: $model.showsSubscriptionSheet) {
            PremiumSubscriptionView()
                .environmentObject(model)
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [model.theme.tint.opacity(0.20), Color.clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .background(Color.platformBackground)
    }
}

/// iPhone・iPadのライト／ダークモードに合うシステム背景色を返します。
extension Color {
    static var platformBackground: Color {
        Color(uiColor: .systemBackground)
    }
}
