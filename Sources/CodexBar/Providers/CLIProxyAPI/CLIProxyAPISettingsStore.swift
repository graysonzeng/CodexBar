import CodexBarCore
import Foundation

extension SettingsStore {
    var cliproxyapiSpendTrackingEnabled: Bool {
        get { self.configSnapshot.providerConfig(for: .cliproxyapi)?.extrasEnabled ?? false }
        set {
            self.updateProviderConfig(provider: .cliproxyapi) { entry in
                entry.extrasEnabled = newValue
            }
            self.logProviderModeChange(
                provider: .cliproxyapi,
                field: "extrasEnabled",
                value: newValue ? "1" : "0")
        }
    }
}
