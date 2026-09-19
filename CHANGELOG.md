# Changelog

All notable changes to MongoHub Plus are recorded here.

Each release's entry is shown inside the app (Settings → Software Update) and
in the update notification, so keep the entries user-facing: what changed for
someone using MongoHub Plus, not how it was implemented.

Version headings are `## <version> — <date>`; the release workflow reads the
version from the heading, so it must match the tag exactly.

## 4.4.0 — unreleased

### Added

- **A Collections table for a database.** Select a database and the new
  Collections toolbar button lists every collection in it with storage size,
  data size, documents, average document size, index count and total index
  size — so the collection responsible for a database's size is obvious at a
  glance, which the totals in Database Stats cannot tell you. Click a column
  header to sort, double-click a row to open that collection's query tab.
  Database Stats and Collection Stats are unchanged.
- **The Index tab shows how big each index is.** A Size column, in the units
  you would expect — `842 B`, `160 KB`, `1.5 MB` — so the indexes worth
  questioning stand out. Sizes come from the collection's stats; where your
  user cannot read those, the column stays empty and the footer says so,
  the same way index usage already does.

## 4.3.0 — 2026-09-20

### Added

- **See what an update will do before you run it.** The Update tab now shows
  how many documents the query matches — right on the button, so it reads
  *Update 28 documents* — and a preview of the first three of them with the
  pending change marked on each: the old value struck through in red, the new
  value beside it in green. Nothing is written to run the preview; it is the
  documents you already matched, annotated. Where an operator's result cannot
  be known without the server (`$pull`'s predicate, `$push` with `$each`,
  `$currentDate`) the field is marked *will change* rather than guessing.
  Anything the update cannot be read from — a value that is not valid JSON —
  clears the preview and disables the button, saying which row is wrong.
- **Stop a running query.** A Stop button appears next to the spinner while a
  query runs in the Find or Aggregation tab (⌘.), for the moment you realise
  you just scanned a collection with no usable index. It stays available
  until the result count finishes too, which on a collection with no useful
  index is the part that actually takes the time. It stops the query *on
  the server*, not just in the window: MongoHub Plus runs every query in its
  own server session and kills that session, which the server confirms by
  interrupting the operation. Simply giving up on the client does not do
  this — a query abandoned that way keeps running and keeps consuming the
  database. The same protection now applies when a query fails for any other
  reason, so MongoHub Plus no longer leaves work running behind your back.
- **⌘F searches the document in the JSON editor.** Find… (⌘F), Find Next
  (⌘G), Find Previous (⇧⌘G), Use Selection for Find and Jump to Selection
  (⌘J) now live under Edit ▸ Find, so a long document — a big
  `snapshot` blob, a description full of HTML — no longer has to be read by
  scrolling. Matches highlight as you type, ⌘G and ⇧⌘G step through them
  without having to click out of the search box first, Esc closes the search
  bar without closing the window, and the same search works in the Insert
  and Aggregation JSON boxes.

### Changed

- **The Remove tab's query label matches the others** — it read `Query:`
  while every other tab reads `Query`.

### Fixed

- **A stray word in an update operator box no longer becomes an `_id`
  rewrite.** The operator boxes were being read the way the query box is,
  where a bare word is shorthand for "the document with this id" — so
  typing `name` into Set quietly built `{$set: {_id: "name"}}`, an update
  that rewrites the `_id` of every matching document. Operator boxes now
  reject anything that is not a document, and say so. The shorthand still
  works where it belongs, in the query box.
- **The Aggregation tab's Options box no longer overlaps the stage buttons.**
  It is taller than its label, and was being centred on it, so its top edge
  rode up over the +/− buttons beneath the stage list.

## 4.2.0 — 2026-09-15

### Added

- **⌘Return in a query box expands id shortcuts before running.** Typing a
  24-hex id has always worked for `_id`; now `user_id: '5f50a10dff1ce7314da050ca'`
  and ⌘Return rewrites the box to
  `{user_id: ObjectId('5f50a10dff1ce7314da050ca')}` and runs it, so ids match
  instead of quietly comparing as strings. It reaches nested fields and
  `$in` lists too, leaves the rest of what you typed exactly as you typed it,
  and works in the Find, Update and Remove query boxes. Plain Return still
  runs the query untouched.
- **Take a query from Find straight to Update or Remove.** Two buttons next
  to Run open the Update or Remove tab with the query already filled in —
  prefilled only, so nothing runs until you say so.

### Changed

- **The Update tab's Multi checkbox now starts ticked**, so an update covers
  every matching document rather than silently touching the first one.
- **Double-clicking a document's `_id` copies it** instead of opening the
  JSON editor, and the footer confirms what went to the clipboard. `_id`
  can't be edited — MongoDB won't allow it — so the double-click now does
  the thing that was always wanted there. The editor is still on the
  right-click menu, and on the document's own row.

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
