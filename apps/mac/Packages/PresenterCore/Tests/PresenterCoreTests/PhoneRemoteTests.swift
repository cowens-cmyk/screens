import Foundation
import Testing

@testable import PresenterCore

/// The phone remote's messages over the sync socket (PhoneRemote).
struct PhoneRemoteTests {
    private func decode(_ json: String) -> CloudServerMessage {
        CloudServerMessage.decode(Data(json.utf8))
    }

    private func command(_ json: String) -> Result<PhoneRemote.Command, PhoneRemote.Failure>? {
        guard case .remote(let request) = decode(json) else { return nil }
        return request.command
    }

    @Test func aTapArrivesWithItsID() {
        guard case .remote(let request) = decode(#"{"t":"remote","id":"r-1","cmd":"advance","args":{"steps":1}}"#) else {
            Issue.record("not a remote message")
            return
        }
        #expect(request.id == "r-1")
        #expect(request.command == .success(.advance(steps: 1)))
        #expect(command(#"{"t":"remote","id":"r","cmd":"advance","args":{"steps":-1}}"#) == .success(.advance(steps: -1)))
    }

    @Test func aTapWithoutAnIDIsNotOne() {
        #expect(decode(#"{"t":"remote","cmd":"advance","args":{"steps":1}}"#) == .unknown("remote"))
        #expect(decode(#"{"t":"remote","id":"","cmd":"advance"}"#) == .unknown("remote"))
    }

    @Test func eachCommandReadsItsArguments() {
        #expect(command(#"{"t":"remote","id":"a","cmd":"slide","args":{"presentationId":"P","slideId":"S","serviceId":"SV","itemId":"I","index":3}}"#)
            == .success(.slide(presentationId: "P", slideId: "S", serviceId: "SV", itemId: "I", index: 3)))
        #expect(command(#"{"t":"remote","id":"a","cmd":"slide","args":{"presentationId":"P","slideId":"S"}}"#)
            == .success(.slide(presentationId: "P", slideId: "S", serviceId: nil, itemId: nil, index: nil)))
        #expect(command(#"{"t":"remote","id":"a","cmd":"item","args":{"serviceId":"SV","itemId":"I"}}"#)
            == .success(.item(serviceId: "SV", itemId: "I")))
        #expect(command(#"{"t":"remote","id":"a","cmd":"timer","args":{"id":"T","action":"reset"}}"#)
            == .success(.timer(id: "T", action: .reset)))
        #expect(command(#"{"t":"remote","id":"a","cmd":"combo","args":{"id":"C"}}"#) == .success(.combo(id: "C")))
        #expect(command(#"{"t":"remote","id":"a","cmd":"alert","args":{"message":"  Wrap up  "}}"#) == .success(.alert(message: "Wrap up")))
        #expect(command(#"{"t":"remote","id":"a","cmd":"alertDismiss"}"#) == .success(.alertDismiss))
        #expect(command(#"{"t":"remote","id":"a","cmd":"service","args":{"id":"SV"}}"#) == .success(.service(id: "SV")))
    }

    @Test func clearTakesTheLocalAPIsNamesAndThePhonesWords() {
        let cases = ["slide": "slides", "slides": "slides", "media": "media", "audio": "audio", "props": "overlays",
                     "overlays": "overlays", "messages": "alerts", "alerts": "alerts", "signage": "signage", "all": "all", "ALL": "all"]
        for (given, want) in cases {
            #expect(command(#"{"t":"remote","id":"a","cmd":"clear","args":{"function":"\#(given)"}}"#) == .success(.clear(function: want)), "\(given)")
        }
        #expect(command(#"{"t":"remote","id":"a","cmd":"clear","args":{"function":"lights"}}"#) == .failure(.init("Say what to clear.")))
    }

    @Test func badArgumentsSayWhatIsMissing() {
        #expect(command(#"{"t":"remote","id":"a","cmd":"advance","args":{"steps":0}}"#) == .failure(.init("Say how many slides to move.")))
        #expect(command(#"{"t":"remote","id":"a","cmd":"advance","args":{"steps":true}}"#) == .failure(.init("Say how many slides to move.")))
        #expect(command(#"{"t":"remote","id":"a","cmd":"slide","args":{"presentationId":"P"}}"#) == .failure(.init("Say which slide.")))
        #expect(command(#"{"t":"remote","id":"a","cmd":"timer","args":{"id":"T","action":"explode"}}"#) == .failure(.init("Timers start, stop or reset.")))
        #expect(command(#"{"t":"remote","id":"a","cmd":"alert","args":{"message":"   "}}"#) == .failure(.init("Write a message.")))
        #expect(command(#"{"t":"remote","id":"a","cmd":"selfDestruct"}"#) == .failure(.init("Unknown command.")))
    }

    @Test func answersAndLiveStateAreWrittenAsTheHubReadsThem() throws {
        let done = try JSONSerialization.jsonObject(with: CloudClientMessage.remoteDone(id: "r", ok: true, message: "ignored").encoded()) as? [String: Any]
        #expect(done?["t"] as? String == "remote-done" && done?["id"] as? String == "r" && done?["ok"] as? Bool == true && done?["message"] == nil)
        let failed = try JSONSerialization.jsonObject(with: CloudClientMessage.remoteDone(id: "r", ok: false, message: "No timer.").encoded()) as? [String: Any]
        #expect(failed?["ok"] as? Bool == false && failed?["message"] as? String == "No timer.")

        let state = try JSONEncoder().encode(["ids": PhoneRemote.LiveIDs(presentationId: "P", slideId: "S", slideIndex: 2)])
        let live = try JSONSerialization.jsonObject(with: CloudClientMessage.live(state: state).encoded()) as? [String: Any]
        let ids = (live?["state"] as? [String: Any])?["ids"] as? [String: Any]
        #expect(live?["t"] as? String == "live")
        #expect(ids?["presentationId"] as? String == "P" && ids?["slideIndex"] as? Int == 2)
        // Nothing live is written as nulls, not left out.
        #expect(ids?.keys.sorted() == ["itemId", "presentationId", "serviceId", "slideId", "slideIndex"])
        #expect(ids?["itemId"] is NSNull)
    }

    /// Claude's requests through the CMS (ClaudeRelay): the request comes as
    /// the JSON-RPC text it was, and the answer goes back as text.
    @Test func claudesRequestsAndAnswersAreReadAndWrittenAsTheHubDoes() throws {
        let body = #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#
        let text = #"{"t":"claude","id":"c-1","user":"cowens@hopejc.org","body":"#
            + String(decoding: try JSONEncoder().encode(body), as: UTF8.self) + "}"
        guard case .claude(let id, let data, let user) = decode(text) else {
            Issue.record("not read as a Claude request")
            return
        }
        #expect(id == "c-1" && user == "cowens@hopejc.org" && String(decoding: data, as: UTF8.self) == body)
        #expect(decode(#"{"t":"claude","id":"c-2"}"#) == .unknown("claude"))

        let ready = try JSONSerialization.jsonObject(with: CloudClientMessage.claudeReady(on: true).encoded()) as? [String: Any]
        #expect(ready?["t"] as? String == "claude-ready" && ready?["on"] as? Bool == true)
        let done = try JSONSerialization.jsonObject(with: CloudClientMessage.claudeDone(id: "c-1", body: "{}").encoded()) as? [String: Any]
        #expect(done?["t"] as? String == "claude-done" && done?["id"] as? String == "c-1" && done?["body"] as? String == "{}")
    }
}
