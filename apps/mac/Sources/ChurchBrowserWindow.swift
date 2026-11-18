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

    /// A Browser slide went up: its window comes forward on the slide's
    /// site, reloaded from the start each time it fires, so the operator
    /// can click around and go back to the slide for a clean page. A slide
    /// without a site leaves the page as it is.
    static func slideWentLive(_ slide: Slide) {
        guard ChurchBrowser.shows(slide) else { return }
        guard let site = ChurchBrowser.site(on: slide) else {
            open(focus: false)
            return
        }
        let inventory = VideoInputInventory.shared
        if inventory.entry(id: ChurchBrowser.inputID) == nil {
            // Made with the slide's site, so it opens there.
            inventory.importEntry(
                id: ChurchBrowser.inputID, name: ChurchBrowser.inputName, kind: .web, sourceId: site)
            DiagnosticsStore.shared.note("browser.made", detail: site)
        } else {
            inventory.assignDevice(id: ChurchBrowser.inputID, kind: .web, sourceId: site)
        }
        inventory.webSource(id: ChurchBrowser.inputID)?.bringForward()
        DiagnosticsStore.shared.note("browser.site", detail: site)
    }
}

/// Asks for the site a Browser slide opens.
@MainActor
enum BrowserSitePrompt {
    /// The site typed, as an address; nil when cancelled.
    static func ask(current: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = current == nil ? "Browser Slide" : "Browser Site"
        alert.informativeText = "The website this slide opens. When the slide goes live, the Browser window opens on it and comes forward, and what you do there shows on the screens."
        let field = NSTextField(string: current ?? "")
        field.placeholderString = "hopejc.org"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: current == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            if let site = ChurchBrowser.normalized(field.stringValue) { return site }
            alert.informativeText = "\u{201C}\(field.stringValue)\u{201D} isn't a web address. Type one like hopejc.org."
        }
        return nil
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
