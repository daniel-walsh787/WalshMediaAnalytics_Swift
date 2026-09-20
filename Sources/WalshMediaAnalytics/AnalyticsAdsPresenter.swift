#if os(iOS)
import UIKit
import WebKit

@MainActor
final class AnalyticsAdsPresenter: NSObject {
    static let shared = AnalyticsAdsPresenter()

    private var currentSelection: AnalyticsAdSelection?
    private var configuration: AnalyticsConfiguration?
    private var clickReported = false

    func present(selection: AnalyticsAdSelection, configuration: AnalyticsConfiguration) -> Bool {
        guard let presenter = topViewController() else { return false }
        self.currentSelection = selection
        self.configuration = configuration
        self.clickReported = false

        let controller = AnalyticsAdSheetViewController(
            htmlURL: selection.ad.htmlURL,
            onClose: { [weak self] in
                self?.handleDismiss()
            },
            onLinkClick: { [weak self] url in
                self?.handleLinkClick(url)
            },
            onDidAppear: { [weak self] in
                self?.handleImpression()
            }
        )
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(controller, animated: true)
        return true
    }

    private func handleImpression() {
        guard let selection = currentSelection, let configuration else { return }
        let campaignId = selection.campaign.id
        let adId = selection.ad.id
        Analytics.track(
            "ad_shown",
            [
                "campaign_id": .int(campaignId),
                "ad_id": .int(adId),
            ]
        )
        Task {
            try? await AnalyticsAdsClient.shared.reportEvent(
                configuration: configuration,
                type: "impression",
                campaignId: campaignId,
                adId: adId
            )
        }
    }

    private func handleLinkClick(_ url: URL) {
        guard let selection = currentSelection, let configuration else {
            UIApplication.shared.open(url)
            return
        }
        if !clickReported {
            clickReported = true
            let campaignId = selection.campaign.id
            let adId = selection.ad.id
            Analytics.track(
                "ad_clicked",
                [
                    "campaign_id": .int(campaignId),
                    "ad_id": .int(adId),
                ]
            )
            Task {
                try? await AnalyticsAdsClient.shared.reportEvent(
                    configuration: configuration,
                    type: "click",
                    campaignId: campaignId,
                    adId: adId
                )
            }
        }
        UIApplication.shared.open(url)
    }

    private func handleDismiss() {
        if let selection = currentSelection {
            Analytics.track(
                "ad_dismissed",
                [
                    "campaign_id": .int(selection.campaign.id),
                    "ad_id": .int(selection.ad.id),
                ]
            )
        }
        currentSelection = nil
        configuration = nil
        clickReported = false
    }

    private func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

@MainActor
final class AnalyticsAdSheetViewController: UIViewController, WKNavigationDelegate {
    private let htmlURL: String
    private let onClose: () -> Void
    private let onLinkClick: (URL) -> Void
    private let onDidAppear: () -> Void
    private var webView: WKWebView!
    private var didFireAppear = false

    init(
        htmlURL: String,
        onClose: @escaping () -> Void,
        onLinkClick: @escaping (URL) -> Void,
        onDidAppear: @escaping () -> Void
    ) {
        self.htmlURL = htmlURL
        self.onClose = onClose
        self.onLinkClick = onLinkClick
        self.onDidAppear = onDidAppear
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.tintColor = .secondaryLabel
        close.translatesAutoresizingMaskIntoConstraints = false
        close.accessibilityLabel = "Close"
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(webView)
        view.addSubview(close)

        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            close.widthAnchor.constraint(equalToConstant: 36),
            close.heightAnchor.constraint(equalToConstant: 36),

            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        if let url = URL(string: htmlURL) {
            webView.load(URLRequest(url: url))
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didFireAppear else { return }
        didFireAppear = true
        onDidAppear()
    }

    @objc private func closeTapped() {
        dismiss(animated: true) { [onClose] in
            onClose()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            onLinkClick(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
#endif
