import AppKit
import SwiftUI

@main
enum Launcher {
    static func main() {
        if Guardian.runIfRequested(arguments: CommandLine.arguments) {
            return
        }
        if isAnotherInstanceRunning() {
            return
        }
        // Covers a previous run whose guardian was also killed.
        Guardian.releaseRecordedProcesses()
        Guardian.launch()
        // AppKit waits well over a second before showing a tooltip, which is easy to miss in a small panel.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 300])
        PowerCapApp.main()
    }

    private static func isAnotherInstanceRunning() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return false
        }
        let ownPid = getpid()
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).contains { $0.processIdentifier != ownPid }
    }
}

struct PowerCapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PowerPanel(controller: appDelegate.controller)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = PowerController()
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Quit cleanly on SIGTERM so limited apps are resumed before PowerCap exits.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}
