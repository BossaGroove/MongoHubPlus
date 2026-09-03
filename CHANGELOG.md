# Changelog

All notable changes to MongoHub Plus are recorded here.

Each release's entry is shown inside the app (Settings → Software Update) and
in the update notification, so keep the entries user-facing: what changed for
someone using MongoHub Plus, not how it was implemented.

Version headings are `## <version> — <date>`; the release workflow reads the
version from the heading, so it must match the tag exactly.

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
