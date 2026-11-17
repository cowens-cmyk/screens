import Foundation
import PresenterCore

extension AppModel {
    /// A plan copied from a template, for New Plan from This Template and
    /// for Shepherd plans built on one (Wednesday Night). It keeps the
    /// template's order, headers, colors, links and what was taken out of it
    /// (the pre-service slideshow, countdown, Transition, Walkout), and each
    /// message item gets an empty Message of its own in the template's
    /// series instead of sharing one. `messageID` names those presentations:
    /// a fixed id lets two Macs that build the same plan make one.
    func plan(
        fromTemplate template: Service, id: String, date: String, isMessage: (ServiceItem) -> Bool,
        messageID: (Int) -> String = { _ in UUID().uuidString }
    ) -> Service {
        var plan = template
        plan.id = id
        plan.isTemplate = nil
        plan.name = template.name.replacingOccurrences(of: " Template", with: "")
        plan.serviceDate = date
        plan.messagePresentationId = nil
        let copied = PlanTemplate.planItems(from: template, isMessage: isMessage)
        plan.items = copied.items
        for (number, itemID) in copied.messageItemIDs.enumerated() {
            guard let index = plan.items.firstIndex(where: { $0.id == itemID }) else { continue }
            var message = Presentation(
                id: messageID(number), name: "Message", presentationKind: .deck,
                themeId: template.sermonThemeId ?? slideBuilding.sermonThemeId ?? BasicTemplates.pointsThemeID,
                slides: [])
            message.category = PresentationTypes.sermon
            message.sermonTimerSeconds = TemplateSermonLength.seconds(in: template, model: self)
            createInDrive(message)
            plan.items[index].refId = message.id
            plan.messagePresentationId = message.id
        }
        if let ensured = PreServiceSlides.ensuring(plan, sharedID: preServiceSlideshowID()) { plan = ensured }
        return plan
    }
}
