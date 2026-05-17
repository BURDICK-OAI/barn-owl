import AppKit
import SwiftUI

@MainActor
final class BarnOwlAppDelegate: NSObject, NSApplicationDelegate {
    private var model: BarnOwlAppModel?

    private var statusBarController: BarnOwlStatusBarController?
    private var recorderWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var controlBridge: BarnOwlControlBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments

        NSApp.setActivationPolicy(.accessory)

        guard Self.shouldInstallAppRuntime(
            environment: environment,
            arguments: arguments
        ) else {
            return
        }

        let model = BarnOwlAppModel()
        self.model = model

        statusBarController = BarnOwlStatusBarController(
            model: model,
            openRecorder: { [weak self] in self?.showRecorderWindow() },
            openSettings: { [weak self] in self?.showSettingsWindow() },
            quit: { NSApp.terminate(nil) }
        )

        let bridge = BarnOwlControlBridge(
            model: model,
            openCurrentMeeting: { [weak self] in self?.showRecorderWindow() },
            openSettings: { [weak self] in self?.showSettingsWindow() }
        )
        bridge.start()
        controlBridge = bridge
    }

    nonisolated static func shouldInstallAppRuntime(
        environment: [String: String],
        arguments: [String]
    ) -> Bool {
        !isRunningUnderXCTest(environment: environment, arguments: arguments)
    }

    nonisolated static func isRunningUnderXCTest(
        environment: [String: String],
        arguments: [String]
    ) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if environment["XCInjectBundleInto"] != nil {
            return true
        }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTestBundleInject.dylib") == true {
            return true
        }
        return arguments.contains { argument in
            argument.hasSuffix(".xctest") || argument.contains(".xctest/")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showRecorderWindow() {
        guard let model else { return }
        if recorderWindow == nil {
            let hostingController = NSHostingController(rootView: RecorderWindow(model: model))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Barn Owl"
            window.setContentSize(NSSize(width: 920, height: 700))
            window.minSize = NSSize(width: 460, height: 520)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            recorderWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        recorderWindow?.makeKeyAndOrderFront(nil)
    }

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Barn Owl Settings"
            window.setContentSize(NSSize(width: 560, height: 600))
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
