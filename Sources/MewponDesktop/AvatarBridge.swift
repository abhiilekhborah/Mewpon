import SwiftUI
import WebKit
import MewponCore

@MainActor protocol AvatarControlling {
    func setExpression(_ expression: String)
    func setActivity(_ activity: String)
    func setOutfit(_ outfit: String)
    func playAnimation(_ animation: String)
    func reset()
}

final class AvatarWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor final class AvatarBridge: NSObject, ObservableObject, AvatarControlling, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var error: String?
    @Published private(set) var isReady = false
    @Published var performanceSummary: String?
    let webView: WKWebView
    @Published private(set) var isPlaying = false
    @Published private(set) var petAction: String?
    @Published private(set) var followingCursor = false
    var onFocusAvatar: (() -> Void)?
    var onPlayRequested: (() -> Void)?
    var onPlayInterrupted: (() -> Void)?
    private var attention = false
    var onActivate: (() -> Void)?
    var onDrag: ((Double, Double) -> Void)?
    private var ready = false
    private var state = AvatarMapping.mapping(for: .idle)
    private var outfit = UserDefaults.standard.string(forKey: "outfit") ?? "default"
    private var visible = true
    private var frameBudget=60
    private var previewing = false
    private var idleTask: Task<Void, Never>?
    private let root: URL
    override init() {
        // SwiftPM's generated accessor searches beside the executable, not inside
        // a macOS app's Contents/Resources directory. Prefer the packaged bundle.
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Mewpon_MewponDesktop.bundle")
        let resources = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        root = resources.url(forResource: "ExistingMewponAvatar", withExtension: nil)!
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = AvatarWebView(frame: .zero, configuration: config)
        super.init()
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        config.userContentController.add(self, name: "mewpon")
        webView.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready": ready = true; isReady = true; applyState(); setOutfit(outfit); setVisible(visible);invoke("budget",["value":frameBudget])
        case "pet":
            let playing = body["playing"] as? Bool ?? false
            let wasPlaying = isPlaying
            isPlaying = playing; petAction = body["action"] as? String
            followingCursor = body["following"] as? Bool ?? false
            if wasPlaying && !playing { onPlayInterrupted?() }
        case "activate": onActivate?()
        case "drag": if let dx = body["dx"] as? Double, let dy = body["dy"] as? Double, abs(dx) < 200, abs(dy) < 200 { onDrag?(dx, dy) }
        case "error": error = body["message"] as? String ?? "Avatar failed to load."
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.isFileURL == true && url!.standardizedFileURL.path.hasPrefix(root.path + "/") ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }
    func event(_ event: AssistantEvent, returnToIdle: Bool = false) {
        let nextAttention=event != .idle
        let mapping=AvatarMapping.mapping(for:event)
        if !returnToIdle,attention==nextAttention,state==mapping,!previewing{return}
        idleTask?.cancel()
        attention = nextAttention
        if attention && isPlaying { exitPlayMode(); onPlayInterrupted?() }
        if state != mapping || previewing || attention { state = mapping; previewing = false; applyState() }
        if returnToIdle {
            idleTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(event == .responding ? 2.5 : 1.4)); self?.event(.idle) } catch {}
            }
        }
    }
    private func applyState() { invoke("state", ["expression": state.expression, "activity": state.activity as Any? ?? NSNull(), "attention": attention]) }
    private func invoke(_ operation: String, _ values: [String: Any] = [:]) {
        guard ready else { return }
        var args = values; args["operation"] = operation
        // Arguments are marshalled by WebKit; never interpolate model/user strings into JavaScript.
        let bridgeStart=ContinuousClock.now
        Task {
            do { _ = try await webView.callAsyncJavaScript("switch(operation){case 'state':window.nativeAvatar.state(expression,activity,attention);break;case 'outfit':window.nativeAvatar.outfit(value);break;case 'expression':window.nativeAvatar.expression(value);break;case 'activity':window.nativeAvatar.activity(value);break;case 'animation':window.nativeAvatar.animation(value);break;case 'reset':window.nativeAvatar.reset();break;case 'play':return window.nativeAvatar.play(value);case 'interact':return window.nativeAvatar.interact(value);case 'idle':window.nativeAvatar.idle(value);break;case 'gaze':window.nativeAvatar.gaze(x,y);break;case 'visible':window.nativeAvatar.visible(value);break;case 'budget':window.nativeAvatar.budget(value);break;case 'meter':window.nativeAvatar.meter(value);break;}", arguments: args, in: nil, contentWorld: .page)
                await PerformanceProfiler.shared.record("avatar.bridge_roundtrip",since:bridgeStart)
            }
            catch { self.error = error.localizedDescription }
        }
    }
    func speechLevel(_ value:Double) { invoke("meter",["value":value]) }
    func enterPlayMode() { guard !attention else { return }; idleTask?.cancel(); isPlaying = true; previewing = true; invoke("play", ["value": true]) }
    func exitPlayMode() { isPlaying = false; followingCursor = false; petAction = nil; invoke("play", ["value": false]); previewing = false; applyState() }
    func interact(_ value: String) { guard Self.petActions.contains(value), isPlaying else { return }; invoke("interact", ["value": value]); if value == "highFive" { onFocusAvatar?() } }
    func playActivity(_ value: String) { guard isPlaying, AvatarMapping.activities.contains(value) || value == "sleeping" else { return }; invoke("activity", ["value": value]) }
    func autonomousIdle(_ value: Bool) { invoke("idle", ["value": value]) }
    func gaze(x: Double, y: Double) { guard isPlaying, followingCursor else { return }; invoke("gaze", ["x": x, "y": y]) }
    static let petActions = ["pet", "poke", "highFive", "wave", "dance", "jump", "spin", "followCursor", "nap", "wake", "random"]
    func setExpression(_ value: String) { guard AvatarMapping.expressions.contains(value) else { error = "Unsupported expression: \(value)"; return }; previewing = true; invoke("expression", ["value": value]) }
    func setActivity(_ value: String) { guard AvatarMapping.activities.contains(value) else { error = "Unsupported activity: \(value)"; return }; previewing = true; invoke("activity", ["value": value]) }
    func setOutfit(_ value: String) {
        guard AvatarMapping.outfits.contains(value) else { error = "Unsupported outfit: \(value)"; return }
        outfit = value; UserDefaults.standard.set(value, forKey: "outfit"); invoke("outfit", ["value": value])
    }
    func playAnimation(_ value: String) { guard AvatarMapping.animations.contains(value) else { error = "Unsupported animation: \(value)"; return }; previewing = true; invoke("animation", ["value": value]) }
    func reset() { outfit = "default"; UserDefaults.standard.set(outfit, forKey: "outfit"); state = AvatarMapping.mapping(for: .idle); invoke("reset") }
    func setInferenceActive(_ value:Bool,adaptive:Bool=false){let next=value && adaptive ? 30:60;guard frameBudget != next else{return};frameBudget=next;invoke("budget",["value":frameBudget])}
    func setVisible(_ value: Bool) { visible = value; invoke("visible", ["value": value]) }
    func measureRenderer() async {
        do {
            let result = try await webView.callAsyncJavaScript("return await window.nativeAvatar.metrics();", arguments: [:], in: nil, contentWorld: .page)
            if let values = result as? [String: Any], let fps = values["observedFPS"] as? Double, let p95 = values["renderP95ms"] as? Double {
                let draw = p95 < 1 ? "<1 ms" : String(format: "%.1f ms", p95)
                performanceSummary = values["visibility"] as? String == "hidden" ? "Paused while hidden" : String(format: "%.1f fps", fps) + " · draw p95 " + draw + " · one loop"
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct AvatarView: NSViewRepresentable {
    let bridge: AvatarBridge
    func makeNSView(context: Context) -> WKWebView { bridge.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
