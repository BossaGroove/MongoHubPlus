# Changelog

All notable changes to MongoHub Plus are recorded here.

Each release's entry is shown inside the app (Settings → Software Update) and
in the update notification, so keep the entries user-facing: what changed for
someone using MongoHub Plus, not how it was implemented.

Version headings are `## <version> — <date>`; the release workflow reads the
version from the heading, so it must match the tag exactly.

## 4.1.0 — 2026-09-03

### Added

- **Choose how documents are written out, per place.** Settings → Syntax has
  a row each for the results table, editing a value in place, copying, and
  the JSON editor. Each picks between official Extended JSON and mongosh
  syntax — `{ _id: ObjectId('6a96…'), price: NumberDecimal('42.95') }` —
  because reading a value, editing one, and copying are different jobs.
  Whatever you choose, both syntaxes are still accepted when you type, and
  exported files are always Extended JSON.
- **BSON export for `mongorestore`.** The export Format popup can now write
  the same folder `mongodump` produces — `<database>/<collection>.bson` plus
  the metadata file carrying the indexes — so restoring one collection is
  just `mongorestore <folder>`, indexes included.
- **A bare date now works in the shell constructors**: `ISODate('2026-01-01')`
  means midnight UTC, as it does in mongosh. A timestamp with no time zone,
  like `ISODate('2026-01-01T10:00:00')`, is still refused with advice to add
  `Z` or an offset — JavaScript reads it as local time and mongosh as UTC, so
  guessing would quietly shift your query by hours.
- The mongosh shorthand MongoHub Plus has always accepted when you type —
  `ObjectId(…)`, `NumberDecimal(…)`, `/regex/i`, unquoted keys, and the rest
  — is now written down, in the README.

### Fixed

- Typing or pasting a long query no longer makes the window grow by itself.
  The grey query preview now shortens with an ellipsis when it does not fit
  (hover it to read the whole query), instead of pushing the window wider.
- The query field no longer ends up with a gap of empty space and its last
  characters cut off after the text outgrows the field.
- Long connection strings in the connection editor, and long queries in the
  Update and Remove tabs, behaved the same way and are fixed too.
- In the Add Connection sheet, the example connection string shown in an
  empty URI field now wraps onto the next line straight away, instead of
  being cut off until you clicked into the field and back out.
- The connection cards are now centred as a group. They used to spread out
  to the window's edges, which left a wide empty channel down the middle at
  two columns, and they kept the spacing of the previous window size after
  a resize.

## 4.0.2 — 2026-09-03

### Added

- Release notes: the update notification now shows what's new in the version
  being offered, and Settings → Software Update lists what's new in the
  version you're running.

### Fixed

- Double-clicking a database in the connection sidebar now expands its
  collection list (and collapses it again). Previously only collections
  responded to a double-click.
- The Find query-history dropdown now behaves like a normal macOS combo box:
  with the list open, Return picks the highlighted entry instead of running
  the query. Press Return again to run it.

## 4.0.1 — 2026-09-01

Maintenance release. No user-facing changes — published to verify the
automatic-update pipeline end to end.

## 4.0.0 — 2026-09-01

First public release. MongoHub Plus is a from-scratch Swift 6 rebuild of the
original [MongoHub](https://github.com/jeromelebel/MongoHub-Mac), which was
abandoned in 2015 and no longer runs on a modern Mac.

### Added

- **Connection manager** — a searchable card grid of saved connections
  (standalone, replica set, sharded, and MongoDB Atlas via `mongodb+srv://`)
  with pinned favorites, SCRAM auth, TLS, SSH tunnels with trust-on-first-use
  host keys, connection-string paste, and passwords stored in the macOS
  Keychain. Multiple windows per connection.
- **Browsing** — databases and collections in a sidebar, with server,
  database, and collection statistics, including `$jsonSchema` validation
  rules, rendered as expandable BSON trees.
- **Querying** — Find with query history, projection, sort and paging;
  Insert; Update with an operator builder; Remove; index management with
  usage statistics; an aggregation stage builder with per-stage live previews
  and Text ⇄ Stages editing; and a live change-stream Tail.
- **Explain plans** — one click on any query or pipeline gives an
  index-versus-collection-scan verdict, the winning-plan chain, execution
  statistics, and index suggestions.
- **Document editing** — edit values and add or delete fields directly in the
  results tree, or open a document in a syntax-coloured JSON editor. Editing
  uses official MongoDB Extended JSON and accepts mongosh-style input such as
  `ObjectId(…)` and unquoted keys. Every edit is round-trip verified at the
  byte level, so a document's BSON types are never silently changed. Typing a
  bare id into a query field still means `{_id: ObjectId("…")}`, as it did in
  the original MongoHub.
- **Monitoring** — a mongostat-style live activity table and a log window.
- **Import and export** — JSON Lines (lossless canonical Extended JSON) and
  CSV (flattened for spreadsheets), covering whole collections, the current
  query results, or a selection of documents.
- **Automatic updates** — signed and notarized updates via Sparkle, with an
  optional beta channel.
- **Localization** — English, 日本語, Deutsch, 繁體中文, 简体中文 and
  Français, switchable in Settings.

Requires macOS 14 (Sonoma) or later. MongoDB 6.0+ servers and MongoDB Atlas
are supported; older servers may work but are untested.
