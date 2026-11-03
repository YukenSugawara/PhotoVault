import SwiftUI

@main
/// iPhone・iPadで共通して使用するiOSアプリのエントリーポイントです。
struct PhotoVaultApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var advertising = AdvertisingService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(advertising)
                .tint(model.theme.tint)
                // 広告SDKはアプリ起動中に一度だけ準備し、Releaseでは同意完了後だけ配信します。
                .task { advertising.prepare() }
                .alert(
                    "お知らせ",
                    isPresented: Binding(
                        get: { model.errorMessage != nil },
                        set: { if !$0 { model.errorMessage = nil } }
                    )
                ) {
                    if model.iCloudAccountIssue != nil {
                        Button("エラー内容をコピー") {
                            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "不明"
                            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "不明"
                            UIPasteboard.general.string = "PhotoVault \(version) / build \(build)\n画面：iCloud再接続\n\(model.errorMessage ?? "")"
                        }
                    }
                    Button("初期化の案内") {
                        model.errorMessage = nil
                        model.showsLocalRestartConfirmation = true
                    }
                    Button("OK") { model.errorMessage = nil }
                } message: {
                    Text(model.errorMessage ?? "")
                }
                // バックグラウンド移行・復帰をAppModelへ渡し、設定された時間で鍵を破棄します。
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        model.sceneDidEnterBackground()
                    }
                    if newPhase == .active {
                        model.sceneDidBecomeActive()
                        Task { await model.refreshSubscriptionStatus() }
                    }
                }
        }
    }
}
