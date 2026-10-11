import AppKit
import Observation
import SwiftUI
import WebKit

// The operator-facing window for one Web Page input. The web view inside it is both the page the
// operator clicks, scrolls and logs in on and the surface ScreenCaptureKit records, so the window is
// kept on screen (no close or minimize button) and its web view is sized so its pixels equal the
// input's output size. The URL bar above the page is cropped out of the capture.

@MainActor
@Observable
final class WebInputPageModel {
    var urlText = ""
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var muted = false
    var status = ""
    var needsPermission = false
}

@MainActor
final class WebInputWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    static let barHeight: CGFloat = 40

    let webView: WKWebView
    let page = WebInputPageModel()

    var onMuteChanged: ((Bool) -> Void)?
    var onBackingChanged: (() -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var pointSize: CGSize

    init(title: String, pixelSize: CGSize, muted: Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false

        // Element fullscreen moves the video into a separate WebKit-owned window, which the
        // window capture can't see — keep it off so players fill the page instead (use an
        // /embed/ URL for a full-frame YouTube or Vimeo player).
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        WebInputPrivate.setBool(false, selector: "_setWindowOcclusionDetectionEnabled:", on: configuration.preferences)
        WebInputPrivate.setBool(false, selector: "_setHiddenPageDOMTimerThrottlingEnabled:", on: configuration.preferences)
        WebInputPrivate.setBool(false, selector: "_setPageVisibilityBasedProcessSuppressionEnabled:", on: configuration.preferences)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        pointSize = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        webView = WKWebView(
            frame: CGRect(origin: .zero, size: pointSize), configuration: configuration)
        // WebKit throttles and stops painting pages in windows it thinks are covered; the capture
        // needs every frame even when the operator parks this window behind the app.
        WebInputPrivate.setBool(false, selector: "_setWindowOcclusionDetectionEnabled:", on: webView)

        let window = NSWindow(
            contentRect: CGRect(
                origin: .zero,
                size: CGSize(width: pointSize.width, height: pointSize.height + Self.barHeight)),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.tabbingMode = .disallowed
        super.init(window: window)

        page.muted = muted
        let container = NSView(frame: window.contentLayoutRect)
        container.addSubview(webView)
        let bar = NSHostingView(rootView: WebInputBar(page: page, controller: self))
        container.addSubview(bar)
        window.contentView = container
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        layoutContent()
        window.center()

        observations = [
            webView.observe(\.url) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.page.urlText = view.url?.absoluteString ?? "" }
            },
            webView.observe(\.title) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.page.title = view.title ?? "" }
            },
            webView.observe(\.canGoBack) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.page.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.page.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.page.isLoading = view.isLoading }
            },
        ]
        applyMute()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Resizes the page so its backing pixels match `pixelSize` on the window's current display.
    func resize(pixelSize: CGSize) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        pointSize = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        guard let window else { return }
        let top = window.frame.maxY
        window.setContentSize(CGSize(width: pointSize.width, height: pointSize.height + Self.barHeight))
        window.setFrameTopLeftPoint(CGPoint(x: window.frame.minX, y: top))
        layoutContent()
    }

    private func layoutContent() {
        webView.frame = CGRect(origin: .zero, size: pointSize)
        window?.contentView?.subviews
            .first { $0 !== webView }?
            .frame = CGRect(x: 0, y: pointSize.height, width: pointSize.width, height: Self.barHeight)
    }

    // The web view's rect within the captured window, in points from the window's top-left — the
    // capture's source rect, so the title bar and URL bar never reach the output.
    func pageRect(capturedWindowHeight: CGFloat) -> CGRect {
        guard let window else { return CGRect(origin: .zero, size: pointSize) }
        let inWindow = webView.convert(webView.bounds, to: nil)
        let height = capturedWindowHeight > 0 ? capturedWindowHeight : window.frame.height
        return CGRect(
            x: inWindow.minX, y: height - inWindow.maxY,
            width: inWindow.width, height: inWindow.height)
    }

    func load(_ text: String) {
        guard let url = WebInputURL.normalized(text) else {
            page.status = "Not a web address: \(text)"
            return
        }
        page.urlText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func setMuted(_ muted: Bool) {
        page.muted = muted
        applyMute()
        onMuteChanged?(muted)
    }

    func teardown() {
        observations = []
        webView.pauseAllMediaPlayback()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        window?.orderOut(nil)
        window?.close()
    }

    private func applyMute() {
        if WebInputPrivate.setUInt(page.muted ? 1 : 0, selector: "_setPageMuted:", on: webView) { return }
        // No private mute on this WebKit: mute the page's media elements directly instead.
        let flag = page.muted ? "true" : "false"
        webView.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach(function(m){m.muted=\(flag);});")
    }

    // MARK: NSWindowDelegate

    func windowDidChangeBackingProperties(_ notification: Notification) {
        onBackingChanged?()
    }

    // MARK: WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyMute()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else { return }
        DiagnosticsStore.shared.note("input.web", detail: "load failed: \(error.localizedDescription)")
    }

    // Pages that open links in a new window (target=_blank) navigate this one instead.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

private struct WebInputBar: View {
    let page: WebInputPageModel
    let controller: WebInputWindowController
    @State private var editing = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { controller.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!page.canGoBack).help("Back")
            Button { controller.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!page.canGoForward).help("Forward")
            Button {
                if page.isLoading { controller.webView.stopLoading() } else { controller.webView.reload() }
            } label: {
                Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(page.isLoading ? "Stop" : "Reload")
            TextField("Web address", text: $editing)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { controller.load(editing) }
            Toggle(isOn: Binding(get: { page.muted }, set: { controller.setMuted($0) })) {
                Image(systemName: page.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .toggleStyle(.button)
            .help("Mute page audio")
            if !page.status.isEmpty {
                Text(page.status)
                    .font(.system(size: 11))
                    .foregroundStyle(page.needsPermission ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .help(page.status)
            }
            if page.needsPermission {
                Button("Open Settings") { WebInputURL.openScreenRecordingSettings() }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .onAppear { editing = page.urlText }
        .onChange(of: page.urlText) { _, url in if !fieldFocused { editing = url } }
    }
}

enum WebInputURL {
    // Accepts what operators type into an address bar: bare hosts get https://.
    static func normalized(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        guard !trimmed.contains(" "), let url = URL(string: "https://" + trimmed), url.host != nil
        else { return nil }
        return url
    }

    @MainActor
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// WebKit's SPI for keeping a page live while covered and for muting it. Every call checks the
// selector first and quietly does nothing on a WebKit without it.
@MainActor
enum WebInputPrivate {
    @discardableResult
    static func setBool(_ value: Bool, selector name: String, on object: NSObject) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector)
        else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(object, selector, value)
        return true
    }

    @discardableResult
    static func setUInt(_ value: UInt, selector name: String, on object: NSObject) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector)
        else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(object, selector, value)
        return true
    }
}
