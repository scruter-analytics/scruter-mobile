import ScruterCMP
import UIKit

/// The UIKit example of Scruter CMP: manual presentation after an onboarding screen, the settings entry, SDKs gated on
/// the answer.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Launch.prepare()
        #if DEBUG
        ScruterCMP.debug = true
        #endif
        // The banner shows where the app asks for it: after the onboarding.
        ScruterCMP.start(appId: "EXMPL02", presentation: .manual, endpoint: Launch.endpoint)
        Partners.shared.wire()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: scene)
        w.rootViewController = UINavigationController(rootViewController: OnboardingViewController())
        w.makeKeyAndVisible()
        window = w
    }
}

final class OnboardingViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Welcome"
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "Bowls turned in the workshop, glazed by hand."
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .title2)
        label.adjustsFontForContentSizeCategory = true
        let button = UIButton(type: .system)
        button.setTitle("Continue", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.accessibilityIdentifier = "onboarding-continue"
        button.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func continueTapped() {
        navigationController?.setViewControllers([SettingsViewController(style: .insetGrouped)], animated: true)
        // After the onboarding, never after a paywall or a sign-in wall: the banner comes first.
        ScruterCMP.showIfNeeded(from: navigationController)
    }
}

/// The app's settings, with the privacy entry that opens the preferences.
final class SettingsViewController: UITableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { "Privacy" }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var c = cell.defaultContentConfiguration()
        c.text = "Privacy choices"
        cell.contentConfiguration = c
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "privacy-choices"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        ScruterCMP.showPreferences(from: self)
    }
}
