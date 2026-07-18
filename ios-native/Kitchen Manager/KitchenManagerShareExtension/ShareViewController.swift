import SwiftUI
import UIKit

/// Principal class for the share-services extension point (declared via
/// `NSExtensionPrincipalClass` in Info.plist — no storyboard entry point).
final class ShareViewController: UIViewController {
    private var viewModel: ShareImportViewModel?

    override func viewDidLoad() {
        super.viewDidLoad()

        let queue = SharedImportConfig.makeQueue()
        let viewModel = ShareImportViewModel(queue: queue)
        self.viewModel = viewModel

        let rootView = ShareImportRootView(
            viewModel: viewModel,
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: "KitchenManagerShareExtension", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "用户取消了分享"
                    ])
                )
            },
            onFinished: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        )

        let hosting = UIHostingController(rootView: rootView)
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        Task { [weak self] in
            await viewModel.load(from: self?.extensionContext?.inputItems as? [NSExtensionItem])
        }
    }
}
