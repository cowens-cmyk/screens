# ATEM: livestream graphics on and off air

Settings › Integrations › ATEM. Per Mac, off until turned on.

The Livestream screen goes into the switcher as Fill and Key (at Hope: ATEM
2 M/E Constellation HD at 10.1.2.12, Fill on input 7, Key on input 6), carried
by one keyer (default ME 1 Key 1; DSK 1 is set up the same way). With
**Put graphics on and off air with the slides** on, Screens cuts that keyer:

- **on** as soon as the Livestream screen shows anything (`StreamCoverage`
  is lower third or full screen: a lower third, lyrics, a full slide, a
  video);
- **off** once the screen has been clear for 1.5 s (`ATEMKeyFollower.offDelay`).

Both cuts happen while the key signal is clear, so what the stream sees is
the slide's own fade, not a cut. Full-screen graphics go through the same
keyer: a full slide's key is solid, so it covers the camera. Nothing switches
program.

It only acts on changes. A keyer cut by hand on the switcher (or with the
**On Air / Off Air** chip on the Livestream monitor) stays that way until the
Livestream screen next changes between clear and showing. When the link
connects or reconnects, it puts the keyer where the stream says it should be.

## Protocol

`PresenterCore/Production/ATEMProtocol.swift` (framing, commands, state; tests
use bytes the real switcher sent) and `Sources/ATEMLink.swift` (UDP session,
the follower, the settings form and the monitor chip).

- UDP 9910. Hello, then ack every packet the switcher marks ack-request.
- Our commands go as ack-request packets and are resent every 250 ms until
  acknowledged (8 tries, then reconnect).
- An empty ack-request packet every second keeps the session up; 4 s with
  nothing heard means start over.
- Commands sent: `CKOn` (upstream keyer on air), `CDsL` (downstream keyer on
  air). State read: `_pin`, `_top`, `InPr`, `KeOn`, `KeBP`, `DskB`, `DskS`,
  `InCm` (end of the first state dump).

The switcher takes a limited number of clients (ATEM Software Control,
Companion, Screens…). If Screens shows "No answer", check that first.
