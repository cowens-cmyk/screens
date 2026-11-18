import AppKit
import PresenterCore

/// The Browser's window: the church's Web Page input with a fixed id, made
/// on this Mac the first time it's opened. Whatever the operator does in
/// it (clicking, scrolling, typing, playing a video) is what the Browser
/// slide shows while it's live.
@MainActor
enum ChurchBrowserWindow {
    /// Opens the window, making the input first if this Mac has none.
    /// `focus` makes it the key window; a slide going live only brings it
    /// forward, so the arrow keys keep driving the slides.
    static func open(focus: Bool = true) {
        let inventory = VideoInputInventory.shared
        if inventory.entry(id: ChurchBrowser.inputID) == nil {
            inventory.importEntry(
                id: ChurchBrowser.inputID, name: ChurchBrowser.inputName,
                kind: .web, sourceId: ChurchBrowser.startPage)
            DiagnosticsStore.shared.note("browser.made", detail: ChurchBrowser.startPage)
        }
        if focus {
            inventory.showWebWindow(id: ChurchBrowser.inputID)
        } else if let source = inventory.webSource(id: ChurchBrowser.inputID) {
            source.bringForward()
        } else {
            inventory.showWebWindow(id: ChurchBrowser.inputID)
        }
    }

    /// The Browser slide went up: its window comes forward.
    static func slideWentLive(_ slide: Slide) {
        guard ChurchBrowser.shows(slide) else { return }
        open(focus: false)
    }
}

extension AppModel {
    /// The church's Browser presentation, made in the library the first
    /// time anyone adds it.
    func browserPresentationID() async -> String? {
        let ids = teamCloudItems.filter { $0.kind == .presentation }.map { (id: $0.id, name: $0.name) }
        if let id = ChurchBrowser.find(ids: ids), libraryEntry(id) != nil { return id }
        if libraryEntry(ChurchBrowser.presentationID) != nil { return ChurchBrowser.presentationID }
        _ = try? await createInDrive(ChurchBrowser.presentation()).value
        DiagnosticsStore.shared.note("browser.presentation", detail: "made")
        return libraryEntry(ChurchBrowser.presentationID) != nil ? ChurchBrowser.presentationID : nil
    }

    /// Add Item › Browser: the Browser slide at the end of the plan, and its
    /// window open to set up the page.
    func addBrowser(to serviceID: String) {
        ChurchBrowserWindow.open()
        Task {
            guard let id = await browserPresentationID() else { return }
            _ = addServiceItem(serviceID, refID: id)
        }
    }
}
