# Claude and Screens (MCP)

Screens serves a Model Context Protocol server on its Local API, so Claude
(Claude Code, or Claude Desktop through a bridge) can build presentations in
the church library: songs from charts, the order they're sung in, the message
from the pastor's notes, lower thirds and the stage display. Changes go
through the app's own edit paths, so they sync to every linked Mac and the
browser editor like an operator's.

## From anywhere: through the CMS

`https://dashboard.hopejc.org/screens/mcp` works from claude.ai, the Claude
apps and Claude Code anywhere. Add it as a custom connector; an admin allows
it on a CMS page. The CMS passes each request over the sync socket to the
Mac that runs the service, which answers with the tools below
(`ClaudeRelay`, `ScreensMCP.server(remote: true)`: without `attach_file`,
`import_media`, `build_message_from_notes` and `import_announcement_cards`,
which read files on the Mac). That Mac needs **Claude** on in Settings ›
Integrations › Sync (off by default) and Run on this Mac on. The sign-in,
tokens and what keeps them safe are in the CMS's docs/cms/SCREENS.md
("Claude").

Messages on the sync socket: `{t:'claude-ready', on}` from the Mac when the
switch or Run on this Mac changes and on connecting; `{t:'claude', id, body,
user}` from the hub; `{t:'claude-done', id, body}` back.

## On the church network: the Local API

1. In Screens, Settings › Remote & API: turn on the Local API (port 6980 by
   default).
2. Manage Keys… › make a key with **Manage** access, named for where it's
   used ("Claude on Cameron's MacBook"). A Watch key can only read; an
   Operate key can't change the library either.
3. In Claude Code:

   ```bash
   claude mcp add --transport http screens http://localhost:6980/mcp --header "Authorization: Bearer <key>"
   ```

   From another Mac on the church network, use the Screens Mac's address
   (Settings › Remote & API shows it) instead of `localhost`.

   Claude Desktop takes it through `mcp-remote` in
   `claude_desktop_config.json`:

   ```json
   { "mcpServers": { "screens": { "command": "npx",
       "args": ["mcp-remote", "http://localhost:6980/mcp", "--header", "Authorization:Bearer <key>"] } } }
   ```

The transport is Streamable HTTP in its simplest form: each POST is one
JSON-RPC message and gets one JSON reply. There are no sessions or server
pushes; `GET /mcp` isn't served.

## Tools

Every tool the in-app Assistant has (`AssistantToolCatalog`), run by the same
`AssistantToolbox`, plus:

| Tool | What it does |
| --- | --- |
| `build_song` | A song from a ChordPro chart, chords over lyrics or plain lyrics with section labels, or from a Shepherd song id; built by `ShepherdSongImport.presentation`, so the slides, chords, key and stage key match a Shepherd import. `sequence` becomes the song's default order. `presentation_id` rebuilds a song in place (`ShepherdSongImport.replacing`); `plan_id`/`item_id` put it on a plan item. A song built from a pasted chart has no Shepherd link, so plan sync never refreshes it. |
| `set_song_sequence` | An order from section names (`ShepherdArrangementSync.mapping`: "Chorus x2", the blank opener). The song's default, or one plan item's. |
| `build_message_from_outline` | The message from an outline Claude read: `SermonSlides.build` with the verses looked up, `SermonMessage.place` into the plan with the series theme. Without a plan, a Sermon deck on its own. |
| `attach_file` | A PDF or picture on this Mac as Assistant attachment ids, for `build_message_from_notes` and `import_announcement_cards`. |
| `import_media` | Pictures and videos into Media (`AppModel.importFiles`), for backgrounds and lower-third pictures. |
| `set_stage_display` | A `setStageMode` action (worship, message, preService, mirror) on slides, or the first slide; `stage_layout_id` on slides or the presentation. |
| `list_stage_layouts` | The stage layouts. |
| `set_slide_notes` | A slide's notes, which stage layouts with a notes box show. |
| `get_stage_and_stream` | `StageStreamTags` for a plan's items, or one presentation's slides. |

Tools that need a Manage key are hidden from a Watch key's tool list, and
refused if called.

## Asking first

The Assistant's tools that wait for the operator's Approve
(`needsConfirmation`, `confirmsWhenReplacing`) take a `confirm` argument
here. Without it, nothing changes and the answer says what would; Claude
asks the user and calls again with `confirm: true`. `build_message_from_outline`
does the same when it would replace a message with slides or change the
plan's series.

`fit_song_slides` is one of these: it splits song slides that take more than
two lines in their theme, for one song or the whole library, and its first
answer says how many slides in how many songs would change. See
`song-slides.md`.

## Code

- `apps/mac/Packages/LocalAPI/Sources/LocalAPI/MCPServer.swift`: the protocol
  (initialize, tools/list, tools/call, ping), as an `APIRoute` behind the
  Local API's key check. Handlers run on the main actor.
- `apps/mac/Sources/ScreensMCP.swift`: the tools.
- `LocalAPIController.start()` adds the route.
- Tests: `MCPServerTests` in the LocalAPI package.
