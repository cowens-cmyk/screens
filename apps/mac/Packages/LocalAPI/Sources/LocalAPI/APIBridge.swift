import Foundation

@MainActor
public protocol LocalAPIBridge: AnyObject, Sendable {

    func librarySummary() throws -> APILibrarySummary
    func libraryEntries(kind: APIDocumentKind) throws -> [APILibraryEntry]

    func documentJSON(kind: APIDocumentKind, id: String) async throws -> Data
    func showStatus() -> APIShowStatus
    func timers() -> [APITimerStatus]
    func transportRows() -> [APITransportRow]
    func outputsStatus() -> APIOutputsStatus
    func schedulerStatus() -> APISchedulerStatus

    func fireSlide(_ command: APIFireSlideCommand) async throws

    func advance(steps: Int, settled: Bool) async throws
    func clear(_ command: APIClearCommand) throws
    func clearAll()
    func fireMedia(id: String) throws
    func fireActionCombo(id: String) throws
    func fireAlert(_ command: APIFireAlertCommand) throws
    func dismissAlert()
    func timerAction(id: String, action: APITimerAction) throws
    func mediaTransport(id: String, command: APIMediaTransportCommand) throws

    func selectService(id: String) throws

    func setSchedulerEnabled(_ enabled: Bool)
    func setScheduleTriggerEnabled(id: String, enabled: Bool) throws

    func fireScheduleTrigger(id: String) throws

    func midiDevices() -> [APIMIDIDeviceStatus]
    func setMIDIDeviceEnabled(id: String, enabled: Bool) throws

    func videoInputs() -> [APIVideoInputStatus]

    func createDocument(kind: APIDocumentKind, body: Data) async throws -> String
    func updateDocument(kind: APIDocumentKind, id: String, body: Data) async throws
    func deleteDocument(kind: APIDocumentKind, id: String) async throws
    func addServiceItem(serviceId: String, refId: String, index: Int?) throws

    /// The audience screen or the next slide as a small JPEG for the phone remote.
    func showFrame(_ which: APIShowFrame) async throws -> Data
    /// Shows a validated note from the remote in the booth and logs it.
    func sendBoothMessage(_ command: APIBoothMessageCommand) throws -> APIBoothMessage
    /// The notes sent this session, newest first.
    func boothMessages() -> [APIBoothMessage]
}
