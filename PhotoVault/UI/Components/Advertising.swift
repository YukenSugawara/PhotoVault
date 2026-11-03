import SwiftUI

#if os(iOS)
import UIKit

#if canImport(GoogleMobileAds)
import GoogleMobileAds
#endif

#if canImport(UserMessagingPlatform)
import UserMessagingPlatform
#endif
#endif

/// 広告SDKの初期化と、広告配信に必要な同意状態を一か所で管理します。
///
/// DebugではGoogle公式テスト広告をすぐに表示します。ReleaseではUMPの同意確認が
/// 完了し、`canRequestAds`が真になった場合にだけ広告リクエストを許可します。
@MainActor
final class AdvertisingService: ObservableObject {
    @Published private(set) var canRequestAds = false
    @Published private(set) var privacyOptionsRequired = false

    private var hasPrepared = false

    /// アプリ起動ごとに一度だけ、広告と同意状態を準備します。
    func prepare() {
        guard !hasPrepared else { return }
        hasPrepared = true

        // 個人用では広告SDK・同意画面・広告リクエストを一切起動しません。
        guard AppDistribution.showsAdvertising else {
            canRequestAds = false
            privacyOptionsRequired = false
            return
        }

#if os(iOS) && canImport(GoogleMobileAds)
#if DEBUG
        // 開発中に本番広告を誤タップしないよう、Debugでは同意画面を待たずテスト広告だけを読み込みます。
        MobileAds.shared.start()
        canRequestAds = true
#else
#if canImport(UserMessagingPlatform)
        let parameters = RequestParameters()
        ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }

                // 更新に失敗した場合も、SDKが保持している直近の有効な同意状態だけを利用します。
                if error != nil {
                    self.finishConsentFlowUsingCachedState()
                    return
                }

                ConsentForm.loadAndPresentIfRequired(from: nil) { [weak self] _ in
                    Task { @MainActor in
                        self?.finishConsentFlowUsingCachedState()
                    }
                }
            }
        }
#else
        // UMPを外した構成では広告を要求せず、同意前配信を防ぎます。
        canRequestAds = false
#endif
#endif
#endif
    }

    /// UMPが再表示を要求しているとき、設定画面からプライバシー選択を開きます。
    func presentPrivacyOptions() {
        guard AppDistribution.showsAdvertising else { return }

#if os(iOS) && canImport(UserMessagingPlatform)
        ConsentForm.presentPrivacyOptionsForm(from: nil) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPrivacyOptionsRequirement()
            }
        }
#endif
    }

#if os(iOS) && canImport(GoogleMobileAds) && canImport(UserMessagingPlatform)
    /// UMPが返す状態を再確認し、許可済みの場合に限ってMobile Ads SDKを開始します。
    private func finishConsentFlowUsingCachedState() {
        refreshPrivacyOptionsRequirement()
        guard ConsentInformation.shared.canRequestAds else {
            canRequestAds = false
            return
        }

        MobileAds.shared.start()
        canRequestAds = true
    }

    private func refreshPrivacyOptionsRequirement() {
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }
#endif
}

#if os(iOS)
/// ログイン後の画面下部へ固定する、iPhone・iPad共通のバナー領域です。
struct PhotoVaultBannerAdView: View {
    @EnvironmentObject private var advertising: AdvertisingService

    var body: some View {
        Group {
            if advertising.canRequestAds {
#if canImport(GoogleMobileAds)
                GoogleBannerContainer(adUnitID: Self.adUnitID)
                    .frame(width: 320, height: 50)
#else
                EmptyView()
#endif
            }
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("広告")
    }

    /// Ad Unit IDはビルド設定からInfo.plistへ渡します。未設定時はGoogle公式テストIDを使います。
    private static var adUnitID: String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "GADBannerAdUnitIdentifier") as? String,
           !configured.isEmpty {
            return configured
        }
        return "ca-app-pub-3940256099942544/2435281174"
    }
}

#if canImport(GoogleMobileAds)
/// UIKit製のGoogleバナーをSwiftUIのレイアウトへ橋渡しします。
private struct GoogleBannerContainer: UIViewRepresentable {
    let adUnitID: String

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = adUnitID
        banner.rootViewController = context.coordinator.presentingViewController
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {
        // バナー自身が自動更新するため、SwiftUI更新時に広告を再リクエストしません。
        if uiView.rootViewController == nil {
            uiView.rootViewController = context.coordinator.presentingViewController
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        /// 現在表示中の最前面ViewControllerを辿り、広告の遷移元として使用します。
        var presentingViewController: UIViewController? {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            var controller = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController

            while let presented = controller?.presentedViewController {
                controller = presented
            }
            return controller
        }
    }
}
#endif
#endif
