import AppKit
import Observation
import PresenterCore
import SwiftUI
import WebKit

/// SongSelect inside Screens. The church signs in once (WebKit keeps the
/// sign-in like a browser does); Get Lyrics opens the song's page here, and
/// whatever is downloaded from it, the lyrics, a ChordPro file or a chord
/// sheet PDF, is imported at once and linked to the plan's song, with no
/// trip through Downloads. CCLI offers no way for an app to fetch songs by
/// itself, so the download stays a click: the person licensed picks it.
@MainActor
@Observable
final class SongSelectPage {
    var title = ""
    var status = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
}

@MainActor
final class SongSelectWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let shared = SongSelectWindow()

    /// The plan song a download is for; nil imports a new library song.
    struct Target: Equatable {
        var itemID: String
        var planID: String
        var title: String
    }

    let page = SongSelectPage()
    private var window: NSWindow?
    private var webView: WKWebView?
    private var target: Target?
    private weak var model: AppModel?
    private var observations: [NSKeyValueObservation] = []
    private var destinations: [ObjectIdentifier: URL] = [:]

    static func url(ccli: Int?, title: String?) -> URL {
        var components = URLComponents(string: "https://songselect.ccli.com")!
        if let ccli {
            components.path = "/songs/\(ccli)"
        } else if let title, !title.isEmpty {
            components.path = "/search/results"
            components.queryItems = [URLQueryItem(name: "search", value: title)]
        }
        return components.url!
    }

    /// Opens SongSelect at the song (by CCLI number, else a title search),
    /// or its home page, ready to download.
    func open(ccli: Int?, title: String?, for target: Target?, model: AppModel) {
        self.target = target
        self.model = model
        page.status = target.map { "Download the lyrics or ChordPro for “\($0.title)”; it goes straight into the plan." }
            ?? "Download a song's lyrics or ChordPro; it's added to the library."
        let webView = webView ?? makeWebView()
        webView.load(URLRequest(url: Self.url(ccli: ccli, title: title)))
        let window = window ?? makeWindow(webView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The default store persists, so the SongSelect sign-in lasts.
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        observations = [
            view.observe(\.title) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.page.title = view.title ?? "" }
            },
            view.observe(\.canGoBack) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.page.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.page.canGoForward = view.canGoForward }
            },
            view.observe(\.isLoading) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.page.isLoading = view.isLoading }
            },
        ]
        webView = view
        return view
    }

    private func makeWindow(_ webView: WKWebView) -> NSWindow {
        let root = SongSelectView(page: page, webView: webView, window: self)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "SongSelect"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1100, height: 800))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("SongSelectWindow")
        window.center()
        self.window = window
        return window
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    /// The page in the Mac's browser instead; a lyrics file downloaded
    /// there is still picked up from Downloads for the plan's song.
    func openInBrowser() {
        guard let url = webView?.url else { return }
        NSWorkspace.shared.open(url)
        if let target, let model {
            LyricsFetcher.shared.watchDownloads(for: target.itemID, planID: target.planID, title: target.title, model: model)
        }
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Closed without a download: Get Lyrics is no longer waiting.
        if target != nil, LyricsFetcher.shared.waitingItemID == target?.itemID, !LyricsFetcher.shared.isWatching {
            LyricsFetcher.shared.cancel()
        }
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        return disposition.contains("attachment") || !navigationResponse.canShowMIMEType ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// Links that open a new window (SongSelect's download buttons can)
    /// open here instead.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("screens-songselect-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(suggestedFilename.isEmpty ? "song.txt" : suggestedFilename)
        destinations[ObjectIdentifier(download)] = url
        page.status = "Downloading \(url.lastPathComponent)…"
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        Task { await imported(url) }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        page.status = "The download didn't finish: \(error.localizedDescription)"
    }

    /// The downloaded file into the library: lyrics and ChordPro as they
    /// are, a chord sheet PDF read into ChordPro first.
    private func imported(_ url: URL) async {
        guard let model else { return }
        let text: String?
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            text = await Task.detached { ChordChartImport.chordPro(fromPDF: url) }.value
        } else if LyricsFetcher.lyricExtensions.contains(ext) {
            text = LyricsFetcher.read(url)
        } else {
            // A .usr, .zip or other download isn't lyrics text; read as text
            // it would make a song of junk and link it to the plan.
            text = nil
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            page.status = "\(url.lastPathComponent) has no lyrics Screens can read. Try the lyrics or ChordPro download."
            return
        }
        let fetcher = LyricsFetcher.shared
        if let target {
            if LyricsFetcher.linkedPresentation(target.itemID, planID: target.planID, model: model) != nil {
                page.status = "“\(target.title)” already has slides."
                fetcher.completed("“\(target.title)” already has slides")
                return
            }
            let song = fetcher.importText(text, title: target.title, model: model)
            fetcher.link(target.itemID, planID: target.planID, to: song.id, model: model)
            fetcher.completed("Imported “\(target.title)” from SongSelect")
            page.status = "Imported “\(song.name)” into the plan."
            self.target = nil
            window?.orderOut(nil)
        } else {
            let song = fetcher.importText(text, title: url.deletingPathExtension().lastPathComponent, model: model)
            model.noteImportSummary("Imported “\(song.name)” from SongSelect")
            page.status = "Imported “\(song.name)” into the library. Download another, or close this window."
        }
    }
}

private struct SongSelectView: View {
    let page: SongSelectPage
    let webView: WKWebView
    let window: SongSelectWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { window.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!page.canGoBack)
                Button { window.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!page.canGoForward)
                Button { window.reload() } label: {
                    Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
                }
                Text(page.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Open in Browser") { window.openInBrowser() }
                    .help("Use the Mac's browser instead; a lyrics file downloaded there is still picked up for this song")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            SongSelectWebView(webView: webView)
        }
        .frame(minWidth: 720, minHeight: 500)
    }
}

private struct SongSelectWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
