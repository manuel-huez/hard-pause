import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    private let ink = UIColor(red: 236 / 255, green: 239 / 255, blue: 246 / 255, alpha: 1)
    private let background = UIColor(red: 28 / 255, green: 29 / 255, blue: 41 / 255, alpha: 1)
    private let coral = UIColor(red: 200 / 255, green: 216 / 255, blue: 242 / 255, alpha: 1)

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        makeConfiguration(name: application.localizedDisplayName)
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        makeConfiguration(name: application.localizedDisplayName)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        makeConfiguration(name: webDomain.domain)
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        makeConfiguration(name: webDomain.domain)
    }

    private func makeConfiguration(name: String?) -> ShieldConfiguration {
        let subject = name.map { "\($0) is paused." } ?? "This is paused."
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            backgroundColor: background,
            icon: companionIcon,
            title: .init(text: subject, color: ink),
            subtitle: .init(
                text: "Your pause is still here. Open Hard Pause to see the timer or request a timeout.",
                color: ink.withAlphaComponent(0.85)
            ),
            primaryButtonLabel: .init(text: "Stay paused", color: background),
            primaryButtonBackgroundColor: coral
        )
    }

    private var companionIcon: UIImage? {
        UIImage(named: "LowLightCharacter", in: Bundle.main, compatibleWith: nil)
    }
}
