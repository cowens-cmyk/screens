# Cloud sync

Every Mac running Screens, and the browser editor on the CMS's Screens page,
shares one church library through a hub in the Hope Church CMS Worker. This file is
the contract between the two sides: the Screens client
(`apps/mac/Packages/PresenterCore/Sources/PresenterCore/Sync/`) and the hub
(`ScreensHub` in `~/Desktop/hope-media-worker.js`, documented in
`~/hope-media-automation/docs/cms/SCREENS.md`).

## What syncs

Each library document is an Automerge document (`<kind>/<id>.automerge`).
Documents whose kind is team-scope (`SyncScope.scope(for:) == .team`: plans,
presentations, themes, media items, audio, playlists, overlays, alert presets,
action combos, schedule triggers, stage layouts, the group palette, effect and
animation boards, link rules, notes, slide-building settings, fonts) sync.
Station-scope kinds (outputs, MIDI, control boards, Run on this Mac) and the
import ledger never leave the Mac.

The hub never reads a document. It keeps, per document, an ordered log of
opaque Automerge byte chunks, and hands them to every other client. A chunk
is whatever `Document.encodeChangesSince(heads:)` or `Document.save()` made;
the client applies any of them with `applyEncodedChanges` (Automerge's
`load_incremental`), which accepts both.

## The browser editor

The CMS's Screens page reads and writes the same documents with Automerge in
the browser (`screensEditorModel` in the Worker; see the CMS's SCREENS.md). It
is not a socket client: it reads the hub's log over HTTP and sends its changes
with `POST /api/admin/screens/library/<kind>/<id>`, which the hub stores as a
`changes` push from device `cms` and sends to every Mac as a `change` with
`from: 'cms'`. It only changes plans (`service`) and presentations. It writes
strings as plain strings and keeps each value's type when it copies one, so
Codable decodes what it wrote; `CloudEditorInteropTests` checks that against
documents it made.

## Media files

Media files (blobs) go through R2, named by their SHA-256 (64 lowercase hex),
over HTTP on the same host as the socket. Every route takes the Mac's token as
`Authorization: Bearer <token>`; no token, a wrong one or an unlinked Mac's is
401. A bad sha is 400.

| Method | Path | What it does |
|---|---|---|
| HEAD | `/api/screens/blobs/<sha>` | 200 with `Content-Length`, `Content-Type` and `X-Screens-Ext`, or 404. |
| GET | `/api/screens/blobs/<sha>` | The file. One `Range: bytes=a-b` or `bytes=a-` is answered 206 with `Content-Range`, so a download can resume; a start past the end is 416. 404 if missing. |
| PUT | `/api/screens/blobs/<sha>` | The file, up to 95 MB, with `Content-Length` (411 without). `Content-Type` and `X-Screens-Ext` (1 to 8 of `[a-z0-9]`) are kept. 201 `{sha, size}`; 200 `{existed:true}` if it is already there (nothing rewritten); 413 over 95 MB. |
| POST | `/api/screens/blobs/<sha>/uploads` | Starts a multipart upload (same headers as PUT, empty body): 201 `{uploadId}`, or 200 `{existed:true}` if the file is already there. |
| PUT | `/api/screens/blobs/<sha>/uploads/<uploadId>/<partNumber>` | One part, 1 to 10000, up to 95 MB: `{partNumber, etag}`. Every part but the last must be at least 5 MiB (R2's rule; `complete` refuses otherwise). Unknown upload: 404. |
| POST | `/api/screens/blobs/<sha>/uploads/<uploadId>/complete` | `{parts:[{partNumber, etag}]}`: 201 `{sha, size}`. |
| DELETE | `/api/screens/blobs/<sha>/uploads/<uploadId>` | Aborts the upload. |

Put the `uploadId` through `encodeURIComponent`. The server does not hash
uploads (it cannot for a multipart one): it trusts the linked Mac. The Mac
that downloads a file hashes it and discards it if it does not match its name.
When an upload finishes, the hub sends `{t:'blob', sha}` to every connected
Mac. Nothing deletes unused files yet.

## Joining

The first Mac to connect to an empty hub uploads its whole library (the Mac
Studio's library is the church library). A Mac joining a hub that already has
documents backs up its library, removes its own team-scope documents and
downloads the hub's: two libraries are never merged, since they share ids
(settings) and content (the same songs imported twice) and would double up.

## Auth

A Mac is linked once. An admin makes a link code in the CMS (8 characters,
single use, 15 minutes); Screens sends it with a name to
`POST https://media.hopejc.org/api/screens/link` `{code, name}` and gets
`{deviceId, token}`. The token is stored in the Keychain and only its SHA-256
is kept by the CMS (`screens_devices`). Unlinking a Mac in the CMS revokes the
token and closes its socket.

## The socket

`GET wss://hope-media.cowens-09f.workers.dev/api/screens/sync` (WebSocket upgrade; media.hopejc.org is proxied and the proxy doesn't carry WebSockets). JSON text
frames. `bytes` fields are standard base64.

### Client to hub

| Message | Meaning |
|---|---|
| `{t:'hello', token, since, app}` | First message. `since` is the last hub `seq` this Mac has applied (0 for none); `app` is the Screens version. A bad or revoked token closes with 4401; no hello within 15 s closes with 4408. |
| `{t:'push', ref, kind, id, bytes, mode, base?}` | Changes to one document. `mode` is `'changes'` (encodeChangesSince the heads the hub already has), `'snapshot'` (a full save of the same history, sent when the hub asks, so it can drop older chunks) or `'reset'` (a full save of a new history replacing the document: it was deleted and made again, or replaced wholesale). `base`, sent with a snapshot or reset, is the last hub `seq` this Mac had applied when it saved; compaction keeps other Macs' chunks after it. |
| `{t:'delete', ref, kind, id}` | The document was deleted. |
| `{t:'ping'}` | Keep-alive; answered with `{t:'pong'}`. |

`ref` is the client's own number for the request, echoed in the answer.

### Hub to client

| Message | Meaning |
|---|---|
| `{t:'welcome', seq, docs, device}` | After a good hello. `seq` is the hub's newest sequence number, `docs` how many live documents it holds (0 means empty: the Mac may seed it), `device` this Mac's name. |
| `{t:'changes', items:[…]}` | Catch-up after hello, oldest first, in pages; then `{t:'caught-up', seq}`. Each item is a change (below). |
| `{t:'change', seq, kind, id, bytes, mode, from}` | Another client's push, live. `from` is the device id. Never sent to the client that pushed it. |
| `{t:'deleted', seq, kind, id, from}` | Another client deleted a document (also appears in catch-up pages, with `mode:'deleted'` and no bytes). |
| `{t:'ack', ref, seq}` | A push or delete was stored at `seq`. |
| `{t:'error', ref, code, message}` | A request was refused. `code`: `'deleted'` (pushing `changes` to a deleted document; the client should delete its copy), `'too-large'`, `'bad-request'`. |
| `{t:'want-snapshot', kind, id}` | The document has many chunks since its last snapshot; the client should push `mode:'snapshot'` when it can. |
| `{t:'blob', sha}` | A media file finished uploading (any Mac, the receiver included). A Mac waiting for it can fetch it now. Best effort: a Mac that misses it finds the file on its next HEAD. |

A catch-up item has the same fields as a `change`, with `mode` one of
`changes`, `snapshot`, `reset` or `deleted`.

### Ordering and compaction

`seq` rises by one per stored push or delete, across all documents. When a
`snapshot` or `reset` is stored, the hub drops the pusher's older chunks of
that document and other Macs' chunks up to `base` (or, without one, the seq
at which it asked for the snapshot), since a later chunk from another Mac may
not be in the snapshot;
a delete drops all of them and keeps a tombstone. A client that is behind
still receives everything it needs, because a snapshot or reset carries the
whole history at a newer `seq`.

A client applying a `reset` replaces its copy instead of merging; a
`snapshot` or `changes` merges.

### Echo

After applying a hub chunk the client adds the heads the chunk introduced to
the heads it knows the hub has, so its next push (encodeChangesSince those
heads) carries only its own unsent changes.
