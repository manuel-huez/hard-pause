import AppKit
import Carbon
import SwiftUI

@main
struct HardPauseApp: App {
    @NSApplicationDelegateAdaptor(HardPauseLifecycle.self) private var lifecycle
    @StateObject private var model = AppModel()
    @State private var updater = AppUpdater()

    var body: some Scene {
        Window("Hard Pause", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    lifecycle.model = model
                    lifecycle.updater = updater
                    updater.start(model: model)
                }
                .background(
                    WindowSizeReader(
                        mode: isCompactSetupWindow ? .setup : .normal
                    )
                )
                .frame(
                    minWidth: isCompactSetupWindow ? 640 : 800,
                    minHeight: 420
                )
        }
        .defaultSize(width: 800, height: 420)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("Hard Pause", systemImage: "pause.circle") {
            HardPauseMenu(model: model, updater: updater)
        }
    }

    private var isCompactSetupWindow: Bool {
        model.activeBlocks.isEmpty && model.setupState == .incomplete
    }
}

private struct HardPauseMenu: View {
    @ObservedObject var model: AppModel
    let updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.serviceIsHealthy ? "Protection service running" : "Protection needs attention")
        if model.activeBlocks.isEmpty {
            Text("No active plans")
        } else if model.activeBlocks.count == 1 {
            Text("1 active plan")
        } else {
            Text("\(model.activeBlocks.count) active plans")
        }
        Divider()
        Button("Open Hard Pause") {
            openWindow(id: "main")
            NSApplication.shared.activate()
        }
        Divider()
        Text("Version \(appVersion)")
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        if !model.activeBlocks.isEmpty && !model.browserWorkerReadyForHandoff {
            Text("Updates wait until browser protection is ready")
        } else if !model.setupServiceReady {
            Text(
                model.needsServiceUpdate
                    ? "App updates wait until protection is updated"
                    : "App updates wait until the protection service is ready"
            )
        }
        if !updater.isConfigured {
            Text("App updates are unavailable in this build")
        }
        if model.needsServiceUpdate {
            Text(
                model.serviceCanUpdateWithoutApproval
                    ? "Protection will update automatically"
                    : "Use Update protection in the app for the service"
            )
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

private enum HardPauseWindowMode: Equatable {
    case setup
    case normal

    var contentSize: NSSize {
        switch self {
        case .setup: return NSSize(width: 640, height: 420)
        case .normal: return NSSize(width: 800, height: 420)
        }
    }
}

private struct WindowSizeReader: NSViewRepresentable {
    let mode: HardPauseWindowMode

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak view] in
                guard let window = view?.window else { return }
                coordinator.apply(mode, to: window)
            }
            return
        }
        context.coordinator.apply(mode, to: window)
    }

    final class Coordinator {
        private var appliedMode: HardPauseWindowMode?

        func apply(_ mode: HardPauseWindowMode, to window: NSWindow) {
            guard appliedMode != mode else { return }
            appliedMode = mode

            let oldFrame = window.frame
            window.setContentSize(mode.contentSize)
            var newFrame = window.frame
            newFrame.origin.x = oldFrame.minX
            newFrame.origin.y = oldFrame.maxY - newFrame.height
            window.setFrame(newFrame, display: true, animate: false)
        }
    }
}

@MainActor
final class HardPauseLifecycle: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    weak var updater: AppUpdater?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let reason =
            (event?.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
            ?? event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)))?.enumCodeValue
        if let reason, [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut].contains(reason),
            updater?.installationIsStarting != true
        {
            return .terminateNow
        }
        if let updater, updater.installationIsStarting {
            Task { @MainActor in
                let mayTerminate = await updater.mayFinishInstallation()
                if !mayTerminate {
                    updater.terminationWasCanceled()
                    sender.hide(nil)
                }
                sender.reply(toApplicationShouldTerminate: mayTerminate)
            }
            return .terminateLater
        }
        if model?.keepsBrowserProtectionRunning == true || updater?.shouldHoldTermination == true {
            sender.hide(nil)
            return .terminateCancel
        }
        return .terminateNow
    }
}
