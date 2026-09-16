import SwiftUI
import WebKit

#if DEBUG
    import OSLog
#endif

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

enum PauseSeedMood: String, Equatable {
    case calm
    case waiting
    case resting
}

#if DEBUG
    private let mascotLogger = Logger(subsystem: "org.hardpause.app", category: "PauseSeed")
#endif

/// The Low Light character used by the iOS and macOS apps.
struct PauseSeed: View {
    let mood: PauseSeedMood
    var size: CGFloat = 220
    var attention: CGPoint?
    var greetingTrigger: Int = 0
    var isAnimationPaused = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var rendererIsReady = false

    var body: some View {
        ZStack {
            MascotWebView(
                state: MascotNativeState(
                    mood: mood,
                    isActive: isVisible && scenePhase == .active && !isAnimationPaused,
                    reduceMotion: reduceMotion,
                    attention: attention,
                    greetingTrigger: greetingTrigger
                ),
                setRendererReady: { rendererIsReady = $0 }
            )
            MascotFirstFrame(mood: mood)
                .opacity(rendererIsReady ? 0 : 1)
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size * 0.95)
        // native.html owns the single accessible button and its interaction.
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

private struct MascotFirstFrame: View {
    let mood: PauseSeedMood
    #if os(macOS)
        private static let image: NSImage? = {
            guard let url = Bundle.main.url(forResource: "first-frame", withExtension: "svg") else {
                return nil
            }
            return NSImage(contentsOf: url)
        }()
        private static let awakeImage: NSImage? = {
            guard
                let url = Bundle.main.url(
                    forResource: "first-frame-awake", withExtension: "svg", subdirectory: "mascot")
            else {
                return nil
            }
            return NSImage(contentsOf: url)
        }()
        private var firstImage: NSImage? { mood == .resting ? Self.awakeImage ?? Self.image : Self.image }
    #elseif os(iOS)
        private static let image = UIImage(named: "LowLightCharacter")
        private static let awakeImage = UIImage(named: "LowLightCharacterAwake")
        private var firstImage: UIImage? { mood == .resting ? Self.awakeImage ?? Self.image : Self.image }
    #endif

    var body: some View {
        if let image = firstImage {
            #if os(macOS)
                firstFrame(Image(nsImage: image))
            #elseif os(iOS)
                firstFrame(Image(uiImage: image))
            #endif
        }
    }

    private func firstFrame(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

private struct MascotNativeState: Equatable {
    let mood: PauseSeedMood
    let isActive: Bool
    let reduceMotion: Bool
    let attentionX: Double
    let attentionY: Double
    let hasAttention: Bool
    let greetingTrigger: Int

    init(mood: PauseSeedMood, isActive: Bool, reduceMotion: Bool, attention: CGPoint?, greetingTrigger: Int) {
        self.mood = mood
        self.isActive = isActive
        self.reduceMotion = reduceMotion
        self.greetingTrigger = greetingTrigger
        if let attention, attention.x.isFinite, attention.y.isFinite {
            attentionX = min(1, max(-1, Double(attention.x)))
            attentionY = min(1, max(-1, Double(attention.y)))
            hasAttention = true
        } else {
            attentionX = 0
            attentionY = 0
            hasAttention = false
        }
    }
}

private struct MascotWebView: View {
    let state: MascotNativeState
    @StateObject private var bridge: MascotWebPageBridge

    init(
        state: MascotNativeState,
        setRendererReady: @escaping @MainActor (Bool) -> Void
    ) {
        self.state = state
        _bridge = StateObject(
            wrappedValue: MascotWebPageBridge(setRendererReady: setRendererReady)
        )
    }

    var body: some View {
        WebView(bridge.page)
            .webViewContentBackground(.hidden)
            .webViewBackForwardNavigationGestures(.disabled)
            .webViewMagnificationGestures(.disabled)
            .webViewLinkPreviews(.disabled)
            .webViewTextSelection(.disabled)
            .onAppear {
                bridge.update(state)
                bridge.startLoading()
            }
            .onChange(of: state) { _, nextState in
                bridge.update(nextState)
            }
    }
}

@MainActor
private final class MascotWebPageBridge: ObservableObject {
    static let readyHandlerName = "hardPauseMascotReady"

    let page: WebPage

    private var latestState: MascotNativeState?
    private var appliedState: MascotNativeState?
    private var documentIsReady = false
    private var rendererIsReady = false
    private var loadStarted = false
    private var isApplying = false
    private var loadTask: Task<Void, Never>?
    private let htmlURL: URL?
    private let readyHandler: MascotReadyMessageHandler
    private let setRendererReady: @MainActor (Bool) -> Void

    init(setRendererReady: @escaping @MainActor (Bool) -> Void) {
        let htmlURL = Bundle.main.url(
            forResource: "native",
            withExtension: "html",
            subdirectory: "mascot"
        )
        let allowedDirectoryURL = htmlURL?.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        let readyHandler = MascotReadyMessageHandler()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = true
        configuration.loadsSubresources = true
        configuration.userContentController.add(
            readyHandler,
            name: Self.readyHandlerName
        )

        self.htmlURL = htmlURL
        self.readyHandler = readyHandler
        self.setRendererReady = setRendererReady
        page = WebPage(
            configuration: configuration,
            navigationDecider: MascotNavigationDecider(
                allowedDirectoryURL: allowedDirectoryURL
            )
        )
        readyHandler.onReady = { [weak self] in
            self?.rendererDidBecomeReady()
        }
    }

    func update(_ state: MascotNativeState) {
        latestState = state
        applyLatestState()
    }

    func startLoading() {
        guard !loadStarted else { return }
        loadStarted = true
        guard let htmlURL else {
            loadStarted = false
            return
        }
        var initialURL = URLComponents(url: htmlURL, resolvingAgainstBaseURL: false)
        initialURL?.fragment = latestState?.mood.rawValue
        let loadURL = initialURL?.url ?? htmlURL
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in page.load(loadURL) {
                    switch event {
                    case .startedProvisionalNavigation:
                        navigationStarted()
                    case .finished:
                        navigationFinished()
                    case .receivedServerRedirect, .committed:
                        break
                    @unknown default:
                        break
                    }
                }
            } catch {
                loadStarted = false
                documentIsReady = false
                rendererIsReady = false
                appliedState = nil
                setRendererReady(false)
                #if DEBUG
                    mascotLogger.error(
                        "native renderer navigation failed: \(error.localizedDescription, privacy: .public)"
                    )
                #endif
            }
        }
    }

    private func applyLatestState() {
        guard documentIsReady, rendererIsReady, !isApplying else { return }
        isApplying = true
        Task { [weak self] in
            await self?.applyLatestStateLoop()
        }
    }

    private func applyLatestStateLoop() async {
        defer { isApplying = false }
        while documentIsReady, rendererIsReady, let state = latestState, state != appliedState {
            do {
                let shouldGreet = state.greetingTrigger != (appliedState?.greetingTrigger ?? 0)
                let applied = try await page.callJavaScript(
                    Self.script(for: state, previous: appliedState, greet: shouldGreet), contentWorld: .page)
                guard applied as? Bool == true else { return }
                appliedState = state
            } catch {
                #if DEBUG
                    mascotLogger.error(
                        "native renderer update failed: \(error.localizedDescription, privacy: .public)"
                    )
                #endif
                return
            }
        }
    }

    private func publishReadinessIfReady() {
        #if DEBUG
            mascotLogger.notice(
                "publish check document=\(self.documentIsReady, privacy: .public) renderer=\(self.rendererIsReady, privacy: .public)"
            )
        #endif
        guard documentIsReady, rendererIsReady else { return }
        setRendererReady(true)
    }

    private func navigationStarted() {
        #if DEBUG
            mascotLogger.notice("navigation started")
        #endif
        documentIsReady = false
        rendererIsReady = false
        appliedState = nil
        setRendererReady(false)
    }

    private func navigationFinished() {
        #if DEBUG
            mascotLogger.notice("navigation finished")
        #endif
        documentIsReady = true
        appliedState = nil
        applyLatestState()
        publishReadinessIfReady()
    }

    private func rendererDidBecomeReady() {
        #if DEBUG
            mascotLogger.notice("renderer ready message")
        #endif
        rendererIsReady = true
        applyLatestState()
        publishReadinessIfReady()
    }

    private static func script(for state: MascotNativeState, previous: MascotNativeState?, greet: Bool) -> String {
        """
        const mascot = window.hardPauseMascot;
        if (!mascot) return false;
        mascot.setActive(\(state.isActive.javaScriptLiteral));
        if (\((previous?.mood != state.mood).javaScriptLiteral)) {
          mascot.setMood('\(state.mood.rawValue)');
        }
        if (\((previous?.reduceMotion != state.reduceMotion).javaScriptLiteral)) {
          mascot.setReducedMotion(\(state.reduceMotion.javaScriptLiteral));
        }
        mascot.setAttention({
          x: \(state.attentionX),
          y: \(state.attentionY),
          active: \(state.hasAttention.javaScriptLiteral)
        });
        if (\(greet.javaScriptLiteral)) mascot.greet();
        return true;
        """
    }
}

@MainActor
private final class MascotReadyMessageHandler: NSObject, WKScriptMessageHandler {
    var onReady: (() -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        onReady?()
    }
}

private struct MascotNavigationDecider: WebPage.NavigationDeciding {
    let allowedDirectoryURL: URL?

    @MainActor
    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard action.target != nil, let url = action.request.url else { return .cancel }
        if url.absoluteString == "about:blank" { return .allow }
        guard url.isFileURL, let allowedDirectoryURL else { return .cancel }
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let directory = allowedDirectoryURL.path
        return candidate == directory || candidate.hasPrefix(directory + "/")
            ? .allow
            : .cancel
    }
}

extension Bool {
    fileprivate var javaScriptLiteral: String {
        self ? "true" : "false"
    }
}
