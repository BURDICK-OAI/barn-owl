import SwiftUI

@main
struct BarnOwlApp: App {
    @NSApplicationDelegateAdaptor(BarnOwlAppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--install-api-key-from-env") {
            let key = ProcessInfo.processInfo.environment["BARNOWL_API_KEY_TO_INSTALL"] ?? ""
            do {
                try BarnOwlAPIKeyStore.saveAPIKey(key)
                print("api_key_install_success=true")
                Darwin.exit(0)
            } catch {
                print("api_key_install_success=false")
                Darwin.exit(1)
            }
        }

        guard CommandLine.arguments.contains("--credential-check") else {
            return
        }

        BarnOwlAPIKeyStore.diagnosticLines().forEach { line in
            print(line)
        }
        Darwin.exit(0)
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
